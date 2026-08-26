# shellcheck shell=bash

# Generic OCI registry fallback. Skopeo reads credentials written by
# skopeo/podman login and, as a fallback, Docker's config.json (including
# credential helpers). Keep all Skopeo calls behind these helpers so private
# registry behavior is consistent for direct checks and reverse lookups.

skopeo_anonymous_authfile=
skopeo_session_authfile=
skopeo_inspect_platform_args=()

# Skopeo's generic reverse lookup launches one manifest inspection per tag.
# Keep the estimate deliberately simple and stable: its purpose is to identify
# obviously expensive scans, not to promise an exact completion time.
readonly SKOPEO_ESTIMATED_SECONDS_PER_TAG=2
readonly SKOPEO_MAX_PARALLEL_JOBS=8
readonly EXPENSIVE_SCAN_THRESHOLD_SECONDS_INTERACTIVE=180
readonly EXPENSIVE_SCAN_THRESHOLD_SECONDS_NONINTERACTIVE=600

# Native Skopeo sees macOS as Darwin, but Docker Desktop runs container images
# inside a Linux VM. Override only the OS on macOS so multi-platform inspection
# selects a Linux image without breaking legitimate Windows-image lookups on
# other hosts.
if [[ "$OSTYPE" == darwin* ]]; then
    skopeo_inspect_platform_args=(--override-os linux)
fi

# Create isolated authfiles before entering a command substitution. The empty
# authfile guarantees that the first request does not send cached credentials;
# the session authfile holds only short-lived credentials obtained after an
# authentication challenge.
function skopeo_prepare_lazy_auth {
    [[ -n "$skopeo_anonymous_authfile" ]] && return

    skopeo_anonymous_authfile=$(mktemp)
    skopeo_session_authfile=$(mktemp)
    chmod 600 "$skopeo_anonymous_authfile" "$skopeo_session_authfile"
    printf '{"auths":{}}\n' >"$skopeo_anonymous_authfile"
    printf '{"auths":{}}\n' >"$skopeo_session_authfile"
    trap skopeo_cleanup_lazy_auth EXIT
}

function skopeo_cleanup_lazy_auth {
    [[ -z "$skopeo_anonymous_authfile" ]] || rm -f "$skopeo_anonymous_authfile"
    [[ -z "$skopeo_session_authfile" ]] || rm -f "$skopeo_session_authfile"
}

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
    local authfile="${2-}"
    local -a auth_args=()

    skopeo_is_available || return 127
    [[ -z "$authfile" ]] || auth_args=(--authfile "$authfile")
    "$SKOPEO" "${skopeo_inspect_platform_args[@]}" inspect \
        "${auth_args[@]}" --raw "docker://$image_reference" 2>/dev/null |
        "$SKOPEO" manifest-digest /dev/stdin 2>/dev/null
}

function skopeo_digest_for_tag_worker {
    local repository="$1"
    local tag="$2"
    local authfile="${3-}"

    skopeo_digest_for_tag "$repository:$tag" "$authfile"
}

function skopeo_format_estimated_duration {
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

# Warn before an expensive interactive scan. Non-interactive callers cannot
# acknowledge an advisory, so require an explicit override and fail before the
# first per-tag manifest lookup. Registry fast paths share the same thresholds
# while supplying their own conservative per-batch estimate.
function registry_expensive_scan_preflight {
    local backend="$1"
    local repository="$2"
    local candidate_count="$3"
    local parallel_jobs="$4"
    local estimated_seconds_per_batch="$5"
    local estimated_batches=$(( (candidate_count + parallel_jobs - 1) / parallel_jobs ))
    local estimated_seconds=$(( estimated_batches * estimated_seconds_per_batch ))
    local estimated_duration scan_description threshold worker_description

    if [[ "$registry_tag_scan" == any ]]; then
        scan_description="may inspect up to $candidate_count tags"
    else
        scan_description="will inspect $candidate_count tags"
    fi
    estimated_duration=$(skopeo_format_estimated_duration "$estimated_seconds")
    worker_description="$parallel_jobs parallel worker"
    (( parallel_jobs == 1 )) || worker_description+=s

    if is_interactive_session; then
        threshold=$EXPENSIVE_SCAN_THRESHOLD_SECONDS_INTERACTIVE
        if (( estimated_seconds > threshold )); then
            warn "$backend $scan_description for $repository; estimated time is about $estimated_duration with $worker_description. Continuing because this is an interactive run."
        fi
        return 0
    fi

    threshold=$EXPENSIVE_SCAN_THRESHOLD_SECONDS_NONINTERACTIVE
    if (( estimated_seconds > threshold )); then
        if [[ -n ${opt_allow_expensive_scan-} ]]; then
            notice "$backend $scan_description for $repository; estimated time is about $estimated_duration with $worker_description. Continuing because --allow-expensive-scan was specified."
        else
            notice "$backend $scan_description for $repository; estimated time is about $estimated_duration with $worker_description. Rerun with --allow-expensive-scan to permit this non-interactive scan."
            return 4
        fi
    fi
}

function skopeo_expensive_scan_preflight {
    registry_expensive_scan_preflight \
        Skopeo "$1" "$2" "$3" "$SKOPEO_ESTIMATED_SECONDS_PER_TAG"
}

function skopeo_tags_by_digest {
    local repository="$1"
    local digest="$2"
    local authfile="${3-}"
    local tags tag error_tmp skopeo_status
    local candidate_count parallel_jobs
    local -a auth_args=()
    local -a candidate_tags=()

    skopeo_is_available || return 127
    [[ -z "$authfile" ]] || auth_args=(--authfile "$authfile")
    info "Listing registry tags with skopeo for $repository"
    error_tmp=$(mktemp)
    if tags=$(
        "$SKOPEO" list-tags "${auth_args[@]}" "docker://$repository" 2>"$error_tmp" |
            $JQ -r '.Tags[]?'
    ); then
        rm -f "$error_tmp"
    else
        skopeo_status=$?
        if grep -Eqi 'unauthorized|authentication required|access denied|denied:|status( code)?:? (401|403)' "$error_tmp"; then
            skopeo_status=3
        fi
        debug "Skopeo tag listing failed for $repository: $(tr '\n' ' ' <"$error_tmp")"
        rm -f "$error_tmp"
        return "$skopeo_status"
    fi

    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        if [[ "$registry_tag_scan" == any && "$tag" == "$registry_direct_tag" ]]; then
            continue
        fi
        candidate_tags+=("$tag")
    done <<<"$tags"
    candidate_count=${#candidate_tags[@]}
    parallel_jobs=$SKOPEO_MAX_PARALLEL_JOBS
    (( candidate_count < parallel_jobs )) && parallel_jobs=$candidate_count
    (( parallel_jobs > 0 )) || parallel_jobs=1
    skopeo_expensive_scan_preflight \
        "$repository" "$candidate_count" "$parallel_jobs" || return $?

    tags_by_digest_with_rolling_pool \
        "$repository" "$digest" candidate_tags "$parallel_jobs" \
        'Searching registry tags with skopeo' \
        'Resolving registry tag with skopeo' \
        skopeo_digest_for_tag_worker '' "$authfile"
}

# Resolve one tag while distinguishing a missing manifest from an access
# denial. Return 0 for success, 1 for not found, 2 for other failures, and 3
# for a denial that may require authentication or may hide an unavailable
# repository.
function skopeo_digest_for_tag_with_status {
    local image_reference="$1"
    local authfile="${2-}"
    local manifest_digest error_tmp skopeo_status
    local -a auth_args=()

    skopeo_is_available || return 127
    [[ -z "$authfile" ]] || auth_args=(--authfile "$authfile")
    error_tmp=$(mktemp)
    if manifest_digest=$(
        "$SKOPEO" "${skopeo_inspect_platform_args[@]}" inspect \
            "${auth_args[@]}" --raw "docker://$image_reference" 2>"$error_tmp" |
            "$SKOPEO" manifest-digest /dev/stdin 2>>"$error_tmp"
    ); then
        rm -f "$error_tmp"
        printf '%s\n' "$manifest_digest"
        return 0
    else
        skopeo_status=$?
    fi

    if grep -Eqi 'unauthorized|authentication required|access denied|denied:|status( code)?:? (401|403)' "$error_tmp"; then
        skopeo_status=3
    elif grep -Eqi 'manifest unknown|name unknown|not found|status( code)?:? 404' "$error_tmp"; then
        skopeo_status=1
    else
        skopeo_status=2
    fi
    debug "Skopeo tag lookup failed for $image_reference: $(tr '\n' ' ' <"$error_tmp")"
    rm -f "$error_tmp"
    return "$skopeo_status"
}

function skopeo_session_has_registry {
    local registry="$1"

    skopeo_is_available || return 1
    "$SKOPEO" login --authfile "$skopeo_session_authfile" --get-login \
        "$registry" >/dev/null 2>&1
}

# Try an isolated anonymous request, configured registry credentials, and then
# a registry-specific short-lived-login function, in that order.
function skopeo_digest_for_tag_with_lazy_auth {
    local registry="$1"
    local image_reference="$2"
    local authenticate_function="$3"
    local manifest_digest lookup_status

    if skopeo_session_has_registry "$registry"; then
        skopeo_digest_for_tag_with_status "$image_reference" "$skopeo_session_authfile"
        return $?
    fi

    if manifest_digest=$(skopeo_digest_for_tag_with_status \
            "$image_reference" "$skopeo_anonymous_authfile"); then
        printf '%s\n' "$manifest_digest"
        return 0
    else
        lookup_status=$?
    fi
    (( lookup_status == 3 )) || return "$lookup_status"

    if skopeo_has_registry_credentials "$registry"; then
        notice "Using configured registry credentials for '$registry'."
        if manifest_digest=$(skopeo_digest_for_tag_with_status "$image_reference"); then
            printf '%s\n' "$manifest_digest"
            return 0
        else
            lookup_status=$?
        fi
        (( lookup_status == 3 )) || return "$lookup_status"
    fi

    "$authenticate_function" "$registry" || return 2
    skopeo_digest_for_tag_with_status "$image_reference" "$skopeo_session_authfile"
}

function skopeo_tags_by_digest_with_lazy_auth {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local authenticate_function="$4"
    local tags lookup_status

    if skopeo_session_has_registry "$registry"; then
        skopeo_tags_by_digest "$repository" "$digest" "$skopeo_session_authfile"
        return $?
    fi

    if tags=$(skopeo_tags_by_digest \
            "$repository" "$digest" "$skopeo_anonymous_authfile"); then
        printf '%s' "$tags"
        return 0
    else
        lookup_status=$?
    fi
    (( lookup_status == 3 )) || return "$lookup_status"

    if skopeo_has_registry_credentials "$registry"; then
        notice "Using configured registry credentials for '$registry'."
        if tags=$(skopeo_tags_by_digest "$repository" "$digest"); then
            printf '%s' "$tags"
            return 0
        else
            lookup_status=$?
        fi
        (( lookup_status == 3 )) || return "$lookup_status"
    fi

    "$authenticate_function" "$registry" || return 2
    skopeo_tags_by_digest "$repository" "$digest" "$skopeo_session_authfile"
}
