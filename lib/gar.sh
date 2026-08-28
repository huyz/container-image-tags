# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # standalone module lint: shared input/output fields

# Google registry access. GAR uses its authenticated DockerImage resource for
# indexed digest-to-tags lookup when credentials are allowed, the shared OCI
# engine for public and token-authenticated registry access, and Skopeo as the
# compatibility fallback. GCR also reuses the token helper for its digest-keyed
# metadata endpoint.

function gar_access_token {
    local registry="$1"
    local token

    command -v "${GCLOUD:=gcloud}" &>/dev/null || {
        warn "Install Google Cloud CLI and run 'gcloud auth login' to access private Google registry '$registry'"
        return "$LOOKUP_UNAVAILABLE"
    }
    notice "Requesting a short-lived token from Google Cloud CLI for '$registry'."
    token=$("$GCLOUD" auth print-access-token --quiet) || {
        warn "Google Cloud CLI authentication failed for registry '$registry'"
        return "$LOOKUP_UNAVAILABLE"
    }
    [[ -n "$token" ]] || return "$LOOKUP_UNAVAILABLE"
    printf '%s\n' "$token"
}

# Probe configured Google Cloud CLI credentials without turning an ordinary
# public GAR lookup into a warning. The default if-faster policy uses this to
# select the indexed DockerImage API only when a token is already available.
function gar_access_token_if_available {
    local token error_tmp

    command -v "${GCLOUD:=gcloud}" &>/dev/null || return "$LOOKUP_UNAVAILABLE"
    error_tmp=$(runtime_temp_file gar-token-error)
    if token=$("$GCLOUD" auth print-access-token --quiet 2>"$error_tmp") &&
            [[ -n "$token" ]]; then
        rm -f "$error_tmp"
        printf '%s\n' "$token"
        return "$LOOKUP_SUCCEEDED"
    fi
    debug "Configured Google Cloud credentials are unavailable: $(command_error_single_line "$error_tmp")"
    rm -f "$error_tmp"
    return "$LOOKUP_UNAVAILABLE"
}

# Print the location, project ID, repository name, and image path represented
# by one GAR reference. Docker writes a domain-scoped project ID's colon as a
# slash, so restore it when the first path component is a domain name.
function gar_api_resource_parts {
    local registry="$1"
    local display_repository="$2"
    local location path first remainder project repository image

    [[ "$registry" == *-docker.pkg.dev ]] || return "$LOOKUP_UNAVAILABLE"
    location="${registry%-docker.pkg.dev}"
    path="${display_repository#"$registry"/}"
    [[ "$path" != "$display_repository" && "$path" == */*/* ]] ||
        return "$LOOKUP_UNAVAILABLE"

    first="${path%%/*}"
    remainder="${path#*/}"
    if [[ "$first" == *.* ]]; then
        [[ "$remainder" == */*/* ]] || return "$LOOKUP_UNAVAILABLE"
        project="$first:${remainder%%/*}"
        remainder="${remainder#*/}"
    else
        project="$first"
    fi
    repository="${remainder%%/*}"
    image="${remainder#*/}"
    [[ -n "$location" && -n "$project" && -n "$repository" &&
            -n "$image" && "$image" != "$remainder" ]] ||
        return "$LOOKUP_UNAVAILABLE"

    printf '%s\n%s\n%s\n%s\n' "$location" "$project" "$repository" "$image"
}

# Fetch one digest-addressed Artifact Registry DockerImage resource. A 404 is
# not authoritative for remote or virtual repositories, whose registry path
# may resolve an upstream image that is absent from this repository's metadata
# index. Treat it as unavailable so OCI can verify the digest before reporting
# not-found.
function gar_docker_image_metadata {
    local registry="$1"
    local display_repository="$2"
    local digest="$3"
    local token="$4"
    local location project repository image
    local location_encoded project_encoded repository_encoded image_encoded
    local request_headers response_tmp http_code error_message expected_uri
    local -a resource_parts=()

    readarray -t resource_parts < <(
        gar_api_resource_parts "$registry" "$display_repository"
    )
    (( ${#resource_parts[@]} == 4 )) || return "$LOOKUP_UNAVAILABLE"
    location="${resource_parts[0]}"
    project="${resource_parts[1]}"
    repository="${resource_parts[2]}"
    image="${resource_parts[3]}@$digest"
    location_encoded=$("$JQ" -rn --arg value "$location" '$value | @uri')
    project_encoded=$("$JQ" -rn --arg value "$project" '$value | @uri')
    repository_encoded=$("$JQ" -rn --arg value "$repository" '$value | @uri')
    image_encoded=$("$JQ" -rn --arg value "$image" '$value | @uri')

    request_headers=$(runtime_temp_file gar-api-headers)
    response_tmp=$(runtime_temp_file gar-api-response)
    chmod 600 "$request_headers"
    printf 'Authorization: Bearer %s\n' "$token" >"$request_headers"
    if ! http_code=$(registry_http_request GET \
            "https://artifactregistry.googleapis.com/v1/projects/$project_encoded/locations/$location_encoded/repositories/$repository_encoded/dockerImages/$image_encoded" \
            "$response_tmp" '' -H "@$request_headers"); then
        rm -f "$request_headers" "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
    rm -f "$request_headers"

    error_message=$(registry_json_error_message "$response_tmp")
    case "$http_code" in
    200)
        expected_uri="$display_repository@$digest"
        if ! "$JQ" -e --arg expected_uri "$expected_uri" '
                .uri == $expected_uri and
                ((.tags // []) | type == "array") and
                all((.tags // [])[]; type == "string")
            ' "$response_tmp" >/dev/null; then
            debug "GAR DockerImage metadata for $expected_uri had an unexpected response shape"
            rm -f "$response_tmp"
            return "$LOOKUP_UNAVAILABLE"
        fi
        cat "$response_tmp"
        rm -f "$response_tmp"
        ;;
    401 | 403)
        debug "GAR DockerImage metadata was denied for $display_repository@$digest (HTTP $http_code)${error_message:+: $error_message}"
        rm -f "$response_tmp"
        return "$LOOKUP_DENIED"
        ;;
    404)
        debug "GAR DockerImage metadata did not contain $display_repository@$digest; verifying through the registry path"
        rm -f "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
        ;;
    429)
        notice "GAR DockerImage API rate limited metadata for $display_repository; not falling back to a more request-intensive registry scan."
        rm -f "$response_tmp"
        return "$LOOKUP_STOPPED"
        ;;
    *)
        debug "GAR DockerImage metadata failed for $display_repository@$digest (HTTP $http_code)${error_message:+: $error_message}"
        rm -f "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
        ;;
    esac
}

function gar_tags_by_digest_api {
    local registry="$1"
    local display_repository="$2"
    local digest="$3"
    local token="$4"
    local metadata matching_tags tag_prefix

    metadata=$(gar_docker_image_metadata \
        "$registry" "$display_repository" "$digest" "$token") || return $?
    tag_prefix="$display_repository:"
    if ! "$JQ" -e --arg prefix "$tag_prefix" '
            all((.tags // [])[]; startswith($prefix))
        ' >/dev/null <<<"$metadata"; then
        debug "GAR DockerImage metadata returned a tag outside $display_repository"
        return "$LOOKUP_UNAVAILABLE"
    fi
    matching_tags=$("$JQ" -r --arg prefix "$tag_prefix" '
        [(.tags // [])[] | .[($prefix | length):]]
        | reduce .[] as $tag ([]; if index($tag) then . else . + [$tag] end)
        | .[]
    ' <<<"$metadata")
    select_matching_tags_for_scan "$matching_tags" "$matching_tags" || true
}

function gar_authenticate {
    local registry="$1"

    command -v "${GCLOUD:=gcloud}" &>/dev/null || {
        warn "Install Google Cloud CLI and run 'gcloud auth login' to access private Google registry '$registry'"
        return 1
    }

    notice "Google registry denied anonymous access; retrying with a short-lived token from Google Cloud CLI."
    if ! "$GCLOUD" auth print-access-token --quiet |
            "$SKOPEO" login --authfile "$skopeo_session_authfile" \
                --username oauth2accesstoken --password-stdin "$registry" >/dev/null; then
        warn "Google Cloud CLI authentication failed for registry '$registry'"
        return 1
    fi
}

# Skopeo reports only the HTTP status for some Google registry token failures,
# while Docker's manifest client can preserve the registry's response body.
# Make this extra network request only in debug mode and return just the
# registry-provided denial reason when one is available.
function gar_debug_denial_detail {
    local image_reference="$1"
    local docker_error error_tmp

    [[ -n ${opt_debug-} ]] || return 1
    command -v "$DOCKER" &>/dev/null || return 1

    debug "Requesting a Docker manifest diagnostic for $image_reference after the authenticated Skopeo request was denied"
    error_tmp=$(runtime_temp_file gar-debug-error)
    if "$DOCKER" manifest inspect "$image_reference" >/dev/null 2>"$error_tmp"; then
        rm -f "$error_tmp"
        debug "Docker manifest inspection succeeded for $image_reference but provided no denial detail"
        return 1
    fi

    docker_error=$(tr '\r\n' '  ' <"$error_tmp" | sed -E 's/[[:space:]]+$//')
    rm -f "$error_tmp"
    if [[ "$docker_error" != *'denied: '* ]]; then
        debug "Docker manifest diagnostic for $image_reference did not include a registry denial reason: $docker_error"
        return 1
    fi

    printf '%s\n' "${docker_error#*denied: }"
}

function gar_digest_for_tag {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local image_reference="$4"
    local digest lookup_status token

    if credential_policy_allows_public; then
        if digest=$(oci_digest_for_tag_anonymously "$registry" "$repository" "$tag"); then
            printf '%s\n' "$digest"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
        case "$lookup_status" in
        "$LOOKUP_NOT_FOUND" | "$LOOKUP_STOPPED") return "$lookup_status" ;;
        esac
    else
        lookup_status=$LOOKUP_DENIED
    fi

    if credential_policy_allows_auth_after "$lookup_status"; then
        if token=$(gar_access_token "$registry") &&
                digest=$(oci_digest_for_tag_with_bearer_token \
                    "$registry" "$repository" "$tag" "$token"); then
            printf '%s\n' "$digest"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
        case "$lookup_status" in
        "$LOOKUP_NOT_FOUND" | "$LOOKUP_STOPPED") return "$lookup_status" ;;
        esac
    fi

    skopeo_is_available || return "$lookup_status"
    if digest=$(skopeo_digest_for_tag_with_access_policy \
            "$registry" "$image_reference" gar_authenticate "$lookup_status"); then
        printf '%s\n' "$digest"
        return "$LOOKUP_SUCCEEDED"
    else
        lookup_status=$?
    fi
    if (( lookup_status == LOOKUP_DENIED )); then
        gar_debug_denial_detail "$image_reference" || true
    fi
    return "$lookup_status"
}

function gar_resolve_tag {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local display_reference="$4"
    local lookup_output

    if lookup_output=$(gar_digest_for_tag \
            "$registry" "$repository" "$tag" "$display_reference"); then
        remote_tag_digest="$lookup_output"
        remote_tag_status=$LOOKUP_SUCCEEDED
    else
        remote_tag_status=$?
        remote_tag_error="$lookup_output"
    fi
}

function gar_find_tags {
    local registry="$1"
    local display_repository="$2"
    local digest="$3"

    local oci_repository="${display_repository#*/}"
    local lookup_status=$LOOKUP_UNAVAILABLE
    local auth_trigger_status=$LOOKUP_UNAVAILABLE
    local token api_attempted=

    # The digest-addressed DockerImage resource returns all attached tags in
    # one request. Probe existing gcloud credentials under if-faster; require
    # emits the normal actionable credential diagnostics.
    if credential_policy_prefers_fast_credentials; then
        registry_lookup_backend=gar-api
        if [[ "${opt_credential_policy:-if-faster}" == require ]]; then
            token=$(gar_access_token "$registry") || lookup_status=$?
        else
            token=$(gar_access_token_if_available) || lookup_status=$?
        fi
        if [[ -n "$token" ]]; then
            api_attempted=1
            if registry_tags=$(gar_tags_by_digest_api \
                    "$registry" "$display_repository" "$digest" "$token"); then
                return
            else
                lookup_status=$?
            fi
            (( lookup_status == LOOKUP_STOPPED )) &&
                abort "GAR DockerImage API lookup stopped for $display_repository"
        fi
    fi

    if credential_policy_allows_public; then
        registry_lookup_backend=oci-registry-api
        if registry_tags=$(oci_tags_by_digest_anonymously \
                "$registry" "$oci_repository" "$digest"); then
            return
        else
            lookup_status=$?
        fi
        auth_trigger_status=$lookup_status
        case "$lookup_status" in
        "$LOOKUP_NOT_FOUND") registry_lookup_result=not_found; return ;;
        "$LOOKUP_STOPPED") abort "Google registry OCI lookup stopped for $display_repository" ;;
        esac
    else
        lookup_status=$LOOKUP_DENIED
        auth_trigger_status=$LOOKUP_DENIED
    fi

    # A token acquired for the fast metadata path can also authenticate the
    # OCI compatibility path. Public-first policies acquire it only after an
    # explicit registry denial.
    if [[ -n "$token" ]] ||
            credential_policy_allows_auth_after "$auth_trigger_status"; then
        if [[ -z "$token" ]]; then
            token=$(gar_access_token "$registry") || lookup_status=$?
        fi
        if [[ -n "$token" && -z "$api_attempted" ]]; then
            registry_lookup_backend=gar-api
            api_attempted=1
            if registry_tags=$(gar_tags_by_digest_api \
                    "$registry" "$display_repository" "$digest" "$token"); then
                return
            else
                lookup_status=$?
            fi
            (( lookup_status == LOOKUP_STOPPED )) &&
                abort "GAR DockerImage API lookup stopped for $display_repository"
        fi
        if [[ -n "$token" ]]; then
            registry_lookup_backend=oci-registry-api
            if registry_tags=$(oci_tags_by_digest_with_bearer_token \
                    "$registry" "$oci_repository" "$digest" "$token"); then
                return
            else
                lookup_status=$?
            fi
            case "$lookup_status" in
            "$LOOKUP_NOT_FOUND") registry_lookup_result=not_found; return ;;
            "$LOOKUP_STOPPED") abort "Google registry OCI lookup stopped for $display_repository" ;;
            esac
            if (( auth_trigger_status == LOOKUP_DENIED )); then
                lookup_status=$LOOKUP_DENIED
            fi
        fi
    fi

    notice "GAR fast paths did not complete for $display_repository; falling back to Skopeo"
    registry_lookup_backend=skopeo
    skopeo_is_available || abort "Install skopeo to query registry '$registry'"
    registry_tags=$(skopeo_tags_by_digest_with_access_policy \
        "$registry" "$display_repository" "$digest" gar_authenticate \
        "$lookup_status") || abort "Google registry lookup failed for $display_repository"
}
