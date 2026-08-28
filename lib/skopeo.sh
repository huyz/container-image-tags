# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # standalone module lint: shared input/output fields

# Generic OCI registry fallback. Skopeo reads credentials written by
# skopeo/podman login and, as a fallback, Docker's config.json (including
# credential helpers). Keep all Skopeo calls behind these helpers so private
# registry behavior is consistent for direct checks and reverse lookups.
#
# Skopeo advertises separate session, isolated-public, configured-credential,
# and provider-token attempts to the policy engine. The engine controls their
# eligibility and order. The public and session authfiles are temporary,
# separate, and mode 0600.

skopeo_anonymous_authfile=
skopeo_session_authfile=
skopeo_inspect_platform_args=()

# Skopeo's generic reverse lookup launches one manifest inspection per tag.
# Keep the estimate deliberately simple and stable: its purpose is to identify
# obviously expensive scans, not to promise an exact completion time.
readonly SKOPEO_ESTIMATED_SECONDS_PER_TAG=2
readonly SKOPEO_MAX_PARALLEL_JOBS=8

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
        run_network_command "$SKOPEO" login --get-login "$registry" \
            >/dev/null 2>&1
}

function skopeo_digest_for_tag {
    local image_reference="$1"
    local authfile="${2-}"
    local -a auth_args=()

    skopeo_is_available || return 127
    [[ -z "$authfile" ]] || auth_args=(--authfile "$authfile")
    run_network_command "$SKOPEO" "${skopeo_inspect_platform_args[@]}" inspect \
        "${auth_args[@]}" --raw "docker://$image_reference" 2>/dev/null |
        run_network_command "$SKOPEO" manifest-digest /dev/stdin 2>/dev/null
}

function skopeo_digest_for_tag_worker {
    local repository="$1"
    local tag="$2"
    local authfile="${3-}"

    skopeo_digest_for_tag "$repository:$tag" "$authfile"
}

function skopeo_format_estimated_duration {
    registry_format_estimated_duration "$@"
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
        run_network_command "$SKOPEO" list-tags \
            "${auth_args[@]}" "docker://$repository" 2>"$error_tmp" |
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
        run_network_command "$SKOPEO" \
            "${skopeo_inspect_platform_args[@]}" inspect \
            "${auth_args[@]}" --raw "docker://$image_reference" 2>"$error_tmp" |
            run_network_command "$SKOPEO" manifest-digest \
                /dev/stdin 2>>"$error_tmp"
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
    run_network_command "$SKOPEO" login \
        --authfile "$skopeo_session_authfile" --get-login \
        "$registry" >/dev/null 2>&1
}

function skopeo_policy_is_available {
    skopeo_is_available
}

function skopeo_policy_session_is_available {
    local -n request_ref="$1"

    skopeo_session_has_registry "${request_ref[registry]}"
}

function skopeo_policy_configured_is_available {
    local -n request_ref="$1"

    skopeo_has_registry_credentials "${request_ref[registry]}"
}

function skopeo_policy_provider_auth_is_available {
    local -n request_ref="$1"

    [[ -n "${request_ref[provider_auth_callback]-}" ]] && skopeo_is_available
}

function skopeo_policy_attempt {
    local request_name="$1"
    local result_name="$2"
    local authfile="${3-}"
    local -n request_ref="$request_name"
    local -n result_ref="$result_name"
    local output status

    if [[ "${request_ref[operation]}" == direct ]]; then
        if output=$(skopeo_digest_for_tag_with_status \
                "${request_ref[display_reference]}" "$authfile"); then
            result_ref[digest]="$output"
            return "$LOOKUP_SUCCEEDED"
        else
            return $?
        fi
    fi

    if output=$(skopeo_tags_by_digest \
            "${request_ref[display_repository]}" \
            "${request_ref[digest]}" "$authfile"); then
        result_ref[tags]="$output"
        return "$LOOKUP_SUCCEEDED"
    else
        status=$?
    fi
    return "$status"
}

function skopeo_policy_attempt_session {
    skopeo_policy_attempt "$1" "$2" "$skopeo_session_authfile"
}

function skopeo_policy_attempt_public {
    skopeo_policy_attempt "$1" "$2" "$skopeo_anonymous_authfile"
}

function skopeo_policy_attempt_configured {
    local request_name="$1"
    local -n request_ref="$request_name"

    notice "Using configured registry credentials for '${request_ref[registry]}'."
    skopeo_policy_attempt "$request_name" "$2"
}

function skopeo_policy_attempt_provider_auth {
    local request_name="$1"
    local -n request_ref="$request_name"
    local authenticate_function="${request_ref[provider_auth_callback]}"

    "$authenticate_function" "${request_ref[registry]}" ||
        return "$LOOKUP_UNAVAILABLE"
    skopeo_policy_attempt "$request_name" "$2" "$skopeo_session_authfile"
}

# Every supported registry can use the same compatibility mechanisms. The
# provider supplies only an optional short-lived credential callback.
function skopeo_register_policy_attempts {
    local request_name="$1"
    local id_prefix="$2"
    local first_cost="${3:-70}"

    policy_add_attempt "$id_prefix-skopeo-session" \
        skopeo_policy_attempt_session skopeo "$POLICY_ACCESS_SESSION" \
        "$first_cost" 1 skopeo_policy_session_is_available
    policy_add_attempt "$id_prefix-skopeo-public" \
        skopeo_policy_attempt_public skopeo "$POLICY_ACCESS_PUBLIC" \
        "$(( first_cost + 10 ))" 1 skopeo_policy_is_available
    policy_add_attempt "$id_prefix-skopeo-configured" \
        skopeo_policy_attempt_configured skopeo "$POLICY_ACCESS_CREDENTIAL" \
        "$(( first_cost + 20 ))" 1 skopeo_policy_configured_is_available
    local -n request_ref="$request_name"
    if [[ -n "${request_ref[provider_auth_callback]-}" ]]; then
        policy_add_attempt "$id_prefix-skopeo-provider" \
            skopeo_policy_attempt_provider_auth skopeo "$POLICY_ACCESS_CREDENTIAL" \
            "$(( first_cost + 30 ))" 1 skopeo_policy_provider_auth_is_available
    fi
}
