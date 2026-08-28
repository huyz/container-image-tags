# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2178  # standalone lint: shared fields and associative namerefs

# Registry classification and request construction. Registry-specific modules
# advertise atomic lookup mechanisms; the policy engine owns their flow.

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

# Build the common request consumed by provider capability declarations and the
# policy engine. Repository normalization remains classification data, not
# policy.
function registry_policy_request_init {
    local repository="$1"
    local request_name="$2"
    local -n request_ref="$request_name"

    request_ref=()
    request_ref[registry_kind]="$registry_kind"
    request_ref[registry]="$registry_host"
    request_ref[display_repository]="$repository"
    case "$registry_kind" in
    docker-hub | ghcr | gcr) request_ref[repository]="$registry_repository" ;;
    *) request_ref[repository]="${registry_repository#*/}" ;;
    esac
}

function registry_register_policy_attempts {
    local request_name="$1"

    case "$registry_kind" in
    docker-hub) docker_hub_register_policy_attempts "$request_name" ;;
    ghcr) ghcr_register_policy_attempts "$request_name" ;;
    acr) acr_register_policy_attempts "$request_name" ;;
    gar) gar_register_policy_attempts "$request_name" ;;
    gcr) gcr_register_policy_attempts "$request_name" ;;
    ecr) ecr_register_policy_attempts "$request_name" ;;
    other) oci_register_policy_attempts "$request_name" ;;
    esac
}

# Resolve the current digest for a known tag through the common request/result
# contract. Callers receive only the explicit lookup context.
function registry_resolve_tag_digest {
    local repository="$1"
    local tag="$2"
    local context_name="$3"
    local remote_tag_reference="$repository:$tag"
    local status
    local -A request=() attempt_result=()
    local -n context_ref="$context_name"

    registry_policy_request_init "$repository" request
    request[operation]=direct
    request[tag]="$tag"
    request[display_reference]="$remote_tag_reference"
    policy_plan_reset
    registry_register_policy_attempts request
    if policy_execute_lookup request attempt_result; then
        status=$LOOKUP_SUCCEEDED
    else
        status=$?
    fi
    if (( status == LOOKUP_STOPPED )); then
        abort "Registry lookup stopped for $remote_tag_reference"
    fi

    context_ref=()
    context_ref[status]="$status"
    context_ref[digest]="${attempt_result[digest]-}"
    context_ref[error]="${attempt_result[error]-}"
}

# Find tags for a digest and populate the caller-owned lookup context. "any"
# stops at the first match. "any-durable" retains matching tags through the
# first one heuristically assumed durable.
function registry_find_tags_by_digest {
    local repository="$1"
    local digest="$2"
    local tag_scan_mode="$3"
    local direct_tag="$4"
    local context_name="$5"
    local status
    local -A request=() attempt_result=()
    local -n context_ref="$context_name"

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

    registry_policy_request_init "$repository" request
    request[operation]=reverse
    request[digest]="$digest"
    request[scan_mode]="$tag_scan_mode"
    request[direct_tag]="$registry_direct_tag"
    request[direct_tag_confirmed]="${registry_direct_tag_confirmed-}"
    policy_plan_reset
    registry_register_policy_attempts request
    if policy_execute_lookup request attempt_result; then
        status=$LOOKUP_SUCCEEDED
    else
        status=$?
    fi
    context_ref=()
    context_ref[backend]="${attempt_result[backend]-}"
    context_ref[metadata]="${attempt_result[metadata]-}"
    context_ref[tags]="${attempt_result[tags]-}"
    case "$status" in
    "$LOOKUP_SUCCEEDED") context_ref[result]=completed ;;
    "$LOOKUP_NOT_FOUND") context_ref[result]=not_found ;;
    "$LOOKUP_STOPPED") abort "Registry lookup stopped for $repository" ;;
    "$LOOKUP_DENIED") abort "Registry denied access to $repository after permitted authentication paths" ;;
    *) abort "Registry lookup failed for $repository" ;;
    esac
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
