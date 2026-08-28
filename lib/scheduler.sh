# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2178  # shared fields and array namerefs

# Bounded, deterministic worker scheduling for per-tag digest lookups.

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
