# shellcheck shell=bash

# Google Artifact Registry and Google Container Registry support. Public
# access stays anonymous; private access obtains a short-lived Google Cloud
# CLI token only after an authentication challenge.

function gar_authenticate {
    local registry="$1"

    command -v "${GCLOUD:=gcloud}" &>/dev/null || {
        warn "Install Google Cloud CLI and run 'gcloud auth login' to access private Google registry '$registry'"
        return 1
    }

    notice "Google registry requires authentication; requesting a short-lived token from Google Cloud CLI."
    if ! "$GCLOUD" auth print-access-token --quiet |
            "$SKOPEO" login --authfile "$skopeo_session_authfile" \
                --username oauth2accesstoken --password-stdin "$registry" >/dev/null; then
        warn "Google Cloud CLI authentication failed for registry '$registry'"
        return 1
    fi
}

function gar_digest_for_tag {
    local registry="$1"
    local image_reference="$2"

    skopeo_digest_for_tag_with_lazy_auth "$registry" "$image_reference" gar_authenticate
}

function gar_tags_by_digest {
    local registry="$1"
    local repository="$2"
    local digest="$3"

    skopeo_tags_by_digest_with_lazy_auth \
        "$registry" "$repository" "$digest" gar_authenticate
}
