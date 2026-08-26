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

    response_tmp=$(mktemp)
    if ! http_code=$(
        "$CURL" -sS -o "$response_tmp" -w '%{http_code}' \
            "https://$registry/v2/$repository/tags/list"
    ); then
        rm -f "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi

    error_message=$(
        "$JQ" -r '
            (.errors[0].message // .message // .error // empty)
            | if type == "string" then gsub("[\\r\\n]+"; " ") else tostring end
        ' "$response_tmp" 2>/dev/null || true
    )
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

# Print current tags for one complete digest. In "any" mode, omit the direct
# tag already checked by the caller and return at most one other match.
function gcr_tags_by_digest_anonymously {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local metadata

    metadata=$(gcr_metadata_anonymously "$registry" "$repository") || return $?
    "$JQ" -r \
        --arg digest "$digest" \
        --arg tag_scan "$registry_tag_scan" \
        --arg direct_tag "$registry_direct_tag" '
            [
                .manifest[$digest].tag[]?
                | select($tag_scan != "any" or . != $direct_tag)
            ]
            | if $tag_scan == "any" then .[0] // empty else .[] end
        ' <<<"$metadata"
}
