# shellcheck shell=bash
# shellcheck disable=SC2034  # standalone module lint: shared output fields

# Local Docker image and repository-reference helpers.

# Resolve a local image reference and populate the image fields used by the
# main lookup. An image can exist locally without a RepoDigest, so an empty
# repo_digest still counts as a successful image resolution.
function inspect_local_image {
    local image_ref="$1"
    local preferred_repository="${2:-}"
    local preferred_tag="${3:-}"
    local repo_digests repo_tags candidate candidate_repository

    if ! image_id=$(
        run_network_command "$DOCKER" image inspect \
            "$image_ref" --format '{{.Id}}' 2>/dev/null
    ); then
        return 1
    fi
    repo_digests=$(
        run_network_command "$DOCKER" image inspect "$image_id" \
            --format='{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null
    ) || return 1
    repo_tags=$(
        run_network_command "$DOCKER" image inspect "$image_id" \
            --format='{{range .RepoTags}}{{println .}}{{end}}' 2>/dev/null
    ) || return 1
    local_image_version=$(
        run_network_command "$DOCKER" image inspect "$image_id" \
            --format='{{with index .Config.Labels "org.opencontainers.image.version"}}{{.}}{{end}}' 2>/dev/null
    ) || return 1
    local_image_revision=$(
        run_network_command "$DOCKER" image inspect "$image_id" \
            --format='{{with index .Config.Labels "org.opencontainers.image.revision"}}{{.}}{{end}}' 2>/dev/null
    ) || return 1
    local_image_refname=$(
        run_network_command "$DOCKER" image inspect "$image_id" \
            --format='{{with index .Config.Labels "org.opencontainers.image.ref.name"}}{{.}}{{end}}' 2>/dev/null
    ) || return 1

    repo_digest=
    local_tag=
    if [[ -n "$preferred_repository" ]]; then
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            if [[ "${candidate%%@*}" == "$preferred_repository" ]]; then
                repo_digest="$candidate"
                break
            fi
        done <<<"$repo_digests"
        if [[ -n "$preferred_tag" ]] && grep -Fxq -- "$preferred_tag" <<<"$repo_tags"; then
            local_tag="$preferred_tag"
        else
            while IFS= read -r candidate; do
                [[ -n "$candidate" ]] || continue
                candidate_repository="${candidate%:*}"
                if [[ "$candidate_repository" == "$preferred_repository" ]]; then
                    local_tag="$candidate"
                    break
                fi
            done <<<"$repo_tags"
        fi
    else
        repo_digest="${repo_digests%%$'\n'*}"
        local_tag="${repo_tags%%$'\n'*}"
    fi
}

# Print every distinct local image ID whose repository name exactly matches
# the requested untagged name. Tags are deliberately ignored here.
function image_ids_for_repository {
    local wanted_repository="$1"
    local image_rows repository image_id_candidate
    local matches=

    image_rows=$(
        run_network_command "$DOCKER" image ls --no-trunc \
            --format '{{.Repository}}\t{{.ID}}' 2>/dev/null
    ) || return 1
    while IFS=$'\t' read -r repository image_id_candidate; do
        if [[ "$repository" == "$wanted_repository" && -n "$image_id_candidate" ]]; then
            matches+="${matches:+$'\n'}$image_id_candidate"
        fi
    done <<<"$image_rows"

    [[ -n "$matches" ]] || return 1
    printf '%s\n' "$matches" | sort -u
}

# Strip an explicit tag from an image reference without mistaking a registry
# port (as in localhost:5000/repo) for a tag.
function repository_from_image_reference {
    local image_reference="$1"
    local final_component

    image_reference="${image_reference%%@*}"
    final_component="${image_reference##*/}"
    if [[ "$final_component" == *:* ]]; then
        image_reference="${image_reference%:*}"
    fi
    printf '%s\n' "$image_reference"
}

# Find locally known repository digests whose complete SHA matches a bare
# registry digest. A content digest does not identify its repository, so this
# local metadata is required before a registry can be queried.
function repo_digests_for_sha {
    local wanted_sha="$1"
    local image_ids candidate_repo_digests image candidate digest
    local matches=

    image_ids=$(run_network_command "$DOCKER" image ls \
        --no-trunc --quiet 2>/dev/null) || return 1
    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        candidate_repo_digests=$(
            run_network_command "$DOCKER" image inspect "$image" \
                --format='{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null
        ) || continue
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            digest="${candidate##*@}"
            if [[ "${digest#sha256:}" == "$wanted_sha" ]]; then
                matches+="${matches:+$'\n'}$candidate"
            fi
        done <<<"$candidate_repo_digests"
    done <<<"$image_ids"

    [[ -n "$matches" ]] || return 1
    printf '%s\n' "$matches" | sort -u
}
