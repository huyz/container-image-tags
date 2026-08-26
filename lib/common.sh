# shellcheck shell=bash

# Shared output and prompting helpers for container-image-tags.

# shellcheck disable=SC2329
function debug { [[ -z ${opt_debug-} ]] || printf "%s: 🔧 DEBUG: %s\n" "$SCRIPT_NAME" "$*" >&2; }
# shellcheck disable=SC2329
function info { [[ -z ${opt_verbose-} ]] || printf "%s\n" "$*" >&2; }
# shellcheck disable=SC2329
function warn { printf "%s: ⚠️ WARNING: %s\n" "$SCRIPT_NAME" "$*" >&2; }
# shellcheck disable=SC2329
function err { printf "%s: ❗ ERROR: %s\n" "$SCRIPT_NAME" "$*" >&2; }
# shellcheck disable=SC2329
function abort { printf "%s: ❌ ERROR: %s\n" "$SCRIPT_NAME" "$*" >&2; exit 1; }

function notice { printf "INFO: %s\n" "$*" >&2; }

# Run one digest lookup per candidate tag while keeping a bounded number of
# workers in flight. Bash 4.4 has wait -n but cannot report which PID finished,
# so workers publish completion markers. Results are emitted in candidate order
# even when lookups finish out of order. The lookup function receives the
# repository, tag, and any remaining arguments and prints one complete digest.
# When require_complete is nonempty, failed workers make an exhaustive lookup
# fail; an "any" lookup may still succeed once it has a definite match.
function tags_by_digest_with_rolling_pool {
    local repository="$1"
    local digest="$2"
    local candidate_array_name="$3"
    local parallel_jobs="$4"
    local progress_label="$5"
    local worker_label="$6"
    local lookup_function="$7"
    local require_complete="$8"
    shift 8
    local -n pool_candidate_tags="$candidate_array_name"
    local tag manifest_digest tag_index next_tag_index active_jobs
    local worker_tmp result_tmp status_tmp done_tmp lookup_status worker_pid
    local checked=0
    local failed=0
    local terminal_status=0
    local match_found=
    local stop_scheduling=
    local matches=
    local -a active_pids=()
    local -a matching_indices=()
    local -a spinner=('|' '/' '-' $'\\')

    if [[ -z ${opt_verbose-} ]]; then
        printf '%s... %s (0 checked)' "$progress_label" "${spinner[0]}" >&2
    fi
    worker_tmp=$(mktemp -d)
    next_tag_index=0
    active_jobs=0
    while (( next_tag_index < ${#pool_candidate_tags[@]} || active_jobs > 0 )); do
        while [[ -z "$match_found" && -z "$stop_scheduling" ]] &&
                (( active_jobs < parallel_jobs &&
                    next_tag_index < ${#pool_candidate_tags[@]} )); do
            tag_index=$next_tag_index
            tag=${pool_candidate_tags[$tag_index]}
            result_tmp="$worker_tmp/$tag_index.result"
            status_tmp="$worker_tmp/$tag_index.status"
            done_tmp="$worker_tmp/$tag_index.done"
            info "$worker_label: $tag"
            (
                if "$lookup_function" "$repository" "$tag" "$@" >"$result_tmp"; then
                    printf '0\n' >"$status_tmp"
                else
                    printf '%d\n' "$?" >"$status_tmp"
                fi
                : >"$done_tmp"
            ) &
            active_pids[$tag_index]=$!
            ((++next_tag_index))
            ((++active_jobs))
        done

        (( active_jobs > 0 )) || break
        wait -n || true

        for tag_index in "${!active_pids[@]}"; do
            done_tmp="$worker_tmp/$tag_index.done"
            [[ -e "$done_tmp" ]] || continue
            result_tmp="$worker_tmp/$tag_index.result"
            status_tmp="$worker_tmp/$tag_index.status"
            worker_pid=${active_pids[$tag_index]}
            # wait -n may already have reaped this PID. The status file is the
            # authoritative result; this exact wait only finishes cleanup.
            wait "$worker_pid" 2>/dev/null || true
            lookup_status=$(<"$status_tmp")
            manifest_digest=
            if (( lookup_status == 0 )); then
                manifest_digest=$(<"$result_tmp")
            else
                ((++failed))
                if [[ -n "$require_complete" && "$lookup_status" == 4 ]]; then
                    terminal_status=4
                    stop_scheduling=1
                fi
            fi
            rm -f "$result_tmp" "$status_tmp" "$done_tmp"
            unset 'active_pids[tag_index]'
            active_jobs=$((active_jobs - 1))

            if [[ "$manifest_digest" == "$digest" ]]; then
                matching_indices[$tag_index]=1
                [[ "$registry_tag_scan" == any ]] && match_found=1
            fi
            ((++checked))
            if [[ -z ${opt_verbose-} ]]; then
                printf '\r%s... %s (%d checked)' \
                    "$progress_label" "${spinner[checked % 4]}" "$checked" >&2
            fi
        done
    done
    rmdir "$worker_tmp"

    for (( tag_index = 0; tag_index < next_tag_index; ++tag_index )); do
        [[ -n ${matching_indices[$tag_index]-} ]] || continue
        tag=${pool_candidate_tags[$tag_index]}
        matches+="${matches:+$'\n'}$tag"
        [[ "$registry_tag_scan" == any ]] && break
    done
    if [[ -z ${opt_verbose-} ]]; then
        printf '\r%s... done (%d checked)\n' "$progress_label" "$checked" >&2
    fi

    printf '%s' "$matches"
    if (( terminal_status == 4 )) &&
            [[ "$registry_tag_scan" != any || -z "$matches" ]]; then
        return 4
    fi
    if [[ -n "$require_complete" && "$failed" -gt 0 ]] &&
            [[ "$registry_tag_scan" != any || -z "$matches" ]]; then
        return 2
    fi
}

# Ask which reverse lookup to perform after the known local tag has been
# checked. Return 0 for any match, 1 for all matches, 2 for no scan, and 3
# when prompting is unavailable.
function choose_remote_tag_scan {
    local choice choice_lower

    if [[ ! -t 0 && ! -t 1 && ! -t 2 ]]; then
        return 3
    fi
    echo "Scan remote tags?" >&2
    echo "  [1] Stop after any matching tag" >&2
    echo "  [a] Find all matching tags" >&2
    echo "  [n] Do not scan" >&2
    while true; do
        printf 'Choose [1/a/n]: ' >&2
        IFS= read -r choice </dev/tty || return 3
        choice_lower=$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')
        case "$choice_lower" in
        1 | any) return 0 ;;
        a | all) return 1 ;;
        '' | n | no) return 2 ;;
        esac
    done
}
