# shellcheck shell=bash

# Registry classification and dispatch. Registry-specific modules implement
# lookup and authentication paths; this file is the single integration point
# for adding another registry such as GAR, ECR, or ACR.

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
    *.azurecr.io/* | *.azurecr.cn/* | *.azurecr.de/* | *.azurecr.us/*)
        registry_kind=acr
        skopeo_prepare_lazy_auth
        ;;
    gcr.io/* | us.gcr.io/* | eu.gcr.io/* | asia.gcr.io/*)
        registry_kind=gcr
        registry_repository="${repository#*/}"
        skopeo_prepare_lazy_auth
        ;;
    *-docker.pkg.dev/*)
        registry_kind=gar
        skopeo_prepare_lazy_auth
        ;;
    public.ecr.aws/*)
        registry_kind=ecr
        skopeo_prepare_lazy_auth
        ;;
    *.dkr.ecr.*.amazonaws.com/* | *.dkr.ecr.*.amazonaws.com.cn/* | \
        *.dkr.ecr-fips.*.amazonaws.com/* | *.dkr.ecr-fips.*.amazonaws.com.cn/* | \
        *.dkr-ecr.*.on.aws/* | *.dkr-ecr-fips.*.on.aws/*)
        registry_kind=ecr
        skopeo_prepare_lazy_auth
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
    local lookup_output

    remote_tag_digest=
    remote_tag_error=
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
    acr)
        skopeo_is_available ||
            abort "Install skopeo to check registry tag '$remote_tag_reference'"
        if remote_tag_digest=$(acr_digest_for_tag "$registry_host" "$remote_tag_reference"); then
            remote_tag_status=0
        else
            remote_tag_status=$?
        fi
        ;;
    gar)
        skopeo_is_available ||
            abort "Install skopeo to check registry tag '$remote_tag_reference'"
        if lookup_output=$(gar_digest_for_tag "$registry_host" "$remote_tag_reference"); then
            remote_tag_digest="$lookup_output"
            remote_tag_status=0
        else
            remote_tag_status=$?
            remote_tag_error="$lookup_output"
        fi
        ;;
    gcr)
        if lookup_output=$(gcr_digest_for_tag_anonymously \
                "$registry_host" "$registry_repository" "$tag"); then
            remote_tag_digest="$lookup_output"
            remote_tag_status=0
        else
            remote_tag_status=$?
            if (( remote_tag_status == 2 || remote_tag_status == 3 )); then
                skopeo_is_available ||
                    abort "Install skopeo to check registry tag '$remote_tag_reference'"
                if lookup_output=$(gar_digest_for_tag "$registry_host" "$remote_tag_reference"); then
                    remote_tag_digest="$lookup_output"
                    remote_tag_status=0
                else
                    remote_tag_status=$?
                    remote_tag_error="$lookup_output"
                fi
            fi
        fi
        ;;
    ecr)
        skopeo_is_available ||
            abort "Install skopeo to check registry tag '$remote_tag_reference'"
        if remote_tag_digest=$(ecr_digest_for_tag "$registry_host" "$remote_tag_reference"); then
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

# Populate registry_tags plus the reverse lookup result, backend, and optional
# provider metadata. In "any" mode, registry_direct_tag is excluded because
# that tag was already handled by the direct remote-tag check.
function registry_find_tags_by_digest {
    local repository="$1"
    local digest="$2"
    local tag_scan_mode="$3"
    local direct_tag="$4"

    registry_tags=
    registry_lookup_result=completed
    registry_lookup_backend=
    registry_metadata=
    registry_digest="$digest"
    registry_tag_scan="$tag_scan_mode"
    registry_direct_tag=
    [[ "$direct_tag" == '<none>' ]] || registry_direct_tag="$direct_tag"

    case "$registry_kind" in
    ghcr)
        ghcr_tags_by_digest "$registry_repository" "$digest" "$repository"
        ;;
    docker-hub)
        registry_lookup_backend=docker-hub-api
        docker_hub_tags_by_digest "$registry_repository" "$digest" "$repository"
        ;;
    acr)
        registry_lookup_backend=skopeo
        skopeo_is_available ||
            abort "Install skopeo to query registry '$registry_host'"
        registry_tags=$(acr_tags_by_digest \
            "$registry_host" "$repository" "$digest") ||
            abort "ACR lookup failed for $repository"
        ;;
    gar)
        registry_lookup_backend=skopeo
        skopeo_is_available ||
            abort "Install skopeo to query registry '$registry_host'"
        registry_tags=$(gar_tags_by_digest \
            "$registry_host" "$repository" "$digest") ||
            abort "Google registry lookup failed for $repository"
        ;;
    gcr)
        registry_lookup_backend=gcr-api
        if registry_tags=$(gcr_tags_by_digest_anonymously \
                "$registry_host" "$registry_repository" "$digest"); then
            :
        else
            registry_lookup_backend=skopeo
            skopeo_is_available ||
                abort "Install skopeo to query registry '$registry_host'"
            registry_tags=$(gar_tags_by_digest \
                "$registry_host" "$repository" "$digest") ||
                abort "Google Container Registry lookup failed for $repository"
        fi
        ;;
    ecr)
        registry_lookup_backend=skopeo
        skopeo_is_available ||
            abort "Install skopeo to query registry '$registry_host'"
        registry_tags=$(ecr_tags_by_digest \
            "$registry_host" "$repository" "$digest") ||
            abort "ECR lookup failed for $repository"
        ;;
    other)
        registry_lookup_backend=skopeo
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
