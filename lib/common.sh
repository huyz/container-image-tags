# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # standalone module lint: shared input/output fields

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
    d | durable | any-durable) printf 'any-durable\n' ;;
    a | all) printf 'all\n' ;;
    '' | n | no) printf 'none\n' ;;
    *) return 1 ;;
    esac
}

# Return the numeric precision of a semantic-version-like tag. An optional v
# prefix and prerelease/build suffix do not change the precision: v1.2.3-rc.1
# has precision 3. Other tags return nonzero without output.
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

# Infer the most precise recurring semantic-version shape in a newline-delimited
# tag sample. Prefer the greatest precision seen at least twice so one unusual
# tag does not redefine a repository's release convention; otherwise use the
# greatest precision present.
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

# Heuristically classify one tag as durable. Known channel names always float.
# With an observed precision, only the repository's most precise semver shape
# is durable. Without a sample, require a strong standalone signal so a direct
# tag can safely satisfy "any-durable" without starting a bulk scan.
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

# Filter a newline-delimited tag set to tags assumed durable under the inferred
# repository convention, preserving order and exact tag values.
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

# Print matching tags in order through the first tag assumed durable. Return
# success only when a durable tag was present; callers can continue searching
# after receiving floating matches when the return status is nonzero.
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

# Apply the public scan-mode contract to one complete provider tag set. In
# "any" mode returns the first match, including a directly confirmed tag.
# "any-durable" retains a directly confirmed tag and floating matches in
# provider order through the first durable match. "all" returns every match.
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

# Run one digest lookup per candidate tag while keeping a bounded number of
# workers in flight. Bash 4.4 has wait -n but cannot report which PID finished,
# so workers publish completion markers. Results are emitted in candidate order
# even when lookups finish out of order. The lookup function receives the
# repository, tag, and any remaining arguments and prints one complete digest.
# When require_complete is nonempty, failed workers make an exhaustive lookup
# fail; a bounded lookup may still succeed once it has its requested match.
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
    local bounded_match_found=
    local stop_scheduling=
    local matches=
    local -a active_pids=()
    local -a matching_indices=()
    local -a spinner=('|' '/' '-' $'\\')

    if is_interactive_session && [[ -z $opt_verbose ]]; then
        printf '%s... %s (0 checked)' "$progress_label" "${spinner[0]}" >&2
    fi
    worker_tmp=$(runtime_temp_dir workers)
    next_tag_index=0
    active_jobs=0
    while (( next_tag_index < ${#pool_candidate_tags[@]} || active_jobs > 0 )); do
        while [[ -z "$bounded_match_found" && -z "$stop_scheduling" ]] &&
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
            active_pids[tag_index]=$!
            runtime_register_child "${active_pids[$tag_index]}"
            ((++next_tag_index))
            ((++active_jobs))
        done

        (( active_jobs > 0 )) || break
        wait -n || true

        # A worker can be killed before it publishes its completion marker.
        # Detect that state after wait -n and convert it into an ordinary
        # unavailable result so active_jobs cannot remain nonzero forever.
        for tag_index in "${!active_pids[@]}"; do
            done_tmp="$worker_tmp/$tag_index.done"
            [[ -e "$done_tmp" ]] && continue
            worker_pid=${active_pids[$tag_index]}
            if ! kill -0 "$worker_pid" 2>/dev/null; then
                wait "$worker_pid" 2>/dev/null || true
                status_tmp="$worker_tmp/$tag_index.status"
                [[ -e "$status_tmp" ]] ||
                    printf '%d\n' "$LOOKUP_UNAVAILABLE" >"$status_tmp"
                : >"$done_tmp"
            fi
        done

        for tag_index in "${!active_pids[@]}"; do
            done_tmp="$worker_tmp/$tag_index.done"
            [[ -e "$done_tmp" ]] || continue
            tag=${pool_candidate_tags[$tag_index]}
            result_tmp="$worker_tmp/$tag_index.result"
            status_tmp="$worker_tmp/$tag_index.status"
            worker_pid=${active_pids[$tag_index]}
            # wait -n may already have reaped this PID. The status file is the
            # authoritative result; this exact wait only finishes cleanup.
            wait "$worker_pid" 2>/dev/null || true
            runtime_unregister_child "$worker_pid"
            lookup_status=$(<"$status_tmp")
            manifest_digest=
            if (( lookup_status == LOOKUP_SUCCEEDED )); then
                manifest_digest=$(<"$result_tmp")
            elif (( lookup_status != LOOKUP_NOT_FOUND )); then
                ((++failed))
                if [[ -n "$require_complete" ]]; then
                    case "$lookup_status" in
                    "$LOOKUP_STOPPED") terminal_status=$LOOKUP_STOPPED; stop_scheduling=1 ;;
                    "$LOOKUP_DENIED")
                        (( terminal_status == LOOKUP_STOPPED )) ||
                            terminal_status=$LOOKUP_DENIED
                        stop_scheduling=1
                        ;;
                    esac
                fi
            fi
            rm -f "$result_tmp" "$status_tmp" "$done_tmp"
            unset 'active_pids[tag_index]'
            active_jobs=$((active_jobs - 1))

            if [[ "$manifest_digest" == "$digest" ]]; then
                matching_indices[tag_index]=1
                case "$registry_tag_scan" in
                any) bounded_match_found=1 ;;
                any-durable)
                    if tag_is_assumed_durable "$tag" \
                            "${registry_durable_semver_precision-}"; then
                        bounded_match_found=1
                    fi
                    ;;
                esac
            fi
            ((++checked))
            if is_interactive_session && [[ -z $opt_verbose ]]; then
                printf '\r%s... %s (%d checked)' \
                    "$progress_label" "${spinner[checked % 4]}" "$checked" >&2
            fi
        done
    done
    rmdir "$worker_tmp"

    matches="${registry_seed_matching_tags-}"
    for (( tag_index = 0; tag_index < next_tag_index; ++tag_index )); do
        [[ -n ${matching_indices[$tag_index]-} ]] || continue
        tag=${pool_candidate_tags[$tag_index]}
        matches+="${matches:+$'\n'}$tag"
        case "$registry_tag_scan" in
        any) break ;;
        any-durable)
            if tag_is_assumed_durable "$tag" \
                    "${registry_durable_semver_precision-}"; then
                break
            fi
            ;;
        esac
    done
    if is_interactive_session; then
        printf '\r%s... done (%d checked)\n' "$progress_label" "$checked" >&2
    fi

    printf '%s' "$matches"
    if (( terminal_status == LOOKUP_STOPPED ||
            terminal_status == LOOKUP_DENIED )) &&
            [[ "$registry_tag_scan" != any &&
                "$registry_tag_scan" != any-durable || -z "$matches" ]]; then
        return "$terminal_status"
    fi
    if [[ -n "$require_complete" && "$failed" -gt 0 ]] &&
            [[ "$registry_tag_scan" != any &&
                "$registry_tag_scan" != any-durable || -z "$matches" ]]; then
        return "$LOOKUP_UNAVAILABLE"
    fi
}

# Ask which reverse lookup to perform after the known local tag has been
# checked. Print "any", "any-durable", "all", or "none"; return nonzero only
# when prompting is unavailable.
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
