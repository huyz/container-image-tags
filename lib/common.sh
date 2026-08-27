# shellcheck shell=bash

# Shared output and prompting helpers for container-image-tags.

# Lookup functions print successful values to stdout and use these statuses for
# out-of-band outcomes. LOOKUP_STOPPED is terminal: callers must not retry with
# a more request-intensive fallback.
readonly LOOKUP_SUCCEEDED=0
readonly LOOKUP_NOT_FOUND=1
readonly LOOKUP_UNAVAILABLE=2
readonly LOOKUP_DENIED=3
readonly LOOKUP_STOPPED=4

# shellcheck disable=SC2329
function debug { [[ -z ${opt_debug-} ]] || printf "%s: 🔧 DEBUG: %s\n" "$SCRIPT_NAME" "$*" >&2; }
# shellcheck disable=SC2329
# Print repeated progress and implementation detail only when verbose output is
# requested. Hide these messages when they do not change the user's decisions.
function verbose { [[ -z ${opt_verbose-} ]] || printf "%s\n" "$*" >&2; }
# shellcheck disable=SC2329
function warn { printf "%s: ⚠️ WARNING: %s\n" "$SCRIPT_NAME" "$*" >&2; }
# shellcheck disable=SC2329
function abort { printf "%s: ❌ ERROR: %s\n" "$SCRIPT_NAME" "$*" >&2; exit 1; }

# Print one-time events that change input meaning, credentials, backend,
# expected duration, completeness, or result scope. These remain visible
# without verbose output.
function notice { printf "NOTICE: %s\n" "$*" >&2; }

# Interactive choices read from /dev/tty and prompts are written to stderr.
# Requiring both terminal input and terminal diagnostics ensures there is a user
# available to answer a visible prompt. stdout is intentionally excluded because
# normal command results may be redirected without making the session noninteractive.
function is_interactive_session {
    [[ -t 0 && -t 2 ]]
}

# Normalize one documented scan-choice spelling. Keeping this parser separate
# from /dev/tty access makes the accepted interactive vocabulary testable
# without depending on the test runner's terminal.
function remote_tag_scan_choice {
    local choice_lower

    choice_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$choice_lower" in
    1 | any) printf 'any\n' ;;
    a | all) printf 'all\n' ;;
    '' | n | no) printf 'none\n' ;;
    *) return 1 ;;
    esac
}

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
    local terminal_status=$LOOKUP_SUCCEEDED
    local match_found=
    local stop_scheduling=
    local matches=
    local -a active_pids=()
    local -a matching_indices=()
    local -a spinner=('|' '/' '-' $'\\')

    if is_interactive_session; then
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
            verbose "$worker_label: $tag"
            (
                if "$lookup_function" "$repository" "$tag" "$@" >"$result_tmp"; then
                    printf '%d\n' "$LOOKUP_SUCCEEDED" >"$status_tmp"
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
            if (( lookup_status == LOOKUP_SUCCEEDED )); then
                manifest_digest=$(<"$result_tmp")
            else
                ((++failed))
                if [[ -n "$require_complete" &&
                        "$lookup_status" == "$LOOKUP_STOPPED" ]]; then
                    terminal_status=$LOOKUP_STOPPED
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
            if is_interactive_session; then
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
    if is_interactive_session; then
        printf '\r%s... done (%d checked)\n' "$progress_label" "$checked" >&2
    fi

    printf '%s' "$matches"
    if (( terminal_status == LOOKUP_STOPPED )) &&
            [[ "$registry_tag_scan" != any || -z "$matches" ]]; then
        return "$LOOKUP_STOPPED"
    fi
    if [[ -n "$require_complete" && "$failed" -gt 0 ]] &&
            [[ "$registry_tag_scan" != any || -z "$matches" ]]; then
        return "$LOOKUP_UNAVAILABLE"
    fi
}

# Ask which reverse lookup to perform after the known local tag has been
# checked. Print "any", "all", or "none"; return nonzero only when prompting
# is unavailable.
function choose_remote_tag_scan {
    local choice action

    if ! is_interactive_session; then
        return 1
    fi
    echo "Scan remote tags?" >&2
    echo "  [1] Stop after any matching tag" >&2
    echo "  [a] Find all matching tags" >&2
    echo "  [n] Do not scan" >&2
    while true; do
        printf 'Choose [1/a/n]: ' >&2
        IFS= read -r choice </dev/tty || return 1
        if action=$(remote_tag_scan_choice "$choice"); then
            printf '%s\n' "$action"
            return
        fi
    done
}
