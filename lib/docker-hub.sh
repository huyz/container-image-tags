# shellcheck shell=bash

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

# Return the digest in one Docker Hub tag record without walking paginated tag
# results. Use LOOKUP_NOT_FOUND for a missing tag and LOOKUP_UNAVAILABLE for
# authentication or transport failures.
function docker_hub_digest_for_tag {
    local hub_repository="$1"
    local tag="$2"
    local tag_encoded response_tmp http_code manifest_digest token
    local -a request_args

    tag_encoded=$($JQ -rn --arg value "$tag" '$value | @uri')
    response_tmp=$(mktemp)
    request_args=(-sS -o "$response_tmp" -w '%{http_code}')
    if [[ -n "$docker_hub_token" ]]; then
        request_args+=(-H "Authorization: Bearer $docker_hub_token")
    fi
    if ! http_code=$(
        $CURL "${request_args[@]}" \
            "https://hub.docker.com/v2/repositories/$hub_repository/tags/$tag_encoded"
    ); then
        rm -f "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
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
    *)
        rm -f "$response_tmp"
        # An explicitly supplied Hub PAT takes precedence over the slower
        # registry-credential Skopeo fallback used by the dispatcher.
        if [[ -z "$docker_hub_token" ]] && token=$(docker_hub_token_from_environment); then
            docker_hub_token=$token
            notice "Docker Hub anonymous tag lookup failed; retrying with the configured username and PAT."
            docker_hub_digest_for_tag "$hub_repository" "$tag"
            return $?
        fi
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

# Explain why anonymous pagination stopped and offer the fast API retry, the
# available slower Skopeo fallback, or a per-image skip. Write "authenticated",
# "skopeo", or "skip" to the caller's named variable; return nonzero only when
# prompting is unavailable.
function choose_docker_hub_authentication {
    local failure_message="$1"
    local allow_skopeo_fallback="${2-}"
    local choice_variable="$3"
    local -n docker_hub_auth_result_ref="$choice_variable"
    local user_choice token auth_status

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
        case "$user_choice" in
        a | A)
            if token=$(docker_hub_token_interactively); then
                docker_hub_token=$token
                docker_hub_auth_result_ref=authenticated
                return
            else
                auth_status=$?
            fi
            (( auth_status == DOCKER_HUB_TOKEN_UNAVAILABLE )) && return 1
            ;;
        f | F)
            if [[ -n "$allow_skopeo_fallback" ]]; then
                docker_hub_auth_result_ref=skopeo
                return
            fi
            ;;
        s | S)
            docker_hub_auth_result_ref=skip
            return
            ;;
        esac
    done
}

# Populate registry_tags with Docker Hub tags matching digest. In "any" mode,
# stop after the first match other than registry_direct_tag. The shared
# skip_input flag is set when the user elects to skip after anonymous
# pagination is refused.
function docker_hub_tags_by_digest {
    local hub_repository="$1"
    local digest="$2"
    local display_repository="$3"
    local next_url response_tmp http_code error_message matching_tags token
    local authentication_choice
    local has_skopeo_credentials=
    local -a request_args

    digest="${digest#sha256:}"
    next_url="https://hub.docker.com/v2/repositories/$hub_repository/tags/?page_size=100"
    response_tmp=$(mktemp)
    while [[ -n "$next_url" ]]; do
        verbose "Listing Docker Hub tags from: $next_url"
        request_args=(-sS -o "$response_tmp" -w '%{http_code}')
        if [[ -n "$docker_hub_token" ]]; then
            request_args+=(-H "Authorization: Bearer $docker_hub_token")
        fi
        if ! http_code=$(
            $CURL "${request_args[@]}" "$next_url"
        ); then
            rm -f "$response_tmp"
            abort "Failed to list tags for $display_repository"
        fi
        error_message=$(
            $JQ -r '
                (.message // .detail // .error // empty)
                | if type == "string" then gsub("[\\r\\n]+"; " ") else tostring end
            ' "$response_tmp" 2>/dev/null || true
        )
        case "$http_code" in
        200) ;;
        401 | 403)
            if [[ -n "$docker_hub_token" ]]; then
                rm -f "$response_tmp"
                abort "Authenticated Docker Hub request failed with HTTP $http_code${error_message:+: $error_message}"
            fi
            if token=$(docker_hub_token_from_environment); then
                docker_hub_token=$token
                notice "Docker Hub refused anonymous tag pagination; retrying with the configured username and PAT."
                continue
            fi
            if skopeo_has_registry_credentials docker.io; then
                has_skopeo_credentials=1
            fi
            if ! choose_docker_hub_authentication \
                    "HTTP $http_code${error_message:+: $error_message}" \
                    "$has_skopeo_credentials" authentication_choice; then
                authentication_choice=unavailable
            fi
            case "$authentication_choice" in
            authenticated)
                continue
                ;;
            skopeo)
                notice "Using configured registry credentials with slower Skopeo lookup."
                ;;
            skip)
                notice "Skipping Docker Hub lookup for $display_repository."
                skip_input=1
                break
                ;;
            unavailable)
                [[ -n "$has_skopeo_credentials" ]] || {
                    rm -f "$response_tmp"
                    abort "Docker Hub authentication requires an interactive terminal"
                }
                notice "Docker Hub tags API was refused anonymously; using configured registry credentials with slower Skopeo lookup. Set DOCKER_HUB_USERNAME and DOCKER_HUB_PAT to retry the faster Docker Hub tags API."
                ;;
            *)
                rm -f "$response_tmp"
                abort "Docker Hub authentication returned an invalid choice"
                ;;
            esac
            if ! registry_tags=$(skopeo_tags_by_digest \
                    "$display_repository" "sha256:$digest"); then
                rm -f "$response_tmp"
                abort "Authenticated Skopeo lookup failed for $display_repository"
            fi
            registry_lookup_backend=skopeo
            next_url=
            break
            ;;
        *)
            rm -f "$response_tmp"
            abort "Docker Hub tag listing failed with HTTP $http_code${error_message:+: $error_message}"
            ;;
        esac
        # shellcheck disable=SC2016  # jq expression, not a shell expansion
        matching_tags=$(
            $JQ -r \
                --arg digest "$digest" \
                --arg tag_scan "$registry_tag_scan" \
                --arg direct_tag "$registry_direct_tag" '
                [
                    .results[]
                    | select(((.digest // "") | ltrimstr("sha256:")) == $digest)
                    | .name
                    | select($tag_scan != "any" or . != $direct_tag)
                ]
                | if $tag_scan == "any" then .[0] // empty else .[] end
            ' "$response_tmp"
        )
        if [[ -n "$matching_tags" ]]; then
            registry_tags+="${registry_tags:+$'\n'}$matching_tags"
            [[ "$registry_tag_scan" == any ]] && break
        fi
        next_url=$($JQ -r '.next // empty' "$response_tmp")
    done
    rm -f "$response_tmp"
}
