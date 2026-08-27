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

    case "$registry_kind" in
    docker-hub | ghcr | other) skopeo_prepare_lazy_auth ;;
    esac
}

# Resolve the current digest for a known tag. Results are returned through the
# shared remote_tag_digest and remote_tag_status fields so dispatch runs in the
# current shell and can preserve the existing fatal-error behavior.
function registry_resolve_tag_digest {
    local repository="$1"
    local tag="$2"
    local context_name="${3-}"
    local remote_tag_reference="$repository:$tag"
    local oci_repository

    remote_tag_digest=
    remote_tag_error=
    remote_tag_status=$LOOKUP_UNAVAILABLE
    case "$registry_kind" in
    docker-hub)
        docker_hub_resolve_tag "$registry_repository" "$tag" "$remote_tag_reference"
        ;;
    ghcr)
        ghcr_resolve_tag "$registry_repository" "$tag"
        ;;
    acr)
        acr_resolve_tag "$registry_host" "${registry_repository#*/}" \
            "$tag" "$remote_tag_reference"
        ;;
    gar)
        gar_resolve_tag "$registry_host" "${registry_repository#*/}" \
            "$tag" "$remote_tag_reference"
        ;;
    gcr)
        gcr_resolve_tag "$registry_host" "$registry_repository" \
            "$tag" "$remote_tag_reference"
        ;;
    ecr)
        ecr_resolve_tag "$registry_host" "${registry_repository#*/}" \
            "$tag" "$remote_tag_reference"
        ;;
    other)
        oci_repository="${repository#*/}"
        oci_resolve_tag "$registry_host" "$oci_repository" \
            "$tag" "$remote_tag_reference"
        ;;
    esac

    if [[ -n "$context_name" ]]; then
        local -n context_ref="$context_name"
        context_ref[status]="$remote_tag_status"
        context_ref[digest]="$remote_tag_digest"
        context_ref[error]="$remote_tag_error"
    fi
}

# Populate registry_tags plus the reverse lookup result, backend, and optional
# provider metadata. In "any" mode, retain matching tags through the first one
# heuristically assumed durable. A directly confirmed durable tag may satisfy
# the lookup itself.
function registry_find_tags_by_digest {
    local repository="$1"
    local digest="$2"
    local tag_scan_mode="$3"
    local direct_tag="$4"
    local context_name="${5-}"
    local oci_repository

    registry_tags=
    registry_lookup_result=completed
    registry_lookup_backend=
    registry_metadata=
    registry_durable_semver_precision=
    registry_seed_matching_tags=
    registry_digest="$digest"
    registry_tag_scan="$tag_scan_mode"
    registry_direct_tag=
    [[ "$direct_tag" == '<none>' ]] || registry_direct_tag="$direct_tag"

    if [[ "$registry_tag_scan" == any &&
            -n "$registry_direct_tag" &&
            -n "${registry_direct_tag_confirmed-}" ]] &&
            tag_is_assumed_durable "$registry_direct_tag"; then
        registry_tags="$registry_direct_tag"
        registry_lookup_backend=direct-tag-check
        return
    fi

    case "$registry_kind" in
    ghcr)
        ghcr_find_tags "$registry_repository" "$digest" "$repository"
        ;;
    docker-hub)
        docker_hub_find_tags "$registry_repository" "$digest" "$repository"
        ;;
    acr)
        acr_find_tags "$registry_host" "${registry_repository#*/}" \
            "$digest" "$repository"
        ;;
    gar)
        gar_find_tags "$registry_host" "$repository" "$digest"
        ;;
    gcr)
        gcr_find_tags "$registry_host" "$registry_repository" \
            "$digest" "$repository"
        ;;
    ecr)
        ecr_find_tags "$registry_host" "${registry_repository#*/}" \
            "$digest" "$repository"
        ;;
    other)
        oci_repository="${repository#*/}"
        oci_find_tags "$registry_host" "$oci_repository" "$digest" "$repository"
        ;;
    esac

    if [[ -n "$context_name" ]]; then
        local -n context_ref="$context_name"
        context_ref[result]="$registry_lookup_result"
        context_ref[backend]="$registry_lookup_backend"
        context_ref[metadata]="$registry_metadata"
        context_ref[tags]="$registry_tags"
    fi
}

function registry_print_metadata {
    local result_name="${1-}"

    if [[ -n "$result_name" ]]; then
        local -n result_ref="$result_name"
        case "${result_ref[registry_kind]}" in
        ghcr) ghcr_print_metadata "$result_name" ;;
        esac
        return
    fi
    case "$registry_kind" in
    ghcr) ghcr_print_metadata ;;
    esac
}
