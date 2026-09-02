# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2178  # standalone module lint: shared fields and namerefs

# Anonymous OCI Distribution fast path for public registries. List tags once,
# obtain at most one repository-scoped bearer token, then resolve tag digests
# with lightweight manifest HEAD requests. Private or incompatible registries
# fall back to Skopeo so configured credential helpers continue to work.

readonly OCI_MAX_PARALLEL_JOBS=8
readonly OCI_ESTIMATED_SECONDS_PER_BATCH=1
readonly OCI_MANIFEST_ACCEPT_HEADER='Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

function oci_header_value {
    local header_file="$1"
    local header_name="$2"

    perl -e '
        my ($name, $file) = @ARGV;
        open my $fh, "<", $file or exit 1;
        while (<$fh>) {
            if (/^\Q$name\E:\s*(.*?)\s*$/i) {
                print "$1\n";
                last;
            }
        }
    ' "$header_name" "$header_file"
}

function oci_http_status {
    local header_file="$1"

    perl -ne '
        $status = $1 if m{^HTTP/\S+\s+(\d{3})};
        END { print "$status\n" if defined $status; }
    ' "$header_file"
}

function oci_next_link {
    local header_file="$1"

    perl -ne '
        if (/^Link:\s*(.*)/i) {
            for (split /,\s*/, $1) {
                if (/<([^>]+)>;\s*rel="next"/i) {
                    print "$1\n";
                    exit;
                }
            }
        }
    ' "$header_file"
}

# Write curl headers to a mode-0600 file so bearer tokens never appear in the
# process list. curl accepts one header per line with -H @file.
function oci_write_request_headers {
    local header_file="$1"
    local token="${2-}"

    : >"$header_file"
    chmod 600 "$header_file"
    printf '%s\n' "$OCI_MANIFEST_ACCEPT_HEADER" >"$header_file"
    [[ -z "$token" ]] || printf 'Authorization: Bearer %s\n' "$token" >>"$header_file"
}

# Exchange a Bearer challenge for one anonymous repository-scoped pull token.
# Codeberg currently advertises scope="*"; use the standard repository scope
# in that case so the resulting token can list and inspect this repository.
function oci_token_from_bearer_challenge {
    local auth_header="$1"
    local repository="$2"
    local realm service scope response_tmp http_code token
    local -a token_args

    [[ "$auth_header" =~ ^[Bb][Ee][Aa][Rr][Ee][Rr][[:space:]] ]] ||
        return "$LOOKUP_UNAVAILABLE"
    realm=$(perl -ne 'if (/\brealm="([^"]+)"/i) { print "$1\n"; exit }' <<<"$auth_header")
    service=$(perl -ne 'if (/\bservice="([^"]*)"/i) { print "$1\n"; exit }' <<<"$auth_header")
    scope=$(perl -ne 'if (/\bscope="([^"]*)"/i) { print "$1\n"; exit }' <<<"$auth_header")
    [[ "$realm" == https://* ]] || return "$LOOKUP_UNAVAILABLE"
    if [[ -z "$scope" || "$scope" == '*' ]]; then
        scope="repository:$repository:pull"
    fi

    response_tmp=$(runtime_temp_file oci-token-response)
    token_args=(-sS -G -o "$response_tmp" -w '%{http_code}')
    [[ -z "$service" ]] || token_args+=(--data-urlencode "service=$service")
    token_args+=(--data-urlencode "scope=$scope")
    if ! http_code=$(run_network_command "$CURL" "${token_args[@]}" "$realm"); then
        rm -f "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
    case "$http_code" in
    200)
        token=$("$JQ" -r '.token // .access_token // empty' "$response_tmp" 2>/dev/null || true)
        rm -f "$response_tmp"
        [[ -n "$token" ]] || return "$LOOKUP_UNAVAILABLE"
        printf '%s\n' "$token"
        ;;
    401 | 403)
        rm -f "$response_tmp"
        return "$LOOKUP_DENIED"
        ;;
    429)
        rm -f "$response_tmp"
        return "$LOOKUP_STOPPED"
        ;;
    *)
        rm -f "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
        ;;
    esac
}

function oci_request_tag_page {
    local url="$1"
    local request_headers="$2"
    local response_headers="$3"
    local response_body="$4"

    : >"$response_headers"
    : >"$response_body"
    registry_http_request GET "$url" "$response_body" "$response_headers" \
        -H "@$request_headers"
}

# Populate the caller-owned inventory context. Return LOOKUP_SUCCEEDED for a
# complete list, LOOKUP_NOT_FOUND for an unavailable repository,
# LOOKUP_UNAVAILABLE for an unsupported/failed fast path, LOOKUP_DENIED for
# access denial, and LOOKUP_STOPPED for rate limiting.
function oci_list_tags {
    local registry="$1"
    local repository="$2"
    local page_mode="${3-full}"
    local initial_token="${4-}"
    local allow_anonymous_challenge="${5-}"
    local inventory_scan_limit_ms="${6-}"
    local -n inventory_ref="$7"
    local request_headers response_headers response_body
    local next_url next_link page_tags auth_header http_code token_status durable_precision
    local page_tag_count listed_tag_count=0 estimated_scan_ms threshold_ms
    local pagination_cost_advised=
    local lookup_status=$LOOKUP_SUCCEEDED

    inventory_ref=([token]="$initial_token" [tags]='' [direct_tag_durable]='')
    request_headers=$(runtime_temp_file oci-request-headers)
    response_headers=$(runtime_temp_file oci-response-headers)
    response_body=$(runtime_temp_file oci-response-body)
    oci_write_request_headers "$request_headers" "${inventory_ref[token]}"
    next_url="https://$registry/v2/$repository/tags/list?n=100"

    while [[ -n "$next_url" ]]; do
        verbose "Listing OCI registry tags from: $next_url"
        if ! http_code=$(oci_request_tag_page \
                "$next_url" "$request_headers" "$response_headers" "$response_body"); then
            lookup_status=$LOOKUP_UNAVAILABLE
            break
        fi

        if [[ "$http_code" == 401 && -n "$allow_anonymous_challenge" &&
                -z "${inventory_ref[token]}" ]]; then
            auth_header=$(oci_header_value "$response_headers" WWW-Authenticate)
            if inventory_ref[token]=$(oci_token_from_bearer_challenge \
                    "$auth_header" "$repository"); then
                oci_write_request_headers "$request_headers" "${inventory_ref[token]}"
                continue
            else
                token_status=$?
                lookup_status=$token_status
                break
            fi
        fi

        case "$http_code" in
        200)
            if ! "$JQ" -e '.tags | type == "array"' "$response_body" >/dev/null 2>&1; then
                lookup_status=$LOOKUP_UNAVAILABLE
                break
            fi
            page_tags=$("$JQ" -r '.tags[]?' "$response_body")
            page_tag_count=$("$JQ" -r '.tags | length' "$response_body")
            listed_tag_count=$(( listed_tag_count + page_tag_count ))
            if [[ -n "$page_tags" ]]; then
                inventory_ref[tags]+="${inventory_ref[tags]:+$'\n'}$page_tags"
            fi
            durable_precision=$(durable_semver_precision_from_tags "${inventory_ref[tags]}")
            if [[ "$registry_tag_scan" == any-durable &&
                    -n "${registry_direct_tag_confirmed-}" &&
                    -n "${registry_direct_tag-}" ]] &&
                    tag_is_assumed_durable "$registry_direct_tag" "$durable_precision"; then
                inventory_ref[direct_tag_durable]=1
                next_url=
                continue
            fi
            if [[ "$page_mode" == sample ]]; then
                next_url=
                continue
            fi
            estimated_scan_ms=$(registry_estimated_milliseconds \
                "$listed_tag_count" "$OCI_MAX_PARALLEL_JOBS" \
                "$(( OCI_ESTIMATED_SECONDS_PER_BATCH * 1000 ))")
            if [[ "$page_mode" == inventory &&
                    "$inventory_scan_limit_ms" =~ ^[0-9]+$ ]] &&
                    (( estimated_scan_ms > inventory_scan_limit_ms )); then
                debug "OCI inventory lower bound exceeded the competing backend estimate for $registry/$repository: tags=$listed_tag_count oci_ms=$estimated_scan_ms limit_ms=$inventory_scan_limit_ms"
                lookup_status=$LOOKUP_UNAVAILABLE
                break
            fi
            # Adaptive GHCR selection inventories tags only to compare the two
            # backends. Defer the HEAD cost decision until OCI is actually
            # selected; ordinary full scans can stop during pagination as soon
            # as the observed lower bound is already too expensive.
            if [[ "$page_mode" == full ]]; then
                if is_interactive_session; then
                    threshold_ms=$(( EXPENSIVE_SCAN_THRESHOLD_SECONDS_INTERACTIVE * 1000 ))
                else
                    threshold_ms=$(( EXPENSIVE_SCAN_THRESHOLD_SECONDS_NONINTERACTIVE * 1000 ))
                fi
                if [[ -z "$pagination_cost_advised" ]] &&
                        (( estimated_scan_ms > threshold_ms )); then
                    if ! registry_expensive_work_preflight \
                            'OCI HEAD' "$registry/$repository" \
                            "must already inspect at least $listed_tag_count listed tags" \
                            "$listed_tag_count" "$OCI_MAX_PARALLEL_JOBS" \
                            "$(( OCI_ESTIMATED_SECONDS_PER_BATCH * 1000 ))"; then
                        lookup_status=$LOOKUP_STOPPED
                        break
                    fi
                    pagination_cost_advised=1
                fi
            fi
            next_link=$(oci_next_link "$response_headers")
            case "$next_link" in
            '') next_url= ;;
            /*) next_url="https://$registry$next_link" ;;
            https://"$registry"/*) next_url="$next_link" ;;
            *)
                debug "OCI registry returned an unsafe or unsupported pagination link: $next_link"
                lookup_status=$LOOKUP_UNAVAILABLE
                break
                ;;
            esac
            ;;
        401 | 403) lookup_status=$LOOKUP_DENIED; break ;;
        404) lookup_status=$LOOKUP_NOT_FOUND; break ;;
        429)
            notice "OCI registry rate limited tag listing for $registry/$repository; not falling back to the more request-intensive Skopeo scan."
            lookup_status=$LOOKUP_STOPPED
            break
            ;;
        *) lookup_status=$LOOKUP_UNAVAILABLE; break ;;
        esac
    done

    rm -f "$request_headers" "$response_headers" "$response_body"
    return "$lookup_status"
}

function oci_list_tags_anonymously {
    oci_list_tags "$1" "$2" "${3-full}" '' 1 "${4-}" "$5"
}

function oci_list_tags_with_bearer_token {
    oci_list_tags "$1" "$2" "${4-full}" "$3" '' '' "$5"
}

function oci_digest_for_tag_with_headers {
    local registry="$1"
    local tag="$2"
    local repository="$3"
    local request_headers="$4"
    local tag_encoded manifest_digest response_headers http_code lookup_status

    # shellcheck disable=SC2016  # jq filter uses a literal jq variable
    tag_encoded=$("$JQ" -rn --arg value "$tag" '$value | @uri')
    response_headers=$(runtime_temp_file oci-response-headers)
    if ! http_code=$(registry_http_request HEAD \
            "https://$registry/v2/$repository/manifests/$tag_encoded" \
            /dev/null "$response_headers" -H "@$request_headers" 2>/dev/null); then
        rm -f "$response_headers"
        return "$LOOKUP_UNAVAILABLE"
    fi
    case "$http_code" in
    200) lookup_status=$LOOKUP_SUCCEEDED ;;
    404) lookup_status=$LOOKUP_NOT_FOUND ;;
    401 | 403) lookup_status=$LOOKUP_DENIED ;;
    429) lookup_status=$LOOKUP_STOPPED ;;
    *) lookup_status=$LOOKUP_UNAVAILABLE ;;
    esac
    manifest_digest=$(oci_header_value "$response_headers" Docker-Content-Digest)
    rm -f "$response_headers"
    (( lookup_status == LOOKUP_SUCCEEDED )) || return "$lookup_status"
    [[ -n "$manifest_digest" ]] || return "$LOOKUP_UNAVAILABLE"
    printf '%s\n' "$manifest_digest"
}

function oci_curl_supports_parallel {
    "$CURL" --help all 2>/dev/null | grep -q -- '--parallel-max'
}

# Resolve an exhaustive candidate set in one curl process. curl's parallel
# engine keeps the same bounded concurrency as the Bash pool while reusing and
# multiplexing connections to the registry where the server permits it.
function oci_tags_by_digest_with_curl_parallel {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local candidate_array_name="$4"
    local parallel_jobs="$5"
    local request_headers="$6"
    local -n parallel_candidate_tags="$candidate_array_name"
    local config_tmp error_tmp result_dir header_file tag tag_encoded
    local curl_pid curl_status tag_index http_status manifest_digest
    local checked=0
    local failed=0
    local rate_limited=
    local denied=
    local matches=
    local -a observed=()
    local -a spinner=('|' '/' '-' $'\\')

    config_tmp=$(runtime_temp_file oci-curl-config)
    error_tmp=$(runtime_temp_file oci-curl-error)
    result_dir=$(runtime_temp_dir oci-results)
    printf 'parallel\nparallel-max = %d\n' "$parallel_jobs" >"$config_tmp"
    for (( tag_index = 0; tag_index < ${#parallel_candidate_tags[@]}; ++tag_index )); do
        tag=${parallel_candidate_tags[$tag_index]}
        # shellcheck disable=SC2016  # jq filter uses a literal jq variable
        tag_encoded=$("$JQ" -rn --arg value "$tag" '$value | @uri')
        header_file="$result_dir/$tag_index.headers"
        (( tag_index == 0 )) || printf 'next\n' >>"$config_tmp"
        printf '%s\n' \
            'silent' \
            'show-error' \
            'head' \
            "header = \"@$request_headers\"" \
            "url = \"https://$registry/v2/$repository/manifests/$tag_encoded\"" \
            "dump-header = \"$header_file\"" \
            'output = "/dev/null"' >>"$config_tmp"
        verbose "Queueing OCI registry tag for parallel HEAD: $tag"
    done

    if is_interactive_session; then
        printf 'Searching OCI registry tags with parallel HEAD... %s (0 checked)' \
            "${spinner[0]}" >&2
    fi
    run_network_command "$CURL" --config "$config_tmp" \
        >/dev/null 2>"$error_tmp" &
    curl_pid=$!
    runtime_register_child "$curl_pid"
    while kill -0 "$curl_pid" 2>/dev/null; do
        for (( tag_index = 0; tag_index < ${#parallel_candidate_tags[@]}; ++tag_index )); do
            [[ -z ${observed[tag_index]-} ]] || continue
            header_file="$result_dir/$tag_index.headers"
            [[ -s "$header_file" ]] || continue
            observed[tag_index]=1
            ((++checked))
            http_status=$(oci_http_status "$header_file")
            if [[ "$http_status" == 429 ]]; then
                rate_limited=1
                kill "$curl_pid" 2>/dev/null || true
            fi
            if is_interactive_session; then
                printf '\rSearching OCI registry tags with parallel HEAD... %s (%d checked)' \
                    "${spinner[checked % 4]}" "$checked" >&2
            fi
        done
        [[ -z "$rate_limited" ]] || break
        (( checked == ${#parallel_candidate_tags[@]} )) && break
        sleep 0.1
    done
    if wait "$curl_pid"; then
        curl_status=0
    else
        curl_status=$?
    fi
    runtime_unregister_child "$curl_pid"

    for (( tag_index = 0; tag_index < ${#parallel_candidate_tags[@]}; ++tag_index )); do
        header_file="$result_dir/$tag_index.headers"
        if [[ ! -s "$header_file" ]]; then
            ((++failed))
            continue
        fi
        if [[ -z ${observed[$tag_index]-} ]]; then
            ((++checked))
        fi
        http_status=$(oci_http_status "$header_file")
        manifest_digest=$(oci_header_value "$header_file" Docker-Content-Digest)
        if [[ "$http_status" != 200 || -z "$manifest_digest" ]]; then
            case "$http_status" in
            404) ;;
            401 | 403) denied=1 ;;
            429) rate_limited=1 ;;
            *) ((++failed)) ;;
            esac
            continue
        fi
        if [[ "$manifest_digest" == "$digest" ]]; then
            tag=${parallel_candidate_tags[$tag_index]}
            matches+="${matches:+$'\n'}$tag"
        fi
    done
    if is_interactive_session; then
        printf '\rSearching OCI registry tags with parallel HEAD... done (%d checked)\n' \
            "$checked" >&2
    fi
    if (( curl_status != 0 )); then
        debug "Parallel OCI HEAD curl failed for $registry/$repository: $(tr '\n' ' ' <"$error_tmp")"
    fi

    for (( tag_index = 0; tag_index < ${#parallel_candidate_tags[@]}; ++tag_index )); do
        rm -f "$result_dir/$tag_index.headers"
    done
    rmdir "$result_dir"
    rm -f "$config_tmp" "$error_tmp"
    printf '%s' "$matches"
    if [[ -n "$rate_limited" ]]; then
        notice "OCI registry rate limited manifest HEAD requests for $registry/$repository; not falling back to the more request-intensive Skopeo scan."
        return "$LOOKUP_STOPPED"
    fi
    [[ -z "$denied" ]] || return "$LOOKUP_DENIED"
    (( failed == 0 )) || return "$LOOKUP_UNAVAILABLE"
}

# Resolve one public tag with HEAD without enumerating the repository.
function oci_digest_for_tag {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local initial_token="${4-}"
    local allow_anonymous_challenge="${5-}"
    local request_headers response_headers tag_encoded http_code auth_header token
    local lookup_status=$LOOKUP_SUCCEEDED

    request_headers=$(runtime_temp_file oci-request-headers)
    response_headers=$(runtime_temp_file oci-response-headers)
    token="$initial_token"
    oci_write_request_headers "$request_headers" "$token"
    # shellcheck disable=SC2016  # jq filter uses a literal jq variable
    tag_encoded=$("$JQ" -rn --arg value "$tag" '$value | @uri')
    while true; do
        : >"$response_headers"
        if ! http_code=$(registry_http_request HEAD \
                "https://$registry/v2/$repository/manifests/$tag_encoded" \
                /dev/null "$response_headers" -H "@$request_headers"); then
            lookup_status=$LOOKUP_UNAVAILABLE
            break
        fi
        if [[ "$http_code" == 401 && -n "$allow_anonymous_challenge" &&
                -z "$token" ]]; then
            auth_header=$(oci_header_value "$response_headers" WWW-Authenticate)
            if token=$(oci_token_from_bearer_challenge "$auth_header" "$repository"); then
                oci_write_request_headers "$request_headers" "$token"
                continue
            else
                lookup_status=$?
                break
            fi
        fi
        case "$http_code" in
        200)
            if token=$(oci_header_value "$response_headers" Docker-Content-Digest) &&
                    [[ -n "$token" ]]; then
                printf '%s\n' "$token"
            else
                lookup_status=$LOOKUP_UNAVAILABLE
            fi
            break
            ;;
        404) lookup_status=$LOOKUP_NOT_FOUND; break ;;
        401 | 403) lookup_status=$LOOKUP_DENIED; break ;;
        429)
            notice "OCI registry rate limited manifest HEAD for $registry/$repository:$tag; not falling back to a more request-intensive Skopeo lookup."
            lookup_status=$LOOKUP_STOPPED
            break
            ;;
        *) lookup_status=$LOOKUP_UNAVAILABLE; break ;;
        esac
    done
    rm -f "$request_headers" "$response_headers"
    return "$lookup_status"
}

function oci_digest_for_tag_anonymously {
    oci_digest_for_tag "$1" "$2" "$3" '' 1
}

function oci_digest_for_tag_with_bearer_token {
    oci_digest_for_tag "$1" "$2" "$3" "$4" ''
}

# Print tags whose complete manifest digest matches digest. Individual HEAD
# failures make an exhaustive result fail so the dispatcher can retry through
# Skopeo rather than silently returning an incomplete tag set.
# The inventory's direct_tag_durable flag refers to the caller's registry_direct_tag.
# Scan mode and direct-tag confirmation remain shared registry_* state; this
# function sets registry_durable_semver_precision and registry_seed_matching_tags
# for the scheduler.
function oci_tags_by_digest_from_list {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local -n inventory_ref="$4"
    local display_repository="$registry/$repository"
    local tag request_headers tags lookup_status durable_precision
    local candidate_count parallel_jobs use_parallel
    local -a candidate_tags=()

    durable_precision=$(durable_semver_precision_from_tags "${inventory_ref[tags]}")
    registry_durable_semver_precision="$durable_precision"
    if [[ -n "${inventory_ref[direct_tag_durable]}" ]]; then
        printf '%s\n' "$registry_direct_tag"
        return
    fi
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        if [[ "$registry_tag_scan" == any-durable &&
                -n "${registry_direct_tag_confirmed-}" &&
                "$tag" == "$registry_direct_tag" ]]; then
            registry_seed_matching_tags="$tag"
            continue
        fi
        candidate_tags+=("$tag")
    done <<<"${inventory_ref[tags]}"

    candidate_count=${#candidate_tags[@]}
    parallel_jobs=$OCI_MAX_PARALLEL_JOBS
    (( candidate_count < parallel_jobs )) && parallel_jobs=$candidate_count
    (( parallel_jobs > 0 )) || parallel_jobs=1
    registry_expensive_scan_preflight \
        'OCI HEAD' "$display_repository" "$candidate_count" "$parallel_jobs" \
        "$OCI_ESTIMATED_SECONDS_PER_BATCH" || return $?

    # Keep engine selection automatic: Codeberg benchmarks showed curl's
    # connection-reusing parallel engine is materially faster for exhaustive
    # scans, while the rolling pool remains the compatibility fallback.
    use_parallel=
    if [[ "$registry_tag_scan" == all ]] &&
            (( candidate_count > 1 )) && oci_curl_supports_parallel; then
        use_parallel=1
    fi

    request_headers=$(runtime_temp_file oci-request-headers)
    oci_write_request_headers "$request_headers" "${inventory_ref[token]}"
    if [[ -n "$use_parallel" ]]; then
        if tags=$(oci_tags_by_digest_with_curl_parallel \
                "$registry" "$repository" "$digest" candidate_tags \
                "$parallel_jobs" "$request_headers"); then
            lookup_status=$LOOKUP_SUCCEEDED
        else
            lookup_status=$?
        fi
    elif tags=$(tags_by_digest_with_rolling_pool \
            "$registry" "$digest" candidate_tags "$parallel_jobs" \
            'Searching OCI registry tags with HEAD' \
            'Resolving OCI registry tag with HEAD' \
            oci_digest_for_tag_with_headers 1 "$repository" "$request_headers"); then
        lookup_status=$LOOKUP_SUCCEEDED
    else
        lookup_status=$?
    fi
    rm -f "$request_headers"
    (( lookup_status == LOOKUP_SUCCEEDED )) || return "$lookup_status"
    printf '%s' "$tags"
}

function oci_tags_by_digest {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local supplied_token="${4-}"
    local allow_anonymous_challenge="${5-}"
    local -A inventory=()

    if [[ -n "$allow_anonymous_challenge" ]]; then
        oci_list_tags_anonymously "$registry" "$repository" full '' inventory || return $?
    else
        oci_list_tags_with_bearer_token \
            "$registry" "$repository" "$supplied_token" full inventory || return $?
    fi
    oci_tags_by_digest_from_list "$registry" "$repository" "$digest" inventory
}

function oci_tags_by_digest_anonymously {
    oci_tags_by_digest "$1" "$2" "$3" '' 1
}

function oci_tags_by_digest_with_bearer_token {
    oci_tags_by_digest "$1" "$2" "$3" "$4" ''
}

function oci_policy_attempt_public {
    local request_name="$1"
    local result_name="$2"
    local -n request_ref="$request_name"
    local -n result_ref="$result_name"
    local output status registry="${request_ref[oci_registry]-${request_ref[registry]}}"

    if [[ "${request_ref[operation]}" == direct ]]; then
        if output=$(oci_digest_for_tag_anonymously \
                "$registry" "${request_ref[repository]}" \
                "${request_ref[tag]}"); then
            result_ref[digest]="$output"
            return "$LOOKUP_SUCCEEDED"
        else
            return $?
        fi
    fi

    if output=$(oci_tags_by_digest_anonymously \
            "$registry" "${request_ref[repository]}" \
            "${request_ref[digest]}"); then
        result_ref[tags]="$output"
        return "$LOOKUP_SUCCEEDED"
    else
        status=$?
    fi
    return "$status"
}

function oci_register_policy_attempts {
    local request_name="$1"

    policy_add_attempt oci-public oci_policy_attempt_public \
        oci-registry-api "$POLICY_ACCESS_PUBLIC" 20
    skopeo_register_policy_attempts "$request_name" oci 70
}
