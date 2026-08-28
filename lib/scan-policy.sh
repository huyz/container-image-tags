# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # standalone module lint: shared scan fields

# Durable-tag classification and user-facing scan selection.

function remote_tag_scan_choice {
    local choice_lower

    choice_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$choice_lower" in
    1 | any) printf 'any\n' ;;
    d | durable | any-durable) printf 'any-durable\n' ;;
    a | all) printf 'all\n' ;;
    '' | n | no) printf 'none\n' ;;
    *) return 1 ;;
    esac
}

function tag_semver_precision {
    local tag="$1"
    local core component
    local precision=0

    tag="${tag#v}"
    tag="${tag#V}"
    core="${tag%%[-+]*}"
    [[ "$core" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
    while [[ -n "$core" ]]; do
        component="${core%%.*}"
        [[ -n "$component" ]] || return 1
        ((++precision))
        [[ "$core" == *.* ]] || break
        core="${core#*.}"
    done
    printf '%d\n' "$precision"
}

# Infer the most precise recurring semantic-version shape. Prefer a precision
# seen at least twice so one unusual tag does not redefine the convention.
function durable_semver_precision_from_tags {
    local tags="$1"
    local tag precision greatest='' recurring=''
    local -A precision_counts=()

    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        if precision=$(tag_semver_precision "$tag"); then
            precision_counts[$precision]=$(( ${precision_counts[$precision]:-0} + 1 ))
            if [[ -z "$greatest" || "$precision" -gt "$greatest" ]]; then
                greatest=$precision
            fi
        fi
    done <<<"$tags"
    for precision in "${!precision_counts[@]}"; do
        if (( precision_counts[$precision] >= 2 )) &&
                [[ -z "$recurring" || "$precision" -gt "$recurring" ]]; then
            recurring=$precision
        fi
    done
    printf '%s\n' "${recurring:-$greatest}"
}

function tag_is_assumed_durable {
    local tag="$1"
    local observed_precision="${2-}"
    local lower precision

    lower=$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
    latest | main | master | dev | devel | development | stable | edge | nightly | canary)
        return 1
        ;;
    esac
    if [[ "$lower" =~ ^[0-9a-f]{12,64}$ && "$lower" =~ [a-f] ]] ||
            [[ "$lower" =~ ^[0-9]{4}-?[0-9]{2}-?[0-9]{2}([._-].*)?$ ]]; then
        return 0
    fi
    precision=$(tag_semver_precision "$tag") || return 1
    if [[ -n "$observed_precision" ]]; then
        [[ "$precision" -eq "$observed_precision" ]]
    else
        (( precision >= 3 ))
    fi
}

function assumed_durable_tags {
    local tags="$1"
    local precision tag result=

    precision=$(durable_semver_precision_from_tags "$tags")
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        if tag_is_assumed_durable "$tag" "$precision"; then
            result+="${result:+$'\n'}$tag"
        fi
    done <<<"$tags"
    printf '%s' "$result"
}

function first_assumed_durable_tag {
    local candidates="$1"
    local observed_tags="${2-$candidates}"
    local precision tag

    precision=$(durable_semver_precision_from_tags "$observed_tags")
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        if tag_is_assumed_durable "$tag" "$precision"; then
            printf '%s\n' "$tag"
            return
        fi
    done <<<"$candidates"
}

function matching_tags_through_first_durable {
    local matching_tags="$1"
    local observed_tags="${2-$matching_tags}"
    local seed_tag="${3-}"
    local precision tag result=

    precision=$(durable_semver_precision_from_tags "$observed_tags")
    if [[ -n "$seed_tag" ]]; then
        result="$seed_tag"
        if tag_is_assumed_durable "$seed_tag" "$precision"; then
            printf '%s' "$result"
            return 0
        fi
    fi
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        [[ -z "$seed_tag" || "$tag" != "$seed_tag" ]] || continue
        result+="${result:+$'\n'}$tag"
        if tag_is_assumed_durable "$tag" "$precision"; then
            printf '%s' "$result"
            return 0
        fi
    done <<<"$matching_tags"
    printf '%s' "$result"
    return 1
}

function select_matching_tags_for_scan {
    local matching_tags="$1"
    local observed_tags="${2-$matching_tags}"
    local seed_tag=

    if [[ "$registry_tag_scan" == any ]]; then
        if [[ -n "${registry_direct_tag_confirmed-}" &&
                -n "${registry_direct_tag-}" ]]; then
            printf '%s' "$registry_direct_tag"
        else
            while IFS= read -r tag; do
                [[ -n "$tag" ]] || continue
                printf '%s' "$tag"
                break
            done <<<"$matching_tags"
        fi
        return
    fi
    if [[ "$registry_tag_scan" != any-durable ]]; then
        printf '%s' "$matching_tags"
        return
    fi
    if [[ -n "${registry_direct_tag_confirmed-}" &&
            -n "${registry_direct_tag-}" ]]; then
        seed_tag="$registry_direct_tag"
    fi
    matching_tags_through_first_durable \
        "$matching_tags" "$observed_tags" "$seed_tag"
}

function choose_remote_tag_scan {
    local choice action

    if ! is_interactive_session; then
        return 1
    fi
    echo "Scan remote tags?" >&2
    echo "  [1] Stop after the first matching tag" >&2
    echo "  [d] Stop after the first matching durable tag" >&2
    echo "  [a] Find all matching tags" >&2
    echo "  [n] Do not scan" >&2
    while true; do
        printf 'Choose [1/d/a/n]: ' >&2
        IFS= read -r choice </dev/tty || return 1
        if action=$(remote_tag_scan_choice "$choice"); then
            printf '%s\n' "$action"
            return
        fi
    done
}
