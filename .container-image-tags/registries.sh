# shellcheck shell=bash

# Registry classification and dispatch. Registry-specific modules implement
# the fast paths; this file is the single integration point for adding another
# registry such as ECR or ACR.

# Populate registry_kind, registry_repository, and registry_host for a Docker
# repository reference. registry_repository is normalized for the selected
# registry module.
function registry_classify {
    local repository="$1"
    local first_component="${repository%%/*}"

    registry_kind=other
    registry_repository="$repository"
    registry_host="$first_component"

    case "$repository" in
    ghcr.io/*)
        registry_kind=ghcr
        registry_repository="${repository#ghcr.io/}"
        registry_host=ghcr.io
        ;;
    *)
        if [[ "$repository" != */* ||
                "$first_component" != *.* && "$first_component" != *:* &&
                "$first_component" != localhost ]] ||
                [[ "$first_component" == docker.io ||
                "$first_component" == index.docker.io ||
                "$first_component" == registry-1.docker.io ]]; then
            registry_kind=docker-hub
            registry_repository=$(docker_hub_repository "$repository")
            registry_host=docker.io
        fi
        ;;
    esac
}

# Resolve the current digest for a known tag. Results are returned through the
# shared remote_tag_digest and remote_tag_status fields so dispatch runs in the
# current shell and can preserve the existing fatal-error behavior.
function registry_resolve_tag_digest {
    local repository="$1"
    local tag="$2"
    local remote_tag_reference="$repository:$tag"

    remote_tag_digest=
    case "$registry_kind" in
    docker-hub)
        if remote_tag_digest=$(docker_hub_digest_for_tag "$registry_repository" "$tag"); then
            remote_tag_status=0
        else
            remote_tag_status=$?
        fi
        if [[ "$remote_tag_status" == 2 ]] &&
                remote_tag_digest=$(skopeo_digest_for_tag "$remote_tag_reference"); then
            info "Resolved Docker Hub tag with configured registry credentials"
            remote_tag_status=0
        fi
        ;;
    ghcr)
        if remote_tag_digest=$(ghcr_digest_for_tag "$registry_repository" "$tag"); then
            remote_tag_status=0
        else
            remote_tag_status=$?
        fi
        ;;
    other)
        skopeo_is_available ||
            abort "Install skopeo to check registry tag '$remote_tag_reference'"
        if remote_tag_digest=$(skopeo_digest_for_tag "$remote_tag_reference"); then
            remote_tag_status=0
        else
            remote_tag_status=2
        fi
        ;;
    esac
}

# Populate registry_tags plus any registry-specific status and metadata for an
# exhaustive reverse lookup.
function registry_find_tags_by_digest {
    local repository="$1"
    local digest="$2"

    registry_tags=
    registry_lookup_status=
    registry_metadata=
    registry_digest="$digest"

    case "$registry_kind" in
    ghcr)
        ghcr_tags_by_digest "$registry_repository" "$digest" "$repository"
        ;;
    docker-hub)
        docker_hub_tags_by_digest "$registry_repository" "$digest" "$repository"
        ;;
    other)
        skopeo_is_available ||
            abort "Install skopeo to query registry '$registry_host'"
        registry_tags=$(skopeo_tags_by_digest "$repository" "$digest") ||
            abort "Skopeo lookup failed for $repository"
        ;;
    esac
}

function registry_print_metadata {
    case "$registry_kind" in
    ghcr) ghcr_print_metadata ;;
    esac
}
