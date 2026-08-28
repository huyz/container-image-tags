# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # standalone module lint: shared input/output fields

# Generic OCI registry fallback. Skopeo reads credentials written by
# skopeo/podman login and, as a fallback, Docker's config.json (including
# credential helpers). Keep all Skopeo calls behind these helpers so private
# registry behavior is consistent for direct checks and reverse lookups.
#
# `skopeo_with_access_policy` gives Skopeo one unambiguous meaning in the
# fallback matrix. Subject to --credential-policy, it reuses an in-session
# token, tries isolated public access, tries configured registry credentials
# after an explicit denial, and finally obtains a provider token after another
# denial. LOOKUP_UNAVAILABLE may select Skopeo as another backend, but never
# authorizes credentials by itself. The public and session authfiles are
# temporary, separate, and mode 0600.

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

    skopeo_anonymous_authfile=$(runtime_temp_file skopeo-anonymous-auth)
    skopeo_session_authfile=$(runtime_temp_file skopeo-session-auth)
    chmod 600 "$skopeo_anonymous_authfile" "$skopeo_session_authfile"
    printf '{"auths":{}}\n' >"$skopeo_anonymous_authfile"
    printf '{"auths":{}}\n' >"$skopeo_session_authfile"
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

    if [[ "$registry_tag_scan" == any ||
            "$registry_tag_scan" == any-durable ]]; then
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
            return "$LOOKUP_STOPPED"
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
    local candidate_count parallel_jobs durable_precision
    local -a auth_args=()
    local -a candidate_tags=()

    skopeo_is_available || return 127
    [[ -z "$authfile" ]] || auth_args=(--authfile "$authfile")
    verbose "Listing registry tags with skopeo for $repository"
    error_tmp=$(runtime_temp_file skopeo-error)
    if tags=$(
        "$SKOPEO" list-tags "${auth_args[@]}" "docker://$repository" 2>"$error_tmp" |
            $JQ -r '.Tags[]?'
    ); then
        rm -f "$error_tmp"
    else
        skopeo_status=$?
        if grep -Eqi 'unauthorized|authentication required|access denied|denied:|status( code)?:? (401|403)' "$error_tmp"; then
            skopeo_status=$LOOKUP_DENIED
        elif grep -Eqi 'manifest unknown|name unknown|not found|status( code)?:? 404' "$error_tmp"; then
            skopeo_status=$LOOKUP_NOT_FOUND
        elif grep -Eqi 'too many requests|rate.?limit|status( code)?:? 429' "$error_tmp"; then
            skopeo_status=$LOOKUP_STOPPED
        else
            skopeo_status=$LOOKUP_UNAVAILABLE
        fi
        debug "Skopeo tag listing failed for $repository: $(command_error_single_line "$error_tmp")"
        rm -f "$error_tmp"
        return "$skopeo_status"
    fi

    durable_precision=$(durable_semver_precision_from_tags "$tags")
    registry_durable_semver_precision="$durable_precision"
    if [[ "$registry_tag_scan" == any-durable &&
            -n "${registry_direct_tag_confirmed-}" &&
            -n "$registry_direct_tag" ]] &&
            tag_is_assumed_durable "$registry_direct_tag" "$durable_precision"; then
        printf '%s\n' "$registry_direct_tag"
        return
    fi
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        if [[ "$registry_tag_scan" == any-durable &&
                -n "${registry_direct_tag_confirmed-}" &&
                "$tag" == "$registry_direct_tag" ]]; then
            registry_seed_matching_tags="$tag"
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
# denial. Use the shared LOOKUP_* status contract; command-not-found remains
# the conventional shell status 127.
function skopeo_digest_for_tag_with_status {
    local image_reference="$1"
    local authfile="${2-}"
    local manifest_digest error_tmp skopeo_status
    local -a auth_args=()

    skopeo_is_available || return 127
    [[ -z "$authfile" ]] || auth_args=(--authfile "$authfile")
    error_tmp=$(runtime_temp_file skopeo-error)
    if manifest_digest=$(
        "$SKOPEO" "${skopeo_inspect_platform_args[@]}" inspect \
            "${auth_args[@]}" --raw "docker://$image_reference" 2>"$error_tmp" |
            "$SKOPEO" manifest-digest /dev/stdin 2>>"$error_tmp"
    ); then
        rm -f "$error_tmp"
        printf '%s\n' "$manifest_digest"
        return "$LOOKUP_SUCCEEDED"
    else
        skopeo_status=$?
    fi

    if grep -Eqi 'unauthorized|authentication required|access denied|denied:|status( code)?:? (401|403)' "$error_tmp"; then
        skopeo_status=$LOOKUP_DENIED
    elif grep -Eqi 'manifest unknown|name unknown|not found|status( code)?:? 404' "$error_tmp"; then
        skopeo_status=$LOOKUP_NOT_FOUND
    elif grep -Eqi 'too many requests|rate.?limit|status( code)?:? 429' "$error_tmp"; then
        skopeo_status=$LOOKUP_STOPPED
    else
        skopeo_status=$LOOKUP_UNAVAILABLE
    fi
    debug "Skopeo tag lookup failed for $image_reference: $(command_error_single_line "$error_tmp")"
    rm -f "$error_tmp"
    return "$skopeo_status"
}

function skopeo_session_has_registry {
    local registry="$1"

    skopeo_is_available || return 1
    "$SKOPEO" login --authfile "$skopeo_session_authfile" --get-login \
        "$registry" >/dev/null 2>&1
}

# Run one Skopeo operation through explicit credential classes. `prior_status`
# describes a public native attempt already made by the caller. A denial may
# advance to credentials; an unavailable native backend may try anonymous
# Skopeo compatibility, but cannot itself authorize credentials.
function skopeo_with_access_policy {
    local operation="$1"
    local registry="$2"
    local authenticate_function="$3"
    local prior_status="$4"
    shift 4
    local output lookup_status="$prior_status"
    local -a operation_args=("$@")

    if credential_policy_allows_credentials &&
            skopeo_session_has_registry "$registry"; then
        "$operation" "${operation_args[@]}" "$skopeo_session_authfile"
        return $?
    fi

    if credential_policy_allows_public; then
        if [[ "$lookup_status" != "$LOOKUP_DENIED" ]]; then
            if output=$("$operation" \
                    "${operation_args[@]}" "$skopeo_anonymous_authfile"); then
                printf '%s' "$output"
                return "$LOOKUP_SUCCEEDED"
            else
                lookup_status=$?
            fi
        fi
        credential_policy_allows_auth_after "$lookup_status" ||
            return "$lookup_status"
    else
        lookup_status=$LOOKUP_DENIED
    fi

    credential_policy_allows_credentials || return "$lookup_status"
    if skopeo_has_registry_credentials "$registry"; then
        notice "Using configured registry credentials for '$registry'."
        if output=$("$operation" "${operation_args[@]}"); then
            printf '%s' "$output"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
        (( lookup_status == LOOKUP_DENIED )) || return "$lookup_status"
    fi

    [[ -n "$authenticate_function" ]] || return "$lookup_status"
    "$authenticate_function" "$registry" || return "$LOOKUP_UNAVAILABLE"
    "$operation" "${operation_args[@]}" "$skopeo_session_authfile"
}

function skopeo_digest_for_tag_with_access_policy {
    local registry="$1"
    local image_reference="$2"
    local authenticate_function="${3-}"
    local prior_status="${4-}"

    skopeo_with_access_policy skopeo_digest_for_tag_with_status \
        "$registry" "$authenticate_function" "$prior_status" "$image_reference"
}

function skopeo_tags_by_digest_with_access_policy {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local authenticate_function="${4-}"
    local prior_status="${5-}"

    skopeo_with_access_policy skopeo_tags_by_digest \
        "$registry" "$authenticate_function" "$prior_status" "$repository" "$digest"
}

# Compatibility names for provider adapters while they migrate independently.
function skopeo_digest_for_tag_with_lazy_auth {
    skopeo_digest_for_tag_with_access_policy "$@"
}

function skopeo_tags_by_digest_with_lazy_auth {
    skopeo_tags_by_digest_with_access_policy "$@"
}
