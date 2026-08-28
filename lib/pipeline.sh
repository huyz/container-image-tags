# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2178  # pipeline stages exchange documented state

# CLI orchestration pipeline:
#   input syntax -> one or more subjects -> remote check -> tag scan -> render
# The policy engine owns registry flow; this file owns user-visible sequencing.

function require_supported_digest_algorithm {
    local digest_reference="$1"
    local digest="${digest_reference##*@}"
    local algorithm

    [[ "$digest" == *:* ]] || return 0
    algorithm="${digest%%:*}"
    [[ -n "$algorithm" ]] || return 0
    [[ "$algorithm" == sha256 ]] ||
        abort "Digest algorithm '$algorithm' in '$digest_reference' is not supported; only sha256 is supported"
}

function reset_input_resolution {
    skip_input=
    container=
    image_id=
    local_image_version=
    local_image_revision=
    local_image_refname=
    repo_digest=
    local_tag=
    wildcard_image_ids=
    wildcard_reference=
    wildcard_repository=
    subject_source=
}

# Resolve one registry tag to its subject digest without consulting Docker. The
# caller supplies the notice so automatic fallback and explicit remote mode
# can explain their different intent before network work starts.
function resolve_remote_tag_subject {
    local repository="$1"
    local tag="$2"
    local resolution_notice="$3"
    local remote_reference="$repository:$tag"
    local -A remote_lookup=()

    notice "$resolution_notice"
    registry_classify "$repository"
    registry_resolve_tag_digest "$repository" "$tag" remote_lookup
    case "${remote_lookup[status]}" in
    "$LOOKUP_SUCCEEDED") ;;
    "$LOOKUP_NOT_FOUND") abort "Cannot resolve remote tag '$remote_reference': the tag was not found" ;;
    "$LOOKUP_DENIED")
        if [[ -n "${remote_lookup[error]}" ]]; then
            abort "Google registry denied access to '$remote_reference': ${remote_lookup[error]}"
        fi
        abort "Registry denied access to '$remote_reference' after authentication; the repository may be unavailable or the authenticated account may lack permission"
        ;;
    *) abort "Failed to resolve remote tag '$remote_reference'" ;;
    esac

    require_supported_digest_algorithm "$remote_reference@${remote_lookup[digest]}"
    [[ "${remote_lookup[digest]}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
        abort "Registry returned an invalid digest for '$remote_reference': '${remote_lookup[digest]}'"
    repo_digest="$repository@${remote_lookup[digest]}"
    local_tag="$remote_reference"
    subject_source=remote
}

function resolve_untagged_repository_subject {
    local input_reference="$1"
    local repository="$2"
    local wildcard_count=0 wildcard_image_id

    if [[ "$opt_tag_resolution" == remote ]]; then
        resolve_remote_tag_subject "$repository" latest \
            "Resolving '$repository:latest' through the registry and ignoring local Docker state."
    elif inspect_local_image "$input_reference" "$repository" "$repository:latest"; then
        notice "Resolved '$input_reference' as an image using its implicit ':latest' tag; not scanning other local tags."
    elif wildcard_image_ids=$(image_ids_for_repository "$repository"); then
        wildcard_reference="$repository:*"
        wildcard_repository="$repository"
        while IFS= read -r wildcard_image_id; do
            [[ -n "$wildcard_image_id" ]] && ((++wildcard_count))
        done <<<"$wildcard_image_ids"
        notice "No local '$repository:latest' image was found; interpreting '$input_reference' as '$repository:*' and checking $wildcard_count distinct local image(s)."
    elif [[ "$opt_tag_resolution" == auto ]]; then
        resolve_remote_tag_subject "$repository" latest \
            "No local image in repository '$repository' was found; falling back to remote tag resolution for '$repository:latest'."
    else
        abort "Cannot resolve '$input_reference' to a local image"
    fi
}

function resolve_input_subjects {
    local input_reference="$1"
    local preferred_repository final_component resolved_image_id registry_sha
    local matching_repo_digests wildcard_count=0 wildcard_image_id

    input="$input_reference"
    reset_input_resolution
    if [[ "$input" == *@* ]]; then
        require_supported_digest_algorithm "$input"
        if [[ "$input" =~ ^.+@sha256:[0-9a-f]{64}$ ]]; then
            repo_digest="$input"
            subject_source=input
            notice "Interpreting '$input' as a complete registry digest reference."
        else
            abort "'$input' looks like a registry digest reference, but expected repository@sha256:<64 lowercase hex characters>"
        fi
    elif [[ "$input" =~ ^([Ss][Hh][Aa]256:)?[0-9a-fA-F]{12,64}$ ]]; then
        if [[ "$opt_tag_resolution" == remote ]]; then
            abort "Cannot resolve SHA-like '$input' remotely without a repository; pass repository@sha256:<64 lowercase hex characters>"
        elif resolved_image_id=$(
            run_network_command "$DOCKER" container inspect \
                "$input" --format '{{.Image}}' 2>/dev/null
        ); then
            container="$input"
            inspect_local_image "$resolved_image_id" ||
                abort "Container '$container' refers to image '$resolved_image_id', but that image cannot be inspected"
            notice "Resolved SHA-like '$input' as a local container ID (image $image_id)."
        elif inspect_local_image "$input"; then
            notice "Resolved SHA-like '$input' as local image ID $image_id."
        else
            registry_sha="$input"
            [[ "$registry_sha" == *:* ]] && registry_sha="${registry_sha#*:}"
            notice "No local container or image ID matched '$input'; assuming it is a registry digest."
            [[ "$registry_sha" =~ ^[0-9a-f]{64}$ ]] ||
                abort "A registry digest must contain exactly 64 lowercase hex characters; pass repository@sha256:<digest> if it is not locally known"
            matching_repo_digests=$(repo_digests_for_sha "$registry_sha") ||
                abort "Cannot determine the repository for sha256:$registry_sha from local images; pass repository@sha256:$registry_sha"
            repo_digest="${matching_repo_digests%%$'\n'*}"
            if [[ "$matching_repo_digests" == *$'\n'* ]]; then
                warn "sha256:$registry_sha is associated with multiple local repositories; using '$repo_digest'. Pass a complete repository@sha256:... argument to select another."
            else
                notice "Recovered registry reference '$repo_digest' from local image metadata."
            fi
        fi
    elif [[ "$input" == */* || "${input##*/}" == *:* ]]; then
        preferred_repository=$(repository_from_image_reference "$input")
        final_component="${input##*/}"
        if [[ "$final_component" == *:* && "${final_component##*:}" == '*' ]]; then
            [[ "$opt_tag_resolution" != remote ]] ||
                abort "Cannot use wildcard '$input' with --tag-resolution=remote; pass a concrete tag"
            wildcard_image_ids=$(image_ids_for_repository "$preferred_repository") ||
                abort "Cannot find any local image in repository '$preferred_repository'"
            wildcard_reference="$input"
            wildcard_repository="$preferred_repository"
            while IFS= read -r wildcard_image_id; do
                [[ -n "$wildcard_image_id" ]] && ((++wildcard_count))
            done <<<"$wildcard_image_ids"
            notice "Explicit wildcard '$input' requested; immediately checking $wildcard_count distinct local image(s)."
        elif [[ "$final_component" == *:* ]]; then
            if [[ "$opt_tag_resolution" == remote ]]; then
                resolve_remote_tag_subject "$preferred_repository" "${final_component##*:}" \
                    "Resolving '$input' through the registry and ignoring local Docker state."
            elif inspect_local_image "$input" "$preferred_repository" "$input"; then
                notice "Interpreting '$input' as a tagged local image reference."
            elif [[ "$opt_tag_resolution" == auto ]]; then
                resolve_remote_tag_subject "$preferred_repository" "${final_component##*:}" \
                    "No local image '$input' was found; falling back to remote tag resolution."
            else
                abort "Cannot inspect local image '$input'"
            fi
        else
            resolve_untagged_repository_subject "$input" "$preferred_repository"
        fi
    elif [[ "$opt_tag_resolution" != remote ]] && resolved_image_id=$(
        run_network_command "$DOCKER" container inspect \
            "$input" --format '{{.Image}}' 2>/dev/null
    ); then
        container="$input"
        inspect_local_image "$resolved_image_id" ||
            abort "Container '$container' refers to image '$resolved_image_id', but that image cannot be inspected"
        notice "Resolved '$input' as a local container name (image $image_id)."
    else
        resolve_untagged_repository_subject "$input" "$input"
    fi
}

function check_subject_remote_tag {
    local result_name="$1"
    local -n result_ref="$result_name"
    local remote_tag_reference
    local -A direct_lookup=()

    if [[ "${result_ref[subject_source]}" == remote ]]; then
        result_ref[remote_check_status]=resolved
        result_ref[remote_check_reference]="${result_ref[repository]}:${result_ref[local_tag]}"
        result_ref[remote_check_digest]="${result_ref[digest]}"
    elif [[ "${result_ref[local_tag]}" == '<none>' ]]; then
        result_ref[remote_check_status]=unavailable
    else
        remote_tag_reference="${result_ref[repository]}:${result_ref[local_tag]}"
        registry_resolve_tag_digest \
            "${result_ref[repository]}" "${result_ref[local_tag]}" direct_lookup
        result_ref[remote_check_reference]="$remote_tag_reference"
        case "${direct_lookup[status]}" in
        "$LOOKUP_SUCCEEDED")
            result_ref[remote_check_digest]="${direct_lookup[digest]}"
            if [[ "${direct_lookup[digest]#sha256:}" == "$repo_sha" ]]; then
                result_ref[remote_check_status]=match
            else
                result_ref[remote_check_status]=mismatch
            fi
            ;;
        "$LOOKUP_NOT_FOUND") result_ref[remote_check_status]=not_found ;;
        "$LOOKUP_DENIED")
            if [[ -n "${direct_lookup[error]}" ]]; then
                abort "Google registry denied access to '$remote_tag_reference': ${direct_lookup[error]}"
            fi
            abort "Registry denied access to '$remote_tag_reference' after authentication; the repository may be unavailable or the authenticated account may lack permission"
            ;;
        *) abort "Failed to check remote tag '$remote_tag_reference'" ;;
        esac
    fi
}

function process_resolved_subject {
    local result_name="$1"
    local -n result_ref="$result_name"
    local tag_scan_mode
    local -A scan_lookup=()

    [[ -n "$repo_digest" ]] || return 1
    require_supported_digest_algorithm "$repo_digest"
    repo="${repo_digest%%@*}"
    repo_sha="${repo_digest##*@}"
    repo_sha="${repo_sha#sha256:}"
    if [[ -z "$local_tag" || "$local_tag" == '<none>:<none>' ]]; then
        local_tag='<none>'
    else
        local_tag="${local_tag##*:}"
    fi
    registry_classify "$repo"

    result_init "$result_name"
    result_capture_subject "$result_name"
    [[ -n "$opt_json" ]] || render_result_header_human "$result_name"
    check_subject_remote_tag "$result_name"
    [[ -n "$opt_json" ]] || render_remote_check_human "$result_name"

    tag_scan_mode="$opt_tag_scan"
    result_ref[scan_mode]="$tag_scan_mode"
    if [[ "$tag_scan_mode" == never ]]; then
        result_ref[scan_status]=not_requested
        [[ -z "$opt_json" ]] || append_json_result "$result_name"
        return
    fi
    if [[ "$tag_scan_mode" == ask ]]; then
        tag_scan_mode=$(choose_remote_tag_scan) ||
            abort "Cannot prompt to scan remote tags; rerun with --tag-scan=never, --tag-scan=any, --tag-scan=any-durable, or --tag-scan=all"
        result_ref[scan_mode]="$tag_scan_mode"
        if [[ "$tag_scan_mode" == none ]]; then
            result_ref[scan_mode]=ask
            result_ref[scan_status]=declined
            [[ -z "$opt_json" ]] || append_json_result "$result_name"
            return
        fi
    fi

    registry_direct_tag_confirmed=
    case "${result_ref[remote_check_status]}" in
    match | resolved) registry_direct_tag_confirmed=1 ;;
    esac
    registry_find_tags_by_digest \
        "$repo" "sha256:$repo_sha" "$tag_scan_mode" "$local_tag" scan_lookup
    result_capture_scan "$result_name" scan_lookup
    if [[ -n "$skip_input" ]]; then
        result_ref[scan_status]=skipped
    fi
    if [[ -n "$opt_json" ]]; then
        append_json_result "$result_name"
    else
        render_scan_human "$result_name"
    fi
}

function print_result_separator {
    local separator_columns="${COLUMNS:-$(tput cols 2>/dev/null || true)}"

    (( separator_columns > 0 )) || separator_columns=80
    printf '%*s\n' "$separator_columns" '' | tr ' ' '-'
}

function process_input {
    local input_reference="$1"
    local input_position="$2"
    local image_to_process wildcard_output_index=0 seen_wildcard_repo_digests=
    local -a images_to_process
    local -A result=()

    if [[ -z "$opt_json" ]] && (( input_position > 1 )); then
        print_result_separator
    fi
    resolve_input_subjects "$input_reference"
    readarray -t images_to_process <<<"${wildcard_image_ids:-__current_resolution__}"
    for image_to_process in "${images_to_process[@]}"; do
        skip_input=
        if [[ "$image_to_process" != __current_resolution__ ]]; then
            container=
            inspect_local_image "$image_to_process" "$wildcard_repository" || {
                warn "Cannot inspect wildcard image match '$image_to_process'; skipping it"
                continue
            }
        fi
        if [[ -z "$repo_digest" ]]; then
            if [[ -n "$container" ]]; then
                echo "No repository digest found for image '$image_id' (used by container '$container')" >&2
            elif [[ -n "$wildcard_image_ids" ]]; then
                warn "No repository digest found for wildcard image '$image_id'; skipping it"
                continue
            else
                echo "No repository digest found for image '$image_id'" >&2
            fi
            exit 1
        fi
        if [[ -n "$wildcard_image_ids" ]]; then
            if grep -Fxq -- "$repo_digest" <<<"$seen_wildcard_repo_digests"; then
                verbose "Skipping local image $image_id because repository digest '$repo_digest' was already checked."
                continue
            fi
            seen_wildcard_repo_digests+="${seen_wildcard_repo_digests:+$'\n'}$repo_digest"
            if [[ -z "$opt_json" ]] && (( wildcard_output_index > 0 )); then
                print_result_separator
            fi
            ((++wildcard_output_index))
            notice "Resolved '$wildcard_reference' to local image $image_id."
        fi
        process_resolved_subject result
    done
}
