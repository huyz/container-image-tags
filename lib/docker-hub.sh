# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2154,SC2178  # shared fields and namerefs

# Docker Hub API fast path and its authentication flow.

# Token-producing functions reserve stdout for the token and use these named
# statuses for distinctions their callers need to preserve.
readonly DOCKER_HUB_ENV_CREDENTIALS_MISSING=1
readonly DOCKER_HUB_ENV_CREDENTIALS_INCOMPLETE=2
readonly DOCKER_HUB_TOKEN_REJECTED=1
readonly DOCKER_HUB_TOKEN_UNAVAILABLE=2

# Normalize Docker's implicit and explicit Hub repository forms for the API.
function docker_hub_repository {
    local repository="$1"

    case "$repository" in
    docker.io/* | index.docker.io/* | registry-1.docker.io/*)
        repository="${repository#*/}"
        ;;
    esac
    if [[ "$repository" != */* ]]; then
        repository="library/$repository"
    fi
    printf '%s\n' "$repository"
}

# Write the short-lived Hub API bearer token to a mode-0600 curl header file so
# it cannot be observed in the process list.
function docker_hub_write_request_headers {
    local header_file="$1"

    : >"$header_file"
    chmod 600 "$header_file"
    printf 'Authorization: Bearer %s\n' "$docker_hub_token" >"$header_file"
}

# Return the digest in one Docker Hub tag record without walking paginated tag
# results. Use LOOKUP_NOT_FOUND for a missing tag and LOOKUP_UNAVAILABLE for
# authentication or transport failures.
function docker_hub_digest_for_tag {
    local hub_repository="$1"
    local tag="$2"
    local tag_encoded response_tmp request_headers='' http_code manifest_digest
    local -a request_args

    tag_encoded=$($JQ -rn --arg value "$tag" '$value | @uri')
    response_tmp=$(runtime_temp_file docker-hub-response)
    request_args=()
    if [[ -n "$docker_hub_token" ]]; then
        request_headers=$(runtime_temp_file docker-hub-request-headers)
        docker_hub_write_request_headers "$request_headers"
        request_args+=(-H "@$request_headers")
    fi
    if ! http_code=$(registry_http_request GET \
            "https://hub.docker.com/v2/repositories/$hub_repository/tags/$tag_encoded" \
            "$response_tmp" '' "${request_args[@]}"); then
        rm -f "$response_tmp"
        [[ -z "$request_headers" ]] || rm -f "$request_headers"
        return "$LOOKUP_UNAVAILABLE"
    fi
    [[ -z "$request_headers" ]] || rm -f "$request_headers"
    case "$http_code" in
    200)
        manifest_digest=$($JQ -r '.digest // empty' "$response_tmp")
        rm -f "$response_tmp"
        [[ -n "$manifest_digest" ]] || return "$LOOKUP_UNAVAILABLE"
        printf '%s\n' "$manifest_digest"
        ;;
    404)
        rm -f "$response_tmp"
        return "$LOOKUP_NOT_FOUND"
        ;;
    401 | 403)
        rm -f "$response_tmp"
        debug "Docker Hub tag lookup returned HTTP $http_code for $hub_repository:$tag"
        return "$LOOKUP_DENIED"
        ;;
    429)
        rm -f "$response_tmp"
        return "$LOOKUP_STOPPED"
        ;;
    *)
        rm -f "$response_tmp"
        debug "Docker Hub tag lookup returned HTTP $http_code for $hub_repository:$tag"
        return "$LOOKUP_UNAVAILABLE"
        ;;
    esac
}

# Exchange a Docker Hub username and PAT for a short-lived API access token.
# Both callers keep the credentials only long enough to make this request.
function docker_hub_token_from_credentials {
    local identifier="$1"
    local secret="$2"
    local response http_code response_body token error_message

    if ! response=$(
        printf '%s\n%s\n' "$identifier" "$secret" |
            $JQ -Rnc '{identifier: input, secret: input}' |
            $CURL -sS -w $'\n%{http_code}' \
                -H 'Content-Type: application/json' \
                --data-binary @- \
                'https://hub.docker.com/v2/auth/token'
    ); then
        secret=
        warn "Docker Hub authentication request failed"
        return "$DOCKER_HUB_TOKEN_REJECTED"
    fi
    secret=
    http_code="${response##*$'\n'}"
    response_body="${response%$'\n'*}"
    response=

    if [[ "$http_code" == 200 ]]; then
        token=$($JQ -r '.access_token // .token // empty' <<<"$response_body")
        response_body=
        if [[ -n "$token" ]]; then
            printf '%s\n' "$token"
            return 0
        fi
        warn "Docker Hub authentication response did not contain an access token"
        return "$DOCKER_HUB_TOKEN_REJECTED"
    fi

    error_message=$(
        $JQ -r '(.detail // .message // .error // empty) | if type == "string" then . else tostring end' \
            <<<"$response_body" 2>/dev/null || true
    )
    response_body=
    warn "Docker Hub authentication failed (HTTP $http_code)${error_message:+: $error_message}"
    return "$DOCKER_HUB_TOKEN_REJECTED"
}

# Exchange environment-supplied credentials only after Docker Hub refuses the
# anonymous request. This keeps the normal public path anonymous while letting
# automated callers retain the fast Hub API rather than falling back to Skopeo.
# Use the named environment-credential statuses to distinguish absent from
# incomplete configuration.
function docker_hub_token_from_environment {
    if [[ -z ${DOCKER_HUB_USERNAME-} && -z ${DOCKER_HUB_PAT-} ]]; then
        return "$DOCKER_HUB_ENV_CREDENTIALS_MISSING"
    fi
    if [[ -z ${DOCKER_HUB_USERNAME-} || -z ${DOCKER_HUB_PAT-} ]]; then
        warn "Set both DOCKER_HUB_USERNAME and DOCKER_HUB_PAT to authenticate Docker Hub's fast tags API."
        return "$DOCKER_HUB_ENV_CREDENTIALS_INCOMPLETE"
    fi
    docker_hub_token_from_credentials "$DOCKER_HUB_USERNAME" "$DOCKER_HUB_PAT"
}

# Exchange a Docker Hub username and PAT read from the controlling terminal.
function docker_hub_token_interactively {
    local identifier secret token

    if ! is_interactive_session; then
        return "$DOCKER_HUB_TOKEN_UNAVAILABLE"
    fi
    printf 'Docker Hub username: ' >&2
    IFS= read -r identifier </dev/tty || return "$DOCKER_HUB_TOKEN_UNAVAILABLE"
    [[ -n "$identifier" ]] || {
        warn "Docker Hub username cannot be empty"
        return "$DOCKER_HUB_TOKEN_REJECTED"
    }

    printf 'Docker Hub personal access token ("Public Repo Read-only" minimum): ' >&2
    IFS= read -rs secret </dev/tty || return "$DOCKER_HUB_TOKEN_UNAVAILABLE"
    printf '\n' >&2
    [[ -n "$secret" ]] || {
        warn "Docker Hub personal access token cannot be empty"
        return "$DOCKER_HUB_TOKEN_REJECTED"
    }

    if token=$(docker_hub_token_from_credentials "$identifier" "$secret"); then
        secret=
        printf '%s\n' "$token"
        return 0
    fi
    secret=
    return "$DOCKER_HUB_TOKEN_REJECTED"
}

function docker_hub_authentication_action {
    local choice="$1"
    local allow_skopeo_fallback="${2-}"

    case "$choice" in
    a | A) printf 'authenticate\n' ;;
    f | F)
        [[ -n "$allow_skopeo_fallback" ]] || return 1
        printf 'skopeo\n'
        ;;
    s | S) printf 'skip\n' ;;
    *) return 1 ;;
    esac
}

# Recover a denied direct tag lookup by collecting a Hub PAT from the
# controlling terminal. Return success only after exchanging the credentials
# for an in-session API token; declining leaves the original denial intact.
function choose_docker_hub_direct_authentication {
    local display_reference="$1"
    local user_choice action token auth_status

    if ! is_interactive_session; then
        return 1
    fi
    echo "$SCRIPT_NAME: Docker Hub denied access to '$display_reference'." >&2
    echo "  [a] Authenticate with a Docker Hub username and PAT" >&2
    echo "  [s] Stop without authenticating" >&2
    while true; do
        printf 'Choose [a/s]: ' >&2
        IFS= read -r user_choice </dev/tty || return 1
        action=$(docker_hub_authentication_action "$user_choice" '') || continue
        case "$action" in
        authenticate)
            if token=$(docker_hub_token_interactively); then
                docker_hub_token=$token
                return
            else
                auth_status=$?
            fi
            (( auth_status == DOCKER_HUB_TOKEN_UNAVAILABLE )) && return 1
            ;;
        skip) return 1 ;;
        esac
    done
}

# Explain why anonymous pagination stopped and offer the fast API retry, the
# available slower Skopeo fallback, or a per-image skip. Write "authenticated",
# "skopeo", or "skip" to the caller's named variable; return nonzero only when
# prompting is unavailable.
function choose_docker_hub_authentication {
    local failure_message="$1"
    local allow_skopeo_fallback="${2-}"
    local choice_variable="$3"
    local -n docker_hub_auth_result_ref="$choice_variable"
    local user_choice action token auth_status

    docker_hub_auth_result_ref=
    if ! is_interactive_session; then
        return 1
    fi
    echo "$SCRIPT_NAME: Docker Hub refused further anonymous tag pagination." >&2
    [[ -z "$failure_message" ]] || echo "  $failure_message" >&2
    echo "  [a] Authenticate with a Docker Hub username and PAT (fast tags API)" >&2
    if [[ -n "$allow_skopeo_fallback" ]]; then
        echo "  [f] Use configured registry credentials with slower Skopeo lookup" >&2
    fi
    echo "  [s] Skip this image" >&2
    while true; do
        if [[ -n "$allow_skopeo_fallback" ]]; then
            printf 'Choose [a/f/s]: ' >&2
        else
            printf 'Choose [a/s]: ' >&2
        fi
        IFS= read -r user_choice </dev/tty || return 1
        action=$(docker_hub_authentication_action \
            "$user_choice" "$allow_skopeo_fallback") || continue
        case "$action" in
        authenticate)
            if token=$(docker_hub_token_interactively); then
                docker_hub_token=$token
                docker_hub_auth_result_ref=authenticated
                return
            else
                auth_status=$?
            fi
            (( auth_status == DOCKER_HUB_TOKEN_UNAVAILABLE )) && return 1
            ;;
        skopeo)
            docker_hub_auth_result_ref=skopeo
            return
            ;;
        skip)
            docker_hub_auth_result_ref=skip
            return
            ;;
        esac
    done
}

# Populate registry_tags with Docker Hub tags matching digest. "any" stops at
# the first match; "any-durable" stops after the first match heuristically
# assumed durable. The shared
# skip_input flag is set when the user elects to skip after anonymous
# pagination is refused.
function docker_hub_tags_by_digest {
    local hub_repository="$1"
    local digest="$2"
    local display_repository="$3"
    local next_url response_tmp request_headers='' http_code error_message matching_tags
    local page_tags page_matches durable_precision durable_found
    local page_started_ms page_finished_ms page_elapsed_ms total_tag_count total_pages
    local remaining_pages
    local pagination_cost_checked=
    local -a request_args

    digest="${digest#sha256:}"
    next_url="https://hub.docker.com/v2/repositories/$hub_repository/tags/?page_size=100"
    response_tmp=$(runtime_temp_file docker-hub-response)
    while [[ -n "$next_url" ]]; do
        verbose "Listing Docker Hub tags from: $next_url"
        request_args=()
        if [[ -n "$docker_hub_token" ]]; then
            request_headers=$(runtime_temp_file docker-hub-request-headers)
            docker_hub_write_request_headers "$request_headers"
            request_args+=(-H "@$request_headers")
        fi
        page_started_ms=$(registry_now_milliseconds)
        if ! http_code=$(registry_http_request GET \
                "$next_url" "$response_tmp" '' "${request_args[@]}"); then
            rm -f "$response_tmp"
            [[ -z "$request_headers" ]] || rm -f "$request_headers"
            return "$LOOKUP_UNAVAILABLE"
        fi
        page_finished_ms=$(registry_now_milliseconds)
        page_elapsed_ms=$(( page_finished_ms - page_started_ms ))
        (( page_elapsed_ms > 0 )) || page_elapsed_ms=1
        [[ -z "$request_headers" ]] || rm -f "$request_headers"
        request_headers=
        error_message=$(registry_json_error_message "$response_tmp")
        case "$http_code" in
        200) ;;
        401 | 403)
            debug "Docker Hub tag listing returned HTTP $http_code for $display_repository${error_message:+: $error_message}"
            rm -f "$response_tmp"
            return "$LOOKUP_DENIED"
            ;;
        *)
            debug "Docker Hub tag listing failed with HTTP $http_code for $display_repository${error_message:+: $error_message}"
            rm -f "$response_tmp"
            case "$http_code" in
            404) return "$LOOKUP_NOT_FOUND" ;;
            429) return "$LOOKUP_STOPPED" ;;
            *) return "$LOOKUP_UNAVAILABLE" ;;
            esac
            ;;
        esac
        if [[ "$registry_tag_scan" == all && -z "$pagination_cost_checked" ]]; then
            total_tag_count=$($JQ -r '.count // 0' "$response_tmp")
            if [[ "$total_tag_count" =~ ^[0-9]+$ ]] && (( total_tag_count > 0 )); then
                total_pages=$(( (total_tag_count + 99) / 100 ))
                remaining_pages=$(( total_pages - 1 ))
                if (( remaining_pages > 0 )); then
                    registry_expensive_work_preflight \
                        'Docker Hub API' "$display_repository" \
                        "may request up to $remaining_pages additional tag pages" \
                        "$remaining_pages" 1 "$page_elapsed_ms" || {
                        rm -f "$response_tmp"
                        return "$LOOKUP_STOPPED"
                    }
                fi
            fi
            pagination_cost_checked=1
        fi
        page_tags=$($JQ -r '.results[].name' "$response_tmp")
        if [[ "$registry_tag_scan" == any-durable ]]; then
            durable_precision=$(durable_semver_precision_from_tags "$page_tags")
            if [[ -n "${registry_direct_tag_confirmed-}" &&
                    -n "$registry_direct_tag" ]] &&
                    tag_is_assumed_durable "$registry_direct_tag" "$durable_precision"; then
                registry_tags="$registry_direct_tag"
                break
            fi
            if [[ -n "${registry_direct_tag_confirmed-}" &&
                    -n "$registry_direct_tag" && -z "$registry_tags" ]]; then
                registry_tags="$registry_direct_tag"
            fi
        fi
        matching_tags=$($JQ -r --arg digest "$digest" '
            .results[]
            | select(((.digest // "") | ltrimstr("sha256:")) == $digest)
            | .name
        ' "$response_tmp")
        if [[ "$registry_tag_scan" == any ]]; then
            page_matches=
            while IFS= read -r tag; do
                [[ -n "$tag" ]] || continue
                page_matches="$tag"
                break
            done <<<"$matching_tags"
            matching_tags="$page_matches"
        elif [[ "$registry_tag_scan" == any-durable ]]; then
            matching_tags=$(printf '%s\n' "$matching_tags" |
                while IFS= read -r tag; do
                    [[ -n "$tag" ]] || continue
                    if [[ -n "${registry_direct_tag_confirmed-}" &&
                            "$tag" == "$registry_direct_tag" ]]; then
                        continue
                    fi
                    printf '%s\n' "$tag"
                done)
            durable_found=
            if page_matches=$(matching_tags_through_first_durable \
                    "$matching_tags" "$page_tags"); then
                durable_found=1
            fi
            matching_tags="$page_matches"
        fi
        if [[ -n "$matching_tags" ]]; then
            registry_tags+="${registry_tags:+$'\n'}$matching_tags"
            if [[ "$registry_tag_scan" == any ||
                    "$registry_tag_scan" == any-durable && -n "$durable_found" ]]; then
                break
            fi
        fi
        next_url=$($JQ -r '.next // empty' "$response_tmp")
    done
    rm -f "$response_tmp"
}

function docker_hub_policy_session_is_available {
    [[ -n "$docker_hub_token" ]]
}

function docker_hub_policy_environment_is_available {
    [[ -n ${DOCKER_HUB_USERNAME-} || -n ${DOCKER_HUB_PAT-} ]]
}

function docker_hub_policy_attempt_api {
    local request_name="$1"
    local result_name="$2"
    local -n request_ref="$request_name"
    local -n result_ref="$result_name"
    local output status

    if [[ "${request_ref[operation]}" == direct ]]; then
        if output=$(docker_hub_digest_for_tag \
                "${request_ref[repository]}" "${request_ref[tag]}"); then
            result_ref[digest]="$output"
            return "$LOOKUP_SUCCEEDED"
        else
            status=$?
            return "$status"
        fi
    fi
    if docker_hub_tags_by_digest \
            "${request_ref[repository]}" "${request_ref[digest]}" \
            "${request_ref[display_repository]}"; then
        result_ref[tags]="$registry_tags"
        return "$LOOKUP_SUCCEEDED"
    else
        status=$?
    fi
    return "$status"
}

function docker_hub_policy_attempt_environment {
    local token

    if [[ -z "$docker_hub_token" ]]; then
        token=$(docker_hub_token_from_environment) || return "$LOOKUP_UNAVAILABLE"
        docker_hub_token="$token"
        notice "Docker Hub denied public access; retrying the tags API with the configured username and PAT."
    fi
    docker_hub_policy_attempt_api "$1" "$2"
}

function docker_hub_policy_attempt_interactive {
    local request_name="$1"
    local result_name="$2"
    local -n request_ref="$request_name"
    local -n result_ref="$result_name"
    local authentication_choice

    if [[ "${request_ref[operation]}" == direct ]]; then
        choose_docker_hub_direct_authentication \
            "${request_ref[display_reference]}" || return "$LOOKUP_DENIED"
    else
        if ! choose_docker_hub_authentication \
                'Automatic credential paths were not usable.' '' \
                authentication_choice; then
            return "$LOOKUP_DENIED"
        fi
        if [[ "$authentication_choice" == skip ]]; then
            notice "Skipping Docker Hub lookup for ${request_ref[display_repository]}."
            skip_input=1
            result_ref[tags]=
            result_ref[skip]=1
            return "$LOOKUP_SUCCEEDED"
        fi
        [[ "$authentication_choice" == authenticated ]] ||
            return "$LOOKUP_DENIED"
    fi
    docker_hub_policy_attempt_api "$request_name" "$result_name"
}

function docker_hub_register_policy_attempts {
    local request_name="$1"

    policy_add_attempt docker-hub-session docker_hub_policy_attempt_api \
        docker-hub-api "$POLICY_ACCESS_SESSION" 5 1 \
        docker_hub_policy_session_is_available
    policy_add_attempt docker-hub-public docker_hub_policy_attempt_api \
        docker-hub-api "$POLICY_ACCESS_PUBLIC" 10
    policy_add_attempt docker-hub-environment docker_hub_policy_attempt_environment \
        docker-hub-api "$POLICY_ACCESS_CREDENTIAL" 20 1 \
        docker_hub_policy_environment_is_available
    skopeo_register_policy_attempts "$request_name" docker-hub 70
    policy_add_attempt docker-hub-interactive docker_hub_policy_attempt_interactive \
        docker-hub-api "$POLICY_ACCESS_INTERACTIVE" 110
}
