# shellcheck shell=bash

# Docker Hub API fast path and its authentication flow.

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
# results. A missing tag returns 1; authentication or transport failures
# return 2.
function docker_hub_digest_for_tag {
    local hub_repository="$1"
    local tag="$2"
    local tag_encoded response_tmp http_code manifest_digest
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
        return 2
    fi
    case "$http_code" in
    200)
        manifest_digest=$($JQ -r '.digest // empty' "$response_tmp")
        rm -f "$response_tmp"
        [[ -n "$manifest_digest" ]] || return 2
        printf '%s\n' "$manifest_digest"
        ;;
    404)
        rm -f "$response_tmp"
        return 1
        ;;
    *)
        debug "Docker Hub tag lookup returned HTTP $http_code for $hub_repository:$tag"
        rm -f "$response_tmp"
        return 2
        ;;
    esac
}

# Exchange a Docker Hub username and PAT for a short-lived API access token.
# Credentials are read from the controlling terminal, sent through stdin, and
# retained only long enough to perform the exchange.
function docker_hub_token_interactively {
    local identifier secret response http_code response_body token error_message

    if [[ ! -t 0 && ! -t 1 && ! -t 2 ]]; then
        return 2
    fi
    printf 'Docker Hub username: ' >&2
    IFS= read -r identifier </dev/tty || return 2
    [[ -n "$identifier" ]] || { warn "Docker Hub username cannot be empty"; return 1; }

    printf 'Docker Hub personal access token ("Public Repo Read-only" minimum): ' >&2
    IFS= read -rs secret </dev/tty || return 2
    printf '\n' >&2
    [[ -n "$secret" ]] || { warn "Docker Hub personal access token cannot be empty"; return 1; }

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
        return 1
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
        return 1
    fi

    error_message=$(
        $JQ -r '(.detail // .message // .error // empty) | if type == "string" then . else tostring end' \
            <<<"$response_body" 2>/dev/null || true
    )
    response_body=
    warn "Docker Hub authentication failed (HTTP $http_code)${error_message:+: $error_message}"
    return 1
}

# Explain why anonymous pagination stopped and offer authentication or a
# per-image skip. The access token is printed on success; return 1 for skip and
# 2 when no controlling terminal is available.
function choose_docker_hub_authentication {
    local failure_message="$1"
    local choice token auth_status

    if [[ ! -t 0 && ! -t 1 && ! -t 2 ]]; then
        return 2
    fi
    echo "$SCRIPT_NAME: Docker Hub refused further anonymous tag pagination." >&2
    [[ -z "$failure_message" ]] || echo "  $failure_message" >&2
    echo "  [a] Authenticate for this run with a Docker Hub username and PAT" >&2
    echo "  [s] Skip this image" >&2
    while true; do
        printf 'Choose [a/s]: ' >&2
        IFS= read -r choice </dev/tty || return 2
        case "$choice" in
        a | A)
            if token=$(docker_hub_token_interactively); then
                printf '%s\n' "$token"
                return 0
            else
                auth_status=$?
            fi
            (( auth_status == 2 )) && return 2
            ;;
        s | S)
            return 1
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
    local next_url response_tmp http_code error_message matching_tags auth_status
    local -a request_args

    digest="${digest#sha256:}"
    next_url="https://hub.docker.com/v2/repositories/$hub_repository/tags/?page_size=100"
    response_tmp=$(mktemp)
    while [[ -n "$next_url" ]]; do
        info "Listing Docker Hub tags from: $next_url"
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
            if skopeo_has_registry_credentials docker.io; then
                notice "Using configured registry credentials for private Docker Hub lookup."
                if ! registry_tags=$(skopeo_tags_by_digest "$display_repository" "sha256:$digest"); then
                    rm -f "$response_tmp"
                    abort "Authenticated Skopeo lookup failed for $display_repository"
                fi
                next_url=
                break
            fi
            if docker_hub_token=$(
                choose_docker_hub_authentication \
                    "HTTP $http_code${error_message:+: $error_message}"
            ); then
                continue
            else
                auth_status=$?
            fi
            if (( auth_status == 1 )); then
                notice "Skipping Docker Hub lookup for $display_repository."
                skip_input=1
                break
            fi
            rm -f "$response_tmp"
            abort "Docker Hub authentication requires an interactive terminal"
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
