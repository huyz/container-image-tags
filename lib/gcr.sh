# shellcheck shell=bash

# Google Container Registry's tags/list response includes a manifest object
# keyed by complete digest, with each value carrying its current tags. Use that
# provider extension to avoid one manifest request per tag. Keep this fast path
# anonymous; the existing Google/Skopeo path handles configured credentials and
# on-demand gcloud authentication after an access denial.

# Print one GCR tags/list response. Use the shared LOOKUP_* status contract to
# distinguish success, an unavailable repository, transport/response failures,
# and access denial.
function gcr_metadata_anonymously {
    local registry="$1"
    local repository="$2"
    local response_tmp http_code error_message

    response_tmp=$(runtime_temp_file gcr-response)
    if ! http_code=$(registry_http_request GET \
            "https://$registry/v2/$repository/tags/list" "$response_tmp" ''); then
        rm -f "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi

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

# Resolve one current tag from GCR's digest-keyed manifest map.
function gcr_digest_for_tag_anonymously {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local metadata digests

    metadata=$(gcr_metadata_anonymously "$registry" "$repository") || return $?
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

function gcr_resolve_tag {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local display_reference="$4"
    local lookup_output

    if lookup_output=$(gcr_digest_for_tag_anonymously "$registry" "$repository" "$tag"); then
        remote_tag_digest="$lookup_output"
        remote_tag_status=$LOOKUP_SUCCEEDED
    else
        remote_tag_status=$?
        if (( remote_tag_status == LOOKUP_UNAVAILABLE ||
                remote_tag_status == LOOKUP_DENIED )); then
            skopeo_is_available || abort "Install skopeo to check registry tag '$display_reference'"
            if lookup_output=$(gar_digest_for_tag "$registry" "$display_reference"); then
                remote_tag_digest="$lookup_output"
                remote_tag_status=$LOOKUP_SUCCEEDED
            else
                remote_tag_status=$?
                remote_tag_error="$lookup_output"
            fi
        fi
    fi
}

# Print current tags for one complete digest. In "any" mode, retain matching
# tags through the first tag heuristically assumed durable under the
# repository's observed convention.
function gcr_tags_by_digest_anonymously {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local metadata matching_tags observed_tags

    metadata=$(gcr_metadata_anonymously "$registry" "$repository") || return $?
    matching_tags=$("$JQ" -r --arg digest "$digest" \
        '.manifest[$digest].tag[]?' <<<"$metadata")
    observed_tags=$("$JQ" -r '.manifest[].tag[]?' <<<"$metadata")
    select_matching_tags_for_scan "$matching_tags" "$observed_tags" || true
}

function gcr_find_tags {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local display_repository="$4"
    local lookup_status

    registry_lookup_backend=gcr-api
    if registry_tags=$(gcr_tags_by_digest_anonymously \
            "$registry" "$repository" "$digest"); then
        return
    else
        lookup_status=$?
    fi
    case "$lookup_status" in
    "$LOOKUP_NOT_FOUND") registry_lookup_result=not_found ;;
    "$LOOKUP_STOPPED") abort "GCR API lookup stopped for $display_repository" ;;
    *)
        registry_lookup_backend=skopeo
        skopeo_is_available || abort "Install skopeo to query registry '$registry'"
        registry_tags=$(gar_tags_by_digest \
            "$registry" "$display_repository" "$digest") ||
            abort "Google Container Registry lookup failed for $display_repository"
        ;;
    esac
}
