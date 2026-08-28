# shellcheck shell=bash

# Registry credential policy. Backend selection and credential selection are
# deliberately separate: an unavailable public backend may fall back to a
# different public backend, but it must not by itself authorize credentials.

readonly EXPENSIVE_SCAN_THRESHOLD_SECONDS_INTERACTIVE=180
readonly EXPENSIVE_SCAN_THRESHOLD_SECONDS_NONINTERACTIVE=600

function registry_now_milliseconds {
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

function registry_format_estimated_duration {
    local total_seconds="$1"
    local minutes=$(( total_seconds / 60 ))
    local seconds=$(( total_seconds % 60 ))

    if (( minutes > 0 && seconds > 0 )); then
        printf '%dm %ds' "$minutes" "$seconds"
    elif (( minutes > 0 )); then
        printf '%dm' "$minutes"
    else
        printf '%ds' "$seconds"
    fi
}

function registry_estimated_milliseconds {
    local candidate_count="$1"
    local parallel_jobs="$2"
    local estimated_milliseconds_per_batch="$3"
    local estimated_batches=$(( (candidate_count + parallel_jobs - 1) / parallel_jobs ))

    printf '%d\n' "$(( estimated_batches * estimated_milliseconds_per_batch ))"
}

# Apply one common advisory/refusal policy to any measurable bulk operation.
# Providers supply a human-readable work description plus request/batch count,
# concurrency, and observed or conservative milliseconds per batch.
function registry_expensive_work_preflight {
    local backend="$1"
    local repository="$2"
    local work_description="$3"
    local candidate_count="$4"
    local parallel_jobs="$5"
    local estimated_milliseconds_per_batch="$6"
    local estimated_milliseconds estimated_seconds estimated_duration threshold
    local worker_description

    (( parallel_jobs > 0 )) || parallel_jobs=1
    estimated_milliseconds=$(registry_estimated_milliseconds \
        "$candidate_count" "$parallel_jobs" "$estimated_milliseconds_per_batch")
    estimated_seconds=$(( (estimated_milliseconds + 999) / 1000 ))
    estimated_duration=$(registry_format_estimated_duration "$estimated_seconds")
    worker_description="$parallel_jobs parallel worker"
    (( parallel_jobs == 1 )) || worker_description+=s

    if is_interactive_session; then
        threshold=$EXPENSIVE_SCAN_THRESHOLD_SECONDS_INTERACTIVE
        if (( estimated_seconds > threshold )); then
            warn "$backend $work_description for $repository; estimated time is about $estimated_duration with $worker_description. Continuing because this is an interactive run."
        fi
        return 0
    fi

    threshold=$EXPENSIVE_SCAN_THRESHOLD_SECONDS_NONINTERACTIVE
    if (( estimated_seconds > threshold )); then
        if [[ -n ${opt_allow_expensive_scan-} ]]; then
            notice "$backend $work_description for $repository; estimated time is about $estimated_duration with $worker_description. Continuing because --allow-expensive-scan was specified."
        else
            notice "$backend $work_description for $repository; estimated time is about $estimated_duration with $worker_description. Rerun with --allow-expensive-scan to permit this non-interactive scan."
            return "$LOOKUP_STOPPED"
        fi
    fi
}

# Compatibility wrapper for existing per-tag callers. New pagination and
# metadata backends call registry_expensive_work_preflight directly.
function registry_expensive_scan_preflight {
    local backend="$1"
    local repository="$2"
    local candidate_count="$3"
    local parallel_jobs="$4"
    local estimated_seconds_per_batch="$5"
    local scan_description

    if [[ "${registry_tag_scan-}" == any ||
            "${registry_tag_scan-}" == any-durable ]]; then
        scan_description="may inspect up to $candidate_count tags"
    else
        scan_description="will inspect $candidate_count tags"
    fi
    registry_expensive_work_preflight \
        "$backend" "$repository" "$scan_description" "$candidate_count" \
        "$parallel_jobs" "$(( estimated_seconds_per_batch * 1000 ))"
}
