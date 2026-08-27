# shellcheck shell=bash

# Anonymous OCI Distribution fast path for public registries. List tags once,
# obtain at most one repository-scoped bearer token, then resolve tag digests
# with lightweight manifest HEAD requests. Private or incompatible registries
# fall back to Skopeo so configured credential helpers continue to work.

readonly OCI_MAX_PARALLEL_JOBS=8
readonly OCI_ESTIMATED_SECONDS_PER_BATCH=1
readonly OCI_MANIFEST_ACCEPT_HEADER='Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

oci_bearer_token=
oci_listed_tags=
oci_direct_tag_durable=

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

    response_tmp=$(mktemp)
    token_args=(-sS -G -o "$response_tmp" -w '%{http_code}')
    [[ -z "$service" ]] || token_args+=(--data-urlencode "service=$service")
    token_args+=(--data-urlencode "scope=$scope")
    if ! http_code=$("$CURL" "${token_args[@]}" "$realm"); then
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
    "$CURL" -sS -H "@$request_headers" -D "$response_headers" \
        -o "$response_body" -w '%{http_code}' "$url"
}

# Populate oci_listed_tags and oci_bearer_token. Return LOOKUP_SUCCEEDED for a
# complete list, LOOKUP_NOT_FOUND for an unavailable repository,
# LOOKUP_UNAVAILABLE for an unsupported/failed fast path, LOOKUP_DENIED for
# access denial, and LOOKUP_STOPPED for rate limiting.
function oci_list_tags_anonymously {
    local registry="$1"
    local repository="$2"
    local page_mode="${3-full}"
    local request_headers response_headers response_body
    local next_url next_link page_tags auth_header http_code token_status durable_precision
    local lookup_status=$LOOKUP_SUCCEEDED

    oci_bearer_token=
    oci_listed_tags=
    oci_direct_tag_durable=
    request_headers=$(mktemp)
    response_headers=$(mktemp)
    response_body=$(mktemp)
    oci_write_request_headers "$request_headers"
    next_url="https://$registry/v2/$repository/tags/list?n=100"

    while [[ -n "$next_url" ]]; do
        verbose "Listing OCI registry tags from: $next_url"
        if ! http_code=$(oci_request_tag_page \
                "$next_url" "$request_headers" "$response_headers" "$response_body"); then
            lookup_status=$LOOKUP_UNAVAILABLE
            break
        fi

        if [[ "$http_code" == 401 && -z "$oci_bearer_token" ]]; then
            auth_header=$(oci_header_value "$response_headers" WWW-Authenticate)
            if oci_bearer_token=$(oci_token_from_bearer_challenge \
                    "$auth_header" "$repository"); then
                oci_write_request_headers "$request_headers" "$oci_bearer_token"
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
            if [[ -n "$page_tags" ]]; then
                oci_listed_tags+="${oci_listed_tags:+$'\n'}$page_tags"
            fi
            durable_precision=$(durable_semver_precision_from_tags "$oci_listed_tags")
            if [[ "$registry_tag_scan" == any &&
                    -n "${registry_direct_tag_confirmed-}" &&
                    -n "${registry_direct_tag-}" ]] &&
                    tag_is_assumed_durable "$registry_direct_tag" "$durable_precision"; then
                oci_direct_tag_durable=1
                next_url=
                continue
            fi
            if [[ "$page_mode" == sample ]]; then
                next_url=
                continue
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

function oci_digest_for_tag_with_headers {
    local registry="$1"
    local tag="$2"
    local repository="$3"
    local request_headers="$4"
    local tag_encoded manifest_digest response_headers http_code lookup_status

    tag_encoded=$("$JQ" -rn --arg value "$tag" '$value | @uri')
    response_headers=$(mktemp)
    if ! http_code=$(
        "$CURL" -sS -I -H "@$request_headers" -D "$response_headers" \
            -o /dev/null -w '%{http_code}' \
            "https://$registry/v2/$repository/manifests/$tag_encoded" 2>/dev/null
    ); then
        rm -f "$response_headers"
        return "$LOOKUP_UNAVAILABLE"
    fi
    case "$http_code" in
    200) lookup_status=$LOOKUP_SUCCEEDED ;;
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
    local matches=
    local -a observed=()
    local -a spinner=('|' '/' '-' $'\\')

    config_tmp=$(mktemp)
    error_tmp=$(mktemp)
    result_dir=$(mktemp -d)
    printf 'parallel\nparallel-max = %d\n' "$parallel_jobs" >"$config_tmp"
    for (( tag_index = 0; tag_index < ${#parallel_candidate_tags[@]}; ++tag_index )); do
        tag=${parallel_candidate_tags[$tag_index]}
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
    "$CURL" --config "$config_tmp" >/dev/null 2>"$error_tmp" &
    curl_pid=$!
    while kill -0 "$curl_pid" 2>/dev/null; do
        for (( tag_index = 0; tag_index < ${#parallel_candidate_tags[@]}; ++tag_index )); do
            [[ -z ${observed[$tag_index]-} ]] || continue
            header_file="$result_dir/$tag_index.headers"
            [[ -s "$header_file" ]] || continue
            observed[$tag_index]=1
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
            ((++failed))
            [[ "$http_status" == 429 ]] && rate_limited=1
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
    (( failed == 0 )) || return "$LOOKUP_UNAVAILABLE"
}

# Resolve one public tag with HEAD without enumerating the repository.
function oci_digest_for_tag_anonymously {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local request_headers response_headers tag_encoded http_code auth_header token
    local lookup_status=$LOOKUP_SUCCEEDED

    request_headers=$(mktemp)
    response_headers=$(mktemp)
    oci_write_request_headers "$request_headers"
    tag_encoded=$("$JQ" -rn --arg value "$tag" '$value | @uri')
    while true; do
        : >"$response_headers"
        if ! http_code=$(
            "$CURL" -sS -I -H "@$request_headers" -D "$response_headers" \
                -o /dev/null -w '%{http_code}' \
                "https://$registry/v2/$repository/manifests/$tag_encoded"
        ); then
            lookup_status=$LOOKUP_UNAVAILABLE
            break
        fi
        if [[ "$http_code" == 401 && -z "${token-}" ]]; then
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

# Print tags whose complete manifest digest matches digest. Individual HEAD
# failures make an exhaustive result fail so the dispatcher can retry through
# Skopeo rather than silently returning an incomplete tag set.
function oci_tags_by_digest_anonymously {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local display_repository="$registry/$repository"
    local tag request_headers tags lookup_status durable_precision
    local candidate_count parallel_jobs scan_engine use_parallel
    local -a candidate_tags=()

    oci_list_tags_anonymously "$registry" "$repository" || return $?
    durable_precision=$(durable_semver_precision_from_tags "$oci_listed_tags")
    registry_durable_semver_precision="$durable_precision"
    if [[ -n "$oci_direct_tag_durable" ]]; then
        printf '%s\n' "$registry_direct_tag"
        return
    fi
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        if [[ "$registry_tag_scan" == any &&
                -n "${registry_direct_tag_confirmed-}" &&
                "$tag" == "$registry_direct_tag" ]]; then
            registry_seed_matching_tags="$tag"
            continue
        fi
        candidate_tags+=("$tag")
    done <<<"$oci_listed_tags"

    candidate_count=${#candidate_tags[@]}
    parallel_jobs=$OCI_MAX_PARALLEL_JOBS
    (( candidate_count < parallel_jobs )) && parallel_jobs=$candidate_count
    (( parallel_jobs > 0 )) || parallel_jobs=1
    registry_expensive_scan_preflight \
        'OCI HEAD' "$display_repository" "$candidate_count" "$parallel_jobs" \
        "$OCI_ESTIMATED_SECONDS_PER_BATCH" || return $?

    scan_engine=${CIT_OCI_SCAN_ENGINE:-auto}
    use_parallel=
    case "$scan_engine" in
    auto)
        if [[ "$registry_tag_scan" == all ]] &&
                (( candidate_count > 1 )) && oci_curl_supports_parallel; then
            use_parallel=1
        fi
        ;;
    parallel)
        if [[ "$registry_tag_scan" == all ]] && (( candidate_count > 1 )); then
            oci_curl_supports_parallel ||
                abort "CIT_OCI_SCAN_ENGINE=parallel requires curl --parallel-max support"
            use_parallel=1
        fi
        ;;
    pool) ;;
    *)
        abort "CIT_OCI_SCAN_ENGINE must be 'auto', 'parallel', or 'pool'"
        ;;
    esac

    request_headers=$(mktemp)
    oci_write_request_headers "$request_headers" "$oci_bearer_token"
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
