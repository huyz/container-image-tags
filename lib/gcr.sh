# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2178  # standalone module lint: shared fields and namerefs

# Google Container Registry's tags/list response includes a manifest object
# keyed by complete digest, with each value carrying its current tags. Use that
# provider extension to avoid one manifest request per tag. Use it first with
# public access and then, after denial, with a short-lived Google token. Skopeo
# remains the compatibility fallback.

# Print one GCR tags/list response. Use the shared LOOKUP_* status contract to
# distinguish success, an unavailable repository, transport/response failures,
# and access denial.
function gcr_metadata {
    local registry="$1"
    local repository="$2"
    local bearer_token="${3-}"
    local response_tmp request_headers http_code error_message

    response_tmp=$(runtime_temp_file gcr-response)
    request_headers=$(runtime_temp_file gcr-request-headers)
    : >"$request_headers"
    chmod 600 "$request_headers"
    [[ -z "$bearer_token" ]] ||
        printf 'Authorization: Bearer %s\n' "$bearer_token" >"$request_headers"
    if ! http_code=$(registry_http_request GET \
            "https://$registry/v2/$repository/tags/list" "$response_tmp" '' \
            -H "@$request_headers"); then
        rm -f "$response_tmp" "$request_headers"
        return "$LOOKUP_UNAVAILABLE"
    fi
    rm -f "$request_headers"

    error_message=$(registry_json_error_message "$response_tmp")
    case "$http_code" in
    200)
        if ! "$JQ" -e '.manifest | type == "object"' "$response_tmp" >/dev/null; then
            debug "GCR tag listing for $registry/$repository did not include a manifest map"
            rm -f "$response_tmp"
            return "$LOOKUP_UNAVAILABLE"
        fi
        cat "$response_tmp"
        rm -f "$response_tmp"
        ;;
    401 | 403)
        debug "Anonymous GCR tag listing was denied for $registry/$repository (HTTP $http_code)${error_message:+: $error_message}"
        rm -f "$response_tmp"
        return "$LOOKUP_DENIED"
        ;;
    404)
        rm -f "$response_tmp"
        return "$LOOKUP_NOT_FOUND"
        ;;
    429)
        notice "GCR rate limited tag metadata for $registry/$repository; not falling back to the more request-intensive Skopeo scan."
        rm -f "$response_tmp"
        return "$LOOKUP_STOPPED"
        ;;
    *)
        debug "GCR tag listing failed for $registry/$repository (HTTP $http_code)${error_message:+: $error_message}"
        rm -f "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
        ;;
    esac
}

function gcr_metadata_anonymously {
    gcr_metadata "$1" "$2"
}

# Resolve one current tag from GCR's digest-keyed manifest map.
function gcr_digest_for_tag_from_metadata {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local metadata_function="$4"
    local bearer_token="${5-}"
    local metadata digests

    metadata=$("$metadata_function" \
        "$registry" "$repository" "$bearer_token") || return $?
    # shellcheck disable=SC2016  # jq filter uses a literal jq variable
    digests=$(
        "$JQ" -r --arg tag "$tag" '
            .manifest
            | to_entries[]
            | select((.value.tag // []) | index($tag) != null)
            | .key
        ' <<<"$metadata"
    )
    [[ -n "$digests" ]] || return "$LOOKUP_NOT_FOUND"
    if [[ "$digests" == *$'\n'* ]]; then
        debug "GCR returned multiple current digests for $registry/$repository:$tag"
        return "$LOOKUP_UNAVAILABLE"
    fi
    printf '%s\n' "$digests"
}

function gcr_digest_for_tag_anonymously {
    gcr_digest_for_tag_from_metadata \
        "$1" "$2" "$3" gcr_metadata_anonymously
}

function gcr_digest_for_tag_with_bearer_token {
    gcr_digest_for_tag_from_metadata \
        "$1" "$2" "$3" gcr_metadata "$4"
}

# Print current tags for one complete digest, applying the shared bounded or
# exhaustive scan contract.
function gcr_tags_by_digest_from_metadata {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local metadata_function="$4"
    local bearer_token="${5-}"
    local metadata matching_tags observed_tags

    metadata=$("$metadata_function" \
        "$registry" "$repository" "$bearer_token") || return $?
    # shellcheck disable=SC2016  # jq filter uses a literal jq variable
    matching_tags=$("$JQ" -r --arg digest "$digest" \
        '.manifest[$digest].tag[]?' <<<"$metadata")
    observed_tags=$("$JQ" -r '.manifest[].tag[]?' <<<"$metadata")
    select_matching_tags_for_scan "$matching_tags" "$observed_tags" || true
}

function gcr_tags_by_digest_anonymously {
    gcr_tags_by_digest_from_metadata \
        "$1" "$2" "$3" gcr_metadata_anonymously
}

function gcr_tags_by_digest_with_bearer_token {
    gcr_tags_by_digest_from_metadata \
        "$1" "$2" "$3" gcr_metadata "$4"
}

function gcr_policy_attempt_public {
    local request_name="$1"
    local result_name="$2"
    local -n request_ref="$request_name"
    local -n result_ref="$result_name"
    local output status

    if [[ "${request_ref[operation]}" == direct ]]; then
        if output=$(gcr_digest_for_tag_anonymously \
                "${request_ref[registry]}" "${request_ref[repository]}" \
                "${request_ref[tag]}"); then
            result_ref[digest]="$output"
            return "$LOOKUP_SUCCEEDED"
        else
            return $?
        fi
    fi
    if output=$(gcr_tags_by_digest_anonymously \
            "${request_ref[registry]}" "${request_ref[repository]}" \
            "${request_ref[digest]}"); then
        result_ref[tags]="$output"
        return "$LOOKUP_SUCCEEDED"
    else
        status=$?
    fi
    return "$status"
}

function gcr_policy_attempt_google_token {
    local request_name="$1"
    local result_name="$2"
    local -n request_ref="$request_name"
    local -n result_ref="$result_name"
    local output token status

    token=$(gar_access_token "${request_ref[registry]}") ||
        return "$LOOKUP_UNAVAILABLE"
    if [[ "${request_ref[operation]}" == direct ]]; then
        if output=$(gcr_digest_for_tag_with_bearer_token \
                "${request_ref[registry]}" "${request_ref[repository]}" \
                "${request_ref[tag]}" "$token"); then
            result_ref[digest]="$output"
            return "$LOOKUP_SUCCEEDED"
        else
            return $?
        fi
    fi
    if output=$(gcr_tags_by_digest_with_bearer_token \
            "${request_ref[registry]}" "${request_ref[repository]}" \
            "${request_ref[digest]}" "$token"); then
        result_ref[tags]="$output"
        return "$LOOKUP_SUCCEEDED"
    else
        status=$?
    fi
    return "$status"
}

function gcr_register_policy_attempts {
    local request_name="$1"
    local -n request_ref="$request_name"

    request_ref[provider_auth_callback]=gar_authenticate
    policy_add_attempt gcr-public gcr_policy_attempt_public \
        gcr-api "$POLICY_ACCESS_PUBLIC" 10
    policy_add_attempt gcr-oci-public oci_policy_attempt_public \
        oci-registry-api "$POLICY_ACCESS_PUBLIC" 30
    policy_add_attempt gcr-google-token gcr_policy_attempt_google_token \
        gcr-api "$POLICY_ACCESS_CREDENTIAL" 20
    skopeo_register_policy_attempts "$request_name" gcr 70
}
