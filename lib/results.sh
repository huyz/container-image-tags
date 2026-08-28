# shellcheck shell=bash
# shellcheck disable=SC2154,SC2178  # associative nameref keys and pipeline-owned fields

# Canonical per-baseline result records and their human/JSON renderers. The
# processing pipeline owns the record; renderers never consult lookup globals.

function result_init {
    local -n result_ref="$1"

    result_ref=()
    result_ref[baseline_source]=local
    result_ref[remote_check_status]=
    result_ref[remote_check_reference]=
    result_ref[remote_check_digest]=
    result_ref[scan_mode]=
    result_ref[scan_status]=not_requested
    result_ref[scan_backend]=
    result_ref[provider_metadata]=
    result_ref[tags]=
}

function result_capture_baseline {
    local -n result_ref="$1"

    result_ref[input]="$input"
    result_ref[container]="${container-}"
    result_ref[image_id]="${image_id-}"
    result_ref[image_version]="${local_image_version-}"
    result_ref[image_revision]="${local_image_revision-}"
    result_ref[image_refname]="${local_image_refname-}"
    result_ref[local_tag]="$local_tag"
    result_ref[repository]="$repo"
    result_ref[digest]="sha256:$repo_sha"
    result_ref[baseline_source]="${baseline_source:-local}"
    result_ref[registry_kind]="$registry_kind"
    result_ref[registry_host]="$registry_host"
}

function result_capture_scan {
    local -n result_ref="$1"
    local context_name="${2-}"

    if [[ -n "$context_name" ]]; then
        local -n context_ref="$context_name"
        result_ref[scan_status]="${context_ref[result]:-completed}"
        result_ref[scan_backend]="${context_ref[backend]-}"
        result_ref[provider_metadata]="${context_ref[metadata]-}"
        result_ref[tags]="${context_ref[tags]-}"
    else
        result_ref[scan_status]="${registry_lookup_result:-completed}"
        result_ref[scan_backend]="${registry_lookup_backend-}"
        result_ref[provider_metadata]="${registry_metadata-}"
        result_ref[tags]="${registry_tags-}"
    fi
}

function render_result_header_human {
    local -n result_ref="$1"

    if [[ -n "${result_ref[container]}" ]]; then
        echo "Container: ${result_ref[container]}"
        echo
    fi
    if [[ -n "${result_ref[image_id]}" ]]; then
        echo "Local Image ID:  ${result_ref[image_id]}"
        [[ -z "${result_ref[image_version]}" ]] || \
            echo "OCI annotation » Version:  ${result_ref[image_version]}"
        [[ -z "${result_ref[image_revision]}" ]] || \
            echo "OCI annotation » Revision: ${result_ref[image_revision]}"
        [[ -z "${result_ref[image_refname]}" ]] || \
            echo "OCI annotation » Ref name: ${result_ref[image_refname]}"
    fi
    echo "Repository:      ${result_ref[repository]}"
    echo "Manifest digest: ${result_ref[digest]}"
    echo
    if [[ -n "${result_ref[image_id]}" ]]; then
        echo "Local tag:  ${result_ref[local_tag]}"
    fi
}

function render_remote_check_human {
    local -n result_ref="$1"

    case "${result_ref[remote_check_status]}" in
    resolved)
        echo "Remote tag: ${result_ref[local_tag]}"
        echo "Remote tag resolution: ${result_ref[remote_check_reference]} points to ${result_ref[remote_check_digest]}"
        ;;
    match)
        echo "Remote tag check: ✅ MATCH — ${result_ref[remote_check_reference]} still points to ${result_ref[digest]}"
        ;;
    mismatch)
        echo "Remote tag check: ❗️ MISMATCH — ${result_ref[remote_check_reference]} now points to ${result_ref[remote_check_digest]}"
        ;;
    not_found)
        echo "Remote tag check: ❌ NOT FOUND — ${result_ref[remote_check_reference]} no longer exists at the registry"
        ;;
    esac
    echo
}

function render_scan_human {
    local result_name="$1"
    local -n result_ref="$result_name"

    case "${result_ref[scan_status]}" in
    not_requested | declined | skipped) return ;;
    esac
    if [[ "${result_ref[scan_mode]}" == any ||
            "${result_ref[scan_mode]}" == any-durable ]]; then
        echo "Remote tags (partial scan):"
    else
        echo "Other remote tags:"
    fi
    printf '%s\n' "${result_ref[tags]:-<none>}"
    registry_print_metadata "$result_name"
}

function result_to_json {
    local -n result_ref="$1"

    "$JQ" -cn \
        --arg input "${result_ref[input]}" \
        --arg container "${result_ref[container]}" \
        --arg image_id "${result_ref[image_id]}" \
        --arg image_version "${result_ref[image_version]}" \
        --arg image_revision "${result_ref[image_revision]}" \
        --arg image_refname "${result_ref[image_refname]}" \
        --arg local_tag "${result_ref[local_tag]}" \
        --arg repository "${result_ref[repository]}" \
        --arg digest "${result_ref[digest]}" \
        --arg baseline_source "${result_ref[baseline_source]}" \
        --arg registry_kind "${result_ref[registry_kind]}" \
        --arg registry_host "${result_ref[registry_host]}" \
        --arg remote_check_status "${result_ref[remote_check_status]}" \
        --arg remote_check_reference "${result_ref[remote_check_reference]}" \
        --arg remote_check_digest "${result_ref[remote_check_digest]}" \
        --arg scan_mode "${result_ref[scan_mode]}" \
        --arg scan_status "${result_ref[scan_status]}" \
        --arg tags "${result_ref[tags]}" \
        --arg scan_backend "${result_ref[scan_backend]}" \
        --arg provider_metadata "${result_ref[provider_metadata]}" '
            def nullable: if length == 0 then null else . end;
            {
                input: $input,
                container: ($container | nullable),
                local_image: (
                    if $image_id == "" then null
                    else {
                        id: $image_id,
                        version: ($image_version | nullable),
                        revision: ($image_revision | nullable),
                        refname: ($image_refname | nullable),
                        tag: (if $local_tag == "<none>" then null else $local_tag end)
                    }
                    end
                ),
                repository: $repository,
                digest: $digest,
                baseline_source: $baseline_source,
                registry: {kind: $registry_kind, host: $registry_host},
                remote_tag_check: {
                    status: $remote_check_status,
                    reference: ($remote_check_reference | nullable),
                    digest: ($remote_check_digest | nullable)
                },
                tag_scan: {
                    mode: $scan_mode,
                    status: $scan_status,
                    backend: ($scan_backend | nullable),
                    provider_metadata: (
                        if $provider_metadata == "" then null
                        else ($provider_metadata | fromjson)
                        end
                    ),
                    tags: ($tags | split("\n") | map(select(length > 0)))
                }
            }
        '
}

function append_json_result {
    local result_name="$1"
    local rendered_json

    rendered_json=$(result_to_json "$result_name")
    json_results+="${json_results:+$'\n'}$rendered_json"
}
