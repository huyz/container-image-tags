# shellcheck shell=bash

# Google registry Skopeo support, used directly for Artifact Registry and as
# the authenticated fallback for Container Registry. Public access stays
# anonymous; after the registry denies anonymous access, retry with a
# short-lived Google Cloud CLI token. A denial can also mean that the repository
# is unavailable, so do not claim that authentication is required.

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
    error_tmp=$(mktemp)
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
    local image_reference="$2"
    local digest lookup_status

    if digest=$(skopeo_digest_for_tag_with_lazy_auth \
            "$registry" "$image_reference" gar_authenticate); then
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

function gar_tags_by_digest {
    local registry="$1"
    local repository="$2"
    local digest="$3"

    skopeo_tags_by_digest_with_lazy_auth \
        "$registry" "$repository" "$digest" gar_authenticate
}
