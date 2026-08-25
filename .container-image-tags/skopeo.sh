# shellcheck shell=bash

# Generic OCI registry fallback. Skopeo reads credentials written by
# skopeo/podman login and, as a fallback, Docker's config.json (including
# credential helpers). Keep all Skopeo calls behind these helpers so private
# registry behavior is consistent for direct checks and reverse lookups.

function skopeo_is_available {
    SKOPEO="${SKOPEO:-skopeo}"
    command -v "$SKOPEO" &>/dev/null
}

function skopeo_has_registry_credentials {
    local registry="$1"

    skopeo_is_available &&
        "$SKOPEO" login --get-login "$registry" >/dev/null 2>&1
}

function skopeo_digest_for_tag {
    local image_reference="$1"

    skopeo_is_available || return 127
    "$SKOPEO" inspect --format '{{.Digest}}' "docker://$image_reference" 2>/dev/null
}

function skopeo_tags_by_digest {
    local repository="$1"
    local digest="$2"
    local tags tag manifest_digest
    local checked=0
    local matches=
    local -a spinner=('|' '/' '-' $'\\')

    skopeo_is_available || return 127
    info "Listing registry tags with skopeo for $repository"
    tags=$(
        "$SKOPEO" list-tags "docker://$repository" |
            $JQ -r '.Tags[]?'
    ) || return 1

    if [[ -z ${opt_verbose-} ]]; then
        printf 'Searching registry tags with skopeo... %s (0 checked)' "${spinner[0]}" >&2
    fi
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        info "Resolving registry tag with skopeo: $tag"
        if manifest_digest=$(skopeo_digest_for_tag "$repository:$tag"); then
            if [[ "$manifest_digest" == "$digest" ]]; then
                matches+="${matches:+$'\n'}$tag"
            fi
        fi
        ((++checked))
        if [[ -z ${opt_verbose-} ]]; then
            printf '\rSearching registry tags with skopeo... %s (%d checked)' \
                "${spinner[checked % 4]}" "$checked" >&2
        fi
    done <<<"$tags"
    if [[ -z ${opt_verbose-} ]]; then
        printf '\rSearching registry tags with skopeo... done (%d checked)\n' "$checked" >&2
    fi

    printf '%s' "$matches"
}
