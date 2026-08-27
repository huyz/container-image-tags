# shellcheck shell=bash

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

function gcr_resolve_tag {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local display_reference="$4"
    local lookup_output lookup_status token

    if credential_policy_allows_public; then
        if lookup_output=$(gcr_digest_for_tag_anonymously \
                "$registry" "$repository" "$tag"); then
            remote_tag_digest="$lookup_output"
            remote_tag_status=$LOOKUP_SUCCEEDED
            return
        else
            lookup_status=$?
        fi
        case "$lookup_status" in
        "$LOOKUP_NOT_FOUND" | "$LOOKUP_STOPPED") remote_tag_status="$lookup_status"; return ;;
        esac
    else
        lookup_status=$LOOKUP_DENIED
    fi

    if credential_policy_allows_auth_after "$lookup_status"; then
        if token=$(gar_access_token "$registry") &&
                lookup_output=$(gcr_digest_for_tag_with_bearer_token \
                    "$registry" "$repository" "$tag" "$token"); then
            remote_tag_digest="$lookup_output"
            remote_tag_status=$LOOKUP_SUCCEEDED
            return
        else
            lookup_status=$?
        fi
        case "$lookup_status" in
        "$LOOKUP_NOT_FOUND" | "$LOOKUP_STOPPED") remote_tag_status="$lookup_status"; return ;;
        esac
    fi

    skopeo_is_available || abort "Install skopeo to check registry tag '$display_reference'"
    if lookup_output=$(skopeo_digest_for_tag_with_access_policy \
            "$registry" "$display_reference" gar_authenticate "$lookup_status"); then
        remote_tag_digest="$lookup_output"
        remote_tag_status=$LOOKUP_SUCCEEDED
    else
        remote_tag_status=$?
        remote_tag_error="$lookup_output"
    fi
}

# Print current tags for one complete digest. In "any" mode, retain matching
# tags through the first tag heuristically assumed durable under the
# repository's observed convention.
function gcr_tags_by_digest_from_metadata {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local metadata_function="$4"
    local bearer_token="${5-}"
    local metadata matching_tags observed_tags

    metadata=$("$metadata_function" \
        "$registry" "$repository" "$bearer_token") || return $?
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

function gcr_find_tags {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local display_repository="$4"
    local lookup_status token

    registry_lookup_backend=gcr-api
    if credential_policy_allows_public; then
        if registry_tags=$(gcr_tags_by_digest_anonymously \
                "$registry" "$repository" "$digest"); then
            return
        else
            lookup_status=$?
        fi
    else
        lookup_status=$LOOKUP_DENIED
    fi
    case "$lookup_status" in
    "$LOOKUP_NOT_FOUND") registry_lookup_result=not_found ;;
    "$LOOKUP_STOPPED") abort "GCR API lookup stopped for $display_repository" ;;
    *)
        if credential_policy_allows_auth_after "$lookup_status"; then
            if token=$(gar_access_token "$registry") &&
                    registry_tags=$(gcr_tags_by_digest_with_bearer_token \
                        "$registry" "$repository" "$digest" "$token"); then
                return
            else
                lookup_status=$?
            fi
            case "$lookup_status" in
            "$LOOKUP_NOT_FOUND") registry_lookup_result=not_found; return ;;
            "$LOOKUP_STOPPED") abort "GCR API lookup stopped for $display_repository" ;;
            esac
        fi
        registry_lookup_backend=skopeo
        skopeo_is_available || abort "Install skopeo to query registry '$registry'"
        registry_tags=$(skopeo_tags_by_digest_with_access_policy \
            "$registry" "$display_repository" "$digest" gar_authenticate \
            "$lookup_status") ||
            abort "Google Container Registry lookup failed for $display_repository"
        ;;
    esac
}
