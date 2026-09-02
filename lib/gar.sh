# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2178  # standalone module lint: shared fields and namerefs

# Google registry access. GAR uses its DockerImage resource anonymously for
# public indexed digest-to-tags lookup and retries it with a Google token after
# denial. The shared OCI engine and Skopeo remain compatibility fallbacks. GCR
# also reuses the token helper for its digest-keyed metadata endpoint.

function gar_access_token {
    local registry="$1"
    local token

    command -v "${GCLOUD:=gcloud}" &>/dev/null || {
        warn "Install Google Cloud CLI and run 'gcloud auth login' to access private Google registry '$registry'"
        return "$LOOKUP_UNAVAILABLE"
    }
    notice "Requesting a short-lived token from Google Cloud CLI for '$registry'."
    token=$(run_network_command "$GCLOUD" auth print-access-token --quiet) || {
        warn "Google Cloud CLI authentication failed for registry '$registry'"
        return "$LOOKUP_UNAVAILABLE"
    }
    [[ -n "$token" ]] || return "$LOOKUP_UNAVAILABLE"
    printf '%s\n' "$token"
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
    local -a resource_parts=() request_args=()

    readarray -t resource_parts < <(
        gar_api_resource_parts "$registry" "$display_repository"
    )
    (( ${#resource_parts[@]} == 4 )) || return "$LOOKUP_UNAVAILABLE"
    location="${resource_parts[0]}"
    project="${resource_parts[1]}"
    repository="${resource_parts[2]}"
    image="${resource_parts[3]}@$digest"
    # shellcheck disable=SC2016  # jq filter uses a literal jq variable
    location_encoded=$("$JQ" -rn --arg value "$location" '$value | @uri')
    # shellcheck disable=SC2016  # jq filter uses a literal jq variable
    project_encoded=$("$JQ" -rn --arg value "$project" '$value | @uri')
    # shellcheck disable=SC2016  # jq filter uses a literal jq variable
    repository_encoded=$("$JQ" -rn --arg value "$repository" '$value | @uri')
    # shellcheck disable=SC2016  # jq filter uses a literal jq variable
    image_encoded=$("$JQ" -rn --arg value "$image" '$value | @uri')

    request_headers=$(runtime_temp_file gar-api-headers)
    response_tmp=$(runtime_temp_file gar-api-response)
    if [[ -n "$token" ]]; then
        chmod 600 "$request_headers"
        printf 'Authorization: Bearer %s\n' "$token" >"$request_headers"
        request_args+=(-H "@$request_headers")
    fi
    if ! http_code=$(registry_http_request GET \
            "https://artifactregistry.googleapis.com/v1/projects/$project_encoded/locations/$location_encoded/repositories/$repository_encoded/dockerImages/$image_encoded" \
            "$response_tmp" '' "${request_args[@]}"); then
        rm -f "$request_headers" "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
    rm -f "$request_headers"

    error_message=$(registry_json_error_message "$response_tmp")
    case "$http_code" in
    200)
        expected_uri="$display_repository@$digest"
        # shellcheck disable=SC2016  # jq filter uses a literal jq variable
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
    # shellcheck disable=SC2016  # jq filter uses a literal jq variable
    if ! "$JQ" -e --arg prefix "$tag_prefix" '
            all((.tags // [])[]; startswith($prefix))
        ' >/dev/null <<<"$metadata"; then
        debug "GAR DockerImage metadata returned a tag outside $display_repository"
        return "$LOOKUP_UNAVAILABLE"
    fi
    # shellcheck disable=SC2016  # jq filter uses a literal jq variable
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
    if ! run_network_command "$GCLOUD" auth print-access-token --quiet |
            run_network_command "$SKOPEO" login \
                --authfile "$skopeo_session_authfile" \
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
    if run_network_command "$DOCKER" manifest inspect \
            "$image_reference" >/dev/null 2>"$error_tmp"; then
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

function gar_policy_get_token {
    local request_name="$1"
    local -n request_ref="$request_name"
    local token

    if [[ -n "${request_ref[provider_token]-}" ]]; then
        return 0
    fi
    token=$(gar_access_token "${request_ref[registry]}") || return 1
    request_ref[provider_token]="$token"
}

function gar_policy_attempt_oci_token {
    local request_name="$1"
    local result_name="$2"
    local -n request_ref="$request_name"
    local -n result_ref="$result_name"
    local output status

    gar_policy_get_token "$request_name" || return "$LOOKUP_UNAVAILABLE"
    if [[ "${request_ref[operation]}" == direct ]]; then
        if output=$(oci_digest_for_tag_with_bearer_token \
                "${request_ref[registry]}" "${request_ref[repository]}" \
                "${request_ref[tag]}" "${request_ref[provider_token]}"); then
            result_ref[digest]="$output"
            return "$LOOKUP_SUCCEEDED"
        else
            return $?
        fi
    fi
    if output=$(oci_tags_by_digest_with_bearer_token \
            "${request_ref[registry]}" "${request_ref[repository]}" \
            "${request_ref[digest]}" "${request_ref[provider_token]}"); then
        result_ref[tags]="$output"
        return "$LOOKUP_SUCCEEDED"
    else
        status=$?
    fi
    return "$status"
}

function gar_policy_attempt_api {
    local request_name="$1"
    local result_name="$2"
    local -n request_ref="$request_name"
    local -n result_ref="$result_name"
    local access_mode="${3-public}"
    local output status token=

    if [[ "$access_mode" == credential ]]; then
        gar_policy_get_token "$request_name" || return "$LOOKUP_UNAVAILABLE"
        token="${request_ref[provider_token]}"
    fi
    if output=$(gar_tags_by_digest_api \
            "${request_ref[registry]}" "${request_ref[display_repository]}" \
            "${request_ref[digest]}" "$token"); then
        result_ref[tags]="$output"
        return "$LOOKUP_SUCCEEDED"
    else
        status=$?
    fi
    return "$status"
}

function gar_policy_attempt_api_with_token {
    gar_policy_attempt_api "$1" "$2" credential
}

function gar_register_policy_attempts {
    local request_name="$1"
    local -n request_ref="$request_name"

    request_ref[provider_auth_callback]=gar_authenticate
    if [[ "${request_ref[operation]}" == reverse ]]; then
        policy_add_attempt gar-api-public gar_policy_attempt_api \
            gar-api "$POLICY_ACCESS_PUBLIC" 10 0
    fi
    policy_add_attempt gar-oci-public oci_policy_attempt_public \
        oci-registry-api "$POLICY_ACCESS_PUBLIC" 20
    if [[ "${request_ref[operation]}" == reverse ]]; then
        policy_add_attempt gar-api-token gar_policy_attempt_api_with_token \
            gar-api "$POLICY_ACCESS_CREDENTIAL" 15 0
    fi
    policy_add_attempt gar-oci-token gar_policy_attempt_oci_token \
        oci-registry-api "$POLICY_ACCESS_CREDENTIAL" 30
    skopeo_register_policy_attempts "$request_name" gar 70
}
