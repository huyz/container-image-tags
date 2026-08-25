#!/bin/bash
# Given a Docker container, local image, or registry digest, this checks
# whether its known local tag still points to the same remote digest. It can
# then find every current remote registry tag for that digest. Each argument
# is classified by its shape and, where necessary, by probing the local Docker
# daemon.
#
# The lookup is done using the image's RepoDigest (e.g. repo@sha256:...).
# The RepoDigest is the manifest digest that Docker resolved from a registry
# when the image was pulled, so it is the only digest that can be matched up
# against the registries.  In contrast, the local image ID (a hash of the
# local image config) cannot be used to match registry tags.
#
# Why not use Skopeo for every registry?  Skopeo can list tags and inspect a
# tag's manifest, but it cannot reverse-lookup tags by digest.  Its generic
# approach therefore requires one manifest lookup per tag.  Docker Hub's tags
# API and GitHub's Packages API include digests and tags in their paginated
# results, making those common lookups much faster.  Skopeo remains the
# portable fallback for other OCI registries and their configured credentials.
#
# Steps:
#   1. Resolve each argument as a container, local image, or registry digest.
#   2. Find the associated repository digest.
#   3. Check whether the known local tag still points to that remote digest.
#   4. Optionally find and print every current registry tag for that digest.
#
# Prerequisites:
# - curl
# - jq
# - docker CLI
# - registry credentials configured by docker login, skopeo login, or podman
#   login, for private registries
# - Azure CLI, optional on-demand authentication for private ACR repositories
# - Google Cloud CLI, optional on-demand authentication for private GAR/GCR
#   repositories
# - AWS CLI, optional on-demand authentication for private ECR repositories
# - Docker Hub username and PAT, only if an exhaustive anonymous scan is refused
# - authenticated gh CLI with read:packages scope, optional fast path for GHCR
# - skopeo, for private-registry fallback and registries other than Docker Hub
#   and GHCR
#
# TIP:
# - To list all the Repo digests for your containers:
#    docker image ls --digests --format 'table {{.Repository}}\t{{.Tag}}\t{{.Digest}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}'
# - To query all local containers:
#   container-image-tags $(docker ps -a --format "{{.Names}}")
#
# 2026-08-22 Authored mostly by DeepSeek V4 Flash and OpenAI's GPT 5.6 Sol

#### Preamble (v2026-08-24)

set -Eeuo pipefail
shopt -s failglob inherit_errexit
SCRIPT_NAME=${BASH_SOURCE[0]##*/}
# shellcheck disable=SC2329
function trap_err { local rc=$?; printf '%s: ERROR: command failed with status %d at %s:%d: %s\n' \
    "$SCRIPT_NAME" "$rc" "${BASH_SOURCE[1]}" "${BASH_LINENO[0]}" "$BASH_COMMAND" >&2; return "$rc"; }
trap trap_err ERR
trap 'exit 130' INT  # Exit this shell on SIGINT rather than continuing after an interrupted command
PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

if [[ $OSTYPE == darwin* ]]; then
    HOMEBREW_PREFIX=$( (/opt/homebrew/bin/brew --prefix || /usr/local/bin/brew --prefix || brew --prefix) 2>/dev/null )
    _install_cmd="brew install"
    [[ -x "${GETOPT:="$HOMEBREW_PREFIX/opt/gnu-getopt/bin/getopt"}" ]] || \
        { echo "$0: ERROR: \`$_install_cmd gnu-getopt\` to install $GETOPT." >&2; exit 1; }
    [[ -x "${REALPATH:="$HOMEBREW_PREFIX/bin/grealpath"}" ]] || \
        { echo "$0: ERROR: \`$_install_cmd coreutils\` to install $REALPATH." >&2; exit 1; }
    [[ -x "${JQ:="$HOMEBREW_PREFIX/bin/jq"}" ]] || \
        { echo "$0: ERROR: \`$_install_cmd jq\` to install $JQ." >&2; exit 1; }
    [[ -x "${DOCKER:="$HOMEBREW_PREFIX/bin/docker"}" ]] || \
        { echo "$0: ERROR: \`$_install_cmd docker\` to install $DOCKER." >&2; exit 1; }
else
    _install_cmd="sudo apt install"
    GETOPT="getopt"
    REALPATH="realpath"
    command -v "${JQ:=jq}" &>/dev/null || \
        { echo "$0: ERROR: \`$_install_cmd jq\` to install $JQ." >&2; exit 1; }
    command -v "${DOCKER:=docker}" &>/dev/null || \
        { echo "$0: ERROR: \`$_install_cmd docker\` to install $DOCKER." >&2; exit 1; }
fi
command -v "${CURL:=curl}" &>/dev/null ||
    { echo "$0: ERROR: \`$_install_cmd curl\` to install $CURL." >&2; exit 1; }

SCRIPT=$("$REALPATH" --no-symlinks "${BASH_SOURCE[0]}")
# shellcheck disable=SC2034
SCRIPT_DIR=$(dirname -- "$SCRIPT")
SOURCE_SCRIPT=$("$REALPATH" "${BASH_SOURCE[0]}")
MODULE_DIR=$(dirname -- "$SOURCE_SCRIPT")/.container-image-tags

# Resolve the physical source path above so an installation symlink in ~/bin
# can still load these modules from the checkout.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=.container-image-tags/common.sh
source "$MODULE_DIR/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=.container-image-tags/skopeo.sh
source "$MODULE_DIR/skopeo.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=.container-image-tags/docker-hub.sh
source "$MODULE_DIR/docker-hub.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=.container-image-tags/ghcr.sh
source "$MODULE_DIR/ghcr.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=.container-image-tags/acr.sh
source "$MODULE_DIR/acr.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=.container-image-tags/gar.sh
source "$MODULE_DIR/gar.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=.container-image-tags/ecr.sh
source "$MODULE_DIR/ecr.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=.container-image-tags/registries.sh
source "$MODULE_DIR/registries.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=.container-image-tags/local-images.sh
source "$MODULE_DIR/local-images.sh"

function require_supported_digest_algorithm {
    local digest_reference="$1"
    local digest="${digest_reference##*@}"
    local algorithm

    [[ "$digest" == *:* ]] || return 0
    algorithm="${digest%%:*}"
    [[ -n "$algorithm" ]] || return 0
    [[ "$algorithm" == sha256 ]] ||
        abort "Digest algorithm '$algorithm' in '$digest_reference' is not supported; only sha256 is supported"
}

#### Options

# Defaults
opt_verbose=
opt_debug=
opt_ghcr_method=auto
opt_local_only=
opt_all=
docker_hub_token=

function usage {
    cat <<END
Usage: $SCRIPT_NAME [-h|--help] [-v|--verbose] [-d|--debug] [-l|--local-only | -a|--all] [--ghcr-method method] <container-or-image-or-digest> [...]
        -h|--help: get help
        -v|--verbose: turn on verbose mode
        -d|--debug: turn on debug mode
        -l|--local-only: only check whether each known local tag still points to the local digest; never prompt or scan
        -a|--all: check each known local tag, then scan for every remote tag matching the digest; never prompt
        --ghcr-method: select the GHCR tag-check and exhaustive-scan method (default: $opt_ghcr_method):
            auto: check public tags anonymously; use the Packages API for exhaustive scans and private-tag fallback
            packages: use only the GitHub Packages API; never prompt or fall back
            anonymous: use only the anonymous OCI scan; never prompt

By default, each known local tag is checked first, then you are asked whether
to scan the registry for every tag that points to the same digest.
Docker Hub scans start anonymously. If deeper pagination requires sign-in, an
interactive run can exchange a username and PAT for an in-memory access token.
Private registry access reuses credentials configured by docker login, skopeo
login, or podman login. ACR, GAR/GCR, and ECR are first tried anonymously, then
reuse configured credentials or request a short-lived token from az, gcloud, or
aws only after the registry requires authentication. Credential values are
never passed on this command line.

Arguments are interpreted as follows:
        repository@sha256:...: use this registry digest directly
        repository:*: immediately match every local tag in that repository
        image name with an explicit tag: inspect that exact local image
        SHA-like value: try a local container ID, then a local image ID, then a registry digest
        image name without a tag (including names with '/'): try ':latest', then match every local repository tag
        any other value: try a container name before treating it as an image name
END
}

opts=$("$GETOPT" --options hvalnd --long help,verbose,all,local-only,dry-run,debug,ghcr-method: --name "$SCRIPT_NAME" -- "$@") || { usage >&2; exit 2; }
eval set -- "$opts"

while true; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        -v | --verbose) opt_verbose=opt_verbose; shift ;;
        -d | --debug) opt_debug=opt_debug; shift ;;
        -l | --local-only) opt_local_only=opt_local_only; shift ;;
        -a | --all) opt_all=opt_all; shift ;;
        --ghcr-method) opt_ghcr_method="$2"; shift 2 ;;
        --) shift; break ;;
        *) abort "🐛 INTERNAL: unrecognized option '$1'" ;;
    esac
done

case "$opt_ghcr_method" in
auto | packages | anonymous) ;;
*) abort "--ghcr-method must be 'auto', 'packages', or 'anonymous'" ;;
esac

if [[ -n "$opt_local_only" && -n "$opt_all" ]]; then
    abort "--local-only and --all are mutually exclusive"
fi

[[ $# -ge 1 ]] || { usage >&2; exit 1; }

##############################################################################
#### Main

input_index=0
for input in "$@"; do
    if (( input_index > 0 )); then
        separator_columns="${COLUMNS:-$(tput cols 2>/dev/null || true)}"
        (( separator_columns > 0 )) || separator_columns=80
        printf '%*s\n' "$separator_columns" '' | tr ' ' '-'
    fi
    ((++input_index))
    skip_input=
    container=
    image_id=
    local_image_version=
    repo_digest=
    local_tag=
    wildcard_image_ids=
    wildcard_reference=
    wildcard_repository=

    # A full repository digest is already unambiguous and does not need local
    # Docker metadata.
    if [[ "$input" == *@* ]]; then
        require_supported_digest_algorithm "$input"
        if [[ "$input" =~ ^.+@sha256:[0-9a-f]{64}$ ]]; then
            repo_digest="$input"
            notice "Interpreting '$input' as a complete registry digest reference."
        else
            abort "'$input' looks like a registry digest reference, but expected repository@sha256:<64 lowercase hex characters>"
        fi

    # SHA-like inputs are inherently ambiguous because Docker container IDs and
    # local image IDs are both hashes.  Probe in the documented order.
    elif [[ "$input" =~ ^([Ss][Hh][Aa]256:)?[0-9a-fA-F]{12,64}$ ]]; then
        if resolved_image_id=$(
            $DOCKER container inspect "$input" --format '{{.Image}}' 2>/dev/null
        ); then
            container="$input"
            inspect_local_image "$resolved_image_id" ||
                abort "Container '$container' refers to image '$resolved_image_id', but that image cannot be inspected"
            notice "Resolved SHA-like '$input' as a local container ID (image $image_id)."
        elif inspect_local_image "$input"; then
            notice "Resolved SHA-like '$input' as local image ID $image_id."
        else
            registry_sha="$input"
            [[ "$registry_sha" == *:* ]] && registry_sha="${registry_sha#*:}"
            notice "No local container or image ID matched '$input'; assuming it is a registry digest."
            if [[ ! "$registry_sha" =~ ^[0-9a-f]{64}$ ]]; then
                abort "A registry digest must contain exactly 64 lowercase hex characters; pass repository@sha256:<digest> if it is not locally known"
            fi
            if ! matching_repo_digests=$(repo_digests_for_sha "$registry_sha"); then
                abort "Cannot determine the repository for sha256:$registry_sha from local images; pass repository@sha256:$registry_sha"
            fi
            repo_digest="${matching_repo_digests%%$'\n'*}"
            if [[ "$matching_repo_digests" == *$'\n'* ]]; then
                warn "sha256:$registry_sha is associated with multiple local repositories; using '$repo_digest'. Pass a complete repository@sha256:... argument to select another."
            else
                notice "Recovered registry reference '$repo_digest' from local image metadata."
            fi
        fi

    # A slash identifies an image name, as does an explicit tag in the final path
    # component.  A literal :* requests an immediate wildcard scan.  For names
    # without an explicit tag, prefer Docker's normal implicit :latest resolution
    # and only then broaden the name to a :* match.
    elif [[ "$input" == */* || "${input##*/}" == *:* ]]; then
        preferred_repository=$(repository_from_image_reference "$input")
        final_component="${input##*/}"
        if [[ "$final_component" == *:* && "${final_component##*:}" == '*' ]]; then
            if ! wildcard_image_ids=$(image_ids_for_repository "$preferred_repository"); then
                abort "Cannot find any local image in repository '$preferred_repository'"
            fi
            wildcard_reference="$input"
            wildcard_repository="$preferred_repository"
            wildcard_count=0
            while IFS= read -r wildcard_image_id; do
                [[ -n "$wildcard_image_id" ]] && ((++wildcard_count))
            done <<<"$wildcard_image_ids"
            notice "Explicit wildcard '$input' requested; immediately checking $wildcard_count distinct local image(s)."
        elif [[ "$final_component" == *:* ]]; then
            inspect_local_image "$input" "$preferred_repository" "$input" ||
                abort "Cannot inspect local image '$input'"
            notice "Interpreting '$input' as a tagged local image reference."
        elif inspect_local_image "$input" "$preferred_repository" "$preferred_repository:latest"; then
            notice "Resolved '$input' using its implicit ':latest' tag; not scanning other local tags."
        elif wildcard_image_ids=$(image_ids_for_repository "$preferred_repository"); then
            wildcard_reference="$preferred_repository:*"
            wildcard_repository="$preferred_repository"
            wildcard_count=0
            while IFS= read -r wildcard_image_id; do
                [[ -n "$wildcard_image_id" ]] && ((++wildcard_count))
            done <<<"$wildcard_image_ids"
            notice "No local '$input:latest' image was found; interpreting '$input' as '$input:*' and checking $wildcard_count distinct local image(s)."
        else
            abort "Cannot find any local image in repository '$preferred_repository'"
        fi

    # Otherwise prefer a container name, then permit an image name without an
    # explicit tag.  The image lookup follows the same :latest-before-:* rule.
    else
        if resolved_image_id=$(
            $DOCKER container inspect "$input" --format '{{.Image}}' 2>/dev/null
        ); then
            container="$input"
            inspect_local_image "$resolved_image_id" ||
                abort "Container '$container' refers to image '$resolved_image_id', but that image cannot be inspected"
            notice "Resolved '$input' as a local container name (image $image_id)."
        elif inspect_local_image "$input" "$input" "$input:latest"; then
            notice "No container named '$input' was found; resolved the image using its implicit ':latest' tag and will not scan other local tags."
        elif wildcard_image_ids=$(image_ids_for_repository "$input"); then
            wildcard_reference="$input:*"
            wildcard_repository="$input"
            wildcard_count=0
            while IFS= read -r wildcard_image_id; do
                [[ -n "$wildcard_image_id" ]] && ((++wildcard_count))
            done <<<"$wildcard_image_ids"
            notice "No container or local '$input:latest' image was found; interpreting '$input' as '$input:*' and checking $wildcard_count distinct local image(s)."
        else
            abort "Cannot resolve '$input' as a local container name or local image repository"
        fi
    fi

    # Most arguments resolve to one lookup.  An untagged repository without a
    # local :latest image can expand to multiple distinct image IDs.
    images_to_process="${wildcard_image_ids:-__current_resolution__}"
    wildcard_output_index=0
    seen_wildcard_repo_digests=
    while IFS= read -r image_to_process; do
        skip_input=
        if [[ "$image_to_process" != __current_resolution__ ]]; then
            container=
            inspect_local_image "$image_to_process" "$wildcard_repository" || {
                warn "Cannot inspect wildcard image match '$image_to_process'; skipping it"
                continue
            }
        fi

    if [[ -z "$repo_digest" ]]; then
        if [[ -n "$container" ]]; then
            echo "No repository digest found for image '$image_id' (used by container '$container')" >&2
        elif [[ -n "$wildcard_image_ids" ]]; then
            warn "No repository digest found for wildcard image '$image_id'; skipping it"
            continue
        else
            echo "No repository digest found for image '$image_id'" >&2
        fi
        exit 1
    fi

    # Docker metadata should normally contain sha256 RepoDigests, but reject a
    # different algorithm explicitly before registry lookup can misinterpret it.
    require_supported_digest_algorithm "$repo_digest"

    if [[ -n "$wildcard_image_ids" ]]; then
        if grep -Fxq -- "$repo_digest" <<<"$seen_wildcard_repo_digests"; then
            notice "Skipping local image $image_id because repository digest '$repo_digest' was already checked."
            continue
        fi
        seen_wildcard_repo_digests+="${seen_wildcard_repo_digests:+$'\n'}$repo_digest"
        if (( wildcard_output_index > 0 )); then
            separator_columns="${COLUMNS:-$(tput cols 2>/dev/null || true)}"
            (( separator_columns > 0 )) || separator_columns=80
            printf '%*s\n' "$separator_columns" '' | tr ' ' '-'
        fi
        ((++wildcard_output_index))
        notice "Resolved '$wildcard_reference' to local image $image_id."
    fi

    # Split e.g. "nginx@sha256:abcd..." into repo and digest.
    repo="${repo_digest%%@*}"
    repo_sha="${repo_digest##*@}"

    # Canonicalize the digest: strip any "sha256:" prefix
    repo_sha="${repo_sha#sha256:}"

    if [[ -z "$local_tag" || "$local_tag" == "<none>:<none>" ]]; then
        local_tag="<none>"
    else
        local_tag="${local_tag##*:}"
    fi

    # Classify the registry once so the direct local-tag check and the optional
    # exhaustive scan use the same normalization.
    registry_classify "$repo"

    if [[ -n "$container" ]]; then
        echo "Container: $container"
        echo
    fi
    if [[ -n "$image_id" ]]; then
        echo "Local Image ID: $image_id"
        if [[ -n "$local_image_version" ]]; then
            echo "Image version:  $local_image_version"
        fi
    fi
    echo "Repository:     $repo"
    echo "Package digest: ${repo_digest##*@}"
    echo
    if [[ -n "$image_id" ]]; then
        echo "Local tag:  $local_tag"
    fi

    if [[ "$local_tag" == "<none>" ]]; then
        echo "Remote tag check: unavailable because this image has no known local tag"
    else
        remote_tag_reference="$repo:$local_tag"
        registry_resolve_tag_digest "$repo" "$local_tag"

        case "$remote_tag_status" in
        0)
            if [[ "${remote_tag_digest#sha256:}" == "$repo_sha" ]]; then
                echo "Remote tag check: MATCH — $remote_tag_reference still points to ${repo_digest##*@}"
            else
                echo "Remote tag check: MISMATCH — $remote_tag_reference now points to $remote_tag_digest"
            fi
            ;;
        1)
            echo "Remote tag check: NOT FOUND — $remote_tag_reference no longer exists at the registry"
            ;;
        *)
            abort "Failed to check remote tag '$remote_tag_reference'"
            ;;
        esac
    fi
    echo

    if [[ -n "$opt_local_only" ]]; then
        continue
    fi
    if [[ -z "$opt_all" ]]; then
        if choose_remote_tag_scan; then
            :
        else
            scan_choice_status=$?
            if (( scan_choice_status == 1 )); then
                continue
            fi
            abort "Cannot prompt to scan remote tags; rerun with --local-only or --all"
        fi
    fi

    registry_find_tags_by_digest "$repo" "sha256:$repo_sha"

    if [[ -n "$skip_input" ]]; then
        continue
    fi

    echo "Registry tag(s):"
    printf '%s\n' "${registry_tags:-<none>}"
    registry_print_metadata
    done <<<"$images_to_process"
done
