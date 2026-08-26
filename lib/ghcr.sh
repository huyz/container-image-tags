# shellcheck shell=bash

# GitHub Container Registry fast paths: GitHub Packages API and anonymous OCI.

readonly GHCR_MANIFEST_ACCEPT_HEADER='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

function ghcr_write_request_headers {
    local header_file="$1"
    local token="$2"

    : >"$header_file"
    chmod 600 "$header_file"
    printf 'Authorization: Bearer %s\n' "$token" >"$header_file"
    printf '%s\n' "$GHCR_MANIFEST_ACCEPT_HEADER" >>"$header_file"
}

# Look up an active GHCR package version by immutable digest or current tag.
# GitHub's Packages API exposes the digest, timestamps, and current tags in the
# same object, so no tag-by-tag manifest lookup is needed.
#
# Return values:
#   LOOKUP_SUCCEEDED: version found (printed as compact JSON)
#   LOOKUP_NOT_FOUND: API queried successfully, but no active version matched
#   LOOKUP_UNAVAILABLE: API could not be queried
function ghcr_package_version {
    local ghcr_repository="$1"
    local selector="$2"
    local wanted="$3"
    local owner package_name package_encoded owner_kind endpoint response_tmp error_tmp match
    local api_status gh_error
    local queried_api=

    owner="${ghcr_repository%%/*}"
    package_name="${ghcr_repository#*/}"
    if [[ "$ghcr_repository" != */* || -z "$owner" || -z "$package_name" ]]; then
        debug "GHCR Packages API rejected repository components: repository=$ghcr_repository owner=$owner package=$package_name"
        return "$LOOKUP_UNAVAILABLE"
    fi

    # shellcheck disable=SC2016  # jq expression, not a shell expansion
    package_encoded=$($JQ -rn --arg value "$package_name" '$value | @uri')

    if ! command -v "${GH:=gh}" &>/dev/null; then
        debug "GitHub Packages API command is unavailable: $GH"
        return "$LOOKUP_UNAVAILABLE"
    fi
    response_tmp=$(mktemp)
    error_tmp=$(mktemp)

    # A GHCR namespace can belong to either an organization or a user. Try
    # both owner-specific Packages API endpoints.
    for owner_kind in orgs users; do
        endpoint="/$owner_kind/$owner/packages/container/$package_encoded/versions?per_page=100"
        verbose "Searching GitHub package versions for $owner_kind/$owner/$package_name"
        if "$GH" api --paginate "$endpoint" >"$response_tmp" 2>"$error_tmp"; then
            queried_api=1
        else
            api_status=$?
            gh_error=$(<"$error_tmp")
            gh_error=${gh_error//$'\n'/; }
            if ((${#gh_error} > 1000)); then
                gh_error="${gh_error:0:1000}..."
            fi
            [[ -n "$gh_error" ]] || gh_error="no stderr output"
            debug "GitHub Packages API request failed: endpoint=$endpoint status=$api_status error=$gh_error"
            continue
        fi

        # gh emits one JSON array per page. Combine the pages and use GitHub's
        # creation timestamp as the recency signal before selecting a version.
        # shellcheck disable=SC2016  # jq expression, not a shell expansion
        match=$(
            $JQ -sc --arg selector "$selector" --arg wanted "$wanted" '
                (add // [])
                | sort_by(.created_at)
                | reverse
                | first(
                    .[]
                    | select(
                        if $selector == "digest" then
                            .name == $wanted
                        else
                            (.metadata.container.tags // [] | index($wanted)) != null
                        end
                    )
                ) // empty
            ' "$response_tmp"
        )
        if [[ -n "$match" ]]; then
            rm -f "$response_tmp" "$error_tmp"
            printf '%s\n' "$match"
            return "$LOOKUP_SUCCEEDED"
        fi
    done

    rm -f "$response_tmp" "$error_tmp"
    [[ -n "$queried_api" ]] && return "$LOOKUP_NOT_FOUND"
    return "$LOOKUP_UNAVAILABLE"
}

function ghcr_package_version_by_digest {
    ghcr_package_version "$1" digest "$2"
}

function ghcr_package_version_by_tag {
    ghcr_package_version "$1" tag "$2"
}

# Request a repository-scoped anonymous GHCR pull token.
function ghcr_anonymous_pull_token {
    local ghcr_repository="$1"
    local auth_header realm service scope token
    local -a token_args

    if ! auth_header=$(
        $CURL -sS -D - -o /dev/null "https://ghcr.io/v2/$ghcr_repository/tags/list" |
            perl -ne 'if (/^www-authenticate:\s*(.*)/i) { print "$1\n"; exit }'
    ); then
        return 1
    fi
    realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$auth_header")
    service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$auth_header")
    scope=$(sed -n 's/.*scope="\([^"]*\)".*/\1/p' <<<"$auth_header")
    [[ -n "$realm" ]] || return 1

    token_args=(-fsS -G)
    [[ -n "$service" ]] && token_args+=(--data-urlencode "service=$service")
    [[ -n "$scope" ]] && token_args+=(--data-urlencode "scope=$scope")
    token=$(
        $CURL "${token_args[@]}" "$realm" |
            $JQ -r '.token // .access_token // empty'
    ) || return 1
    [[ -n "$token" ]] || return 1
    printf '%s\n' "$token"
}

# Return the current remote digest for one public GHCR tag without enumerating
# any other tags. Use LOOKUP_NOT_FOUND for a missing tag and LOOKUP_UNAVAILABLE
# for authentication or transport failures.
function ghcr_digest_for_tag_anonymously {
    local ghcr_repository="$1"
    local tag="$2"
    local tag_encoded token request_headers header_tmp http_code manifest_digest

    token=$(ghcr_anonymous_pull_token "$ghcr_repository") ||
        return "$LOOKUP_UNAVAILABLE"
    tag_encoded=$($JQ -rn --arg value "$tag" '$value | @uri')
    request_headers=$(mktemp)
    ghcr_write_request_headers "$request_headers" "$token"
    header_tmp=$(mktemp)
    if ! http_code=$(
        $CURL -sS -I -D "$header_tmp" -o /dev/null -w '%{http_code}' \
            -H "@$request_headers" \
            "https://ghcr.io/v2/$ghcr_repository/manifests/$tag_encoded"
    ); then
        rm -f "$request_headers" "$header_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
    if [[ "$http_code" == 404 ]]; then
        rm -f "$request_headers" "$header_tmp"
        return "$LOOKUP_NOT_FOUND"
    fi
    if [[ "$http_code" != 200 ]]; then
        debug "Anonymous GHCR tag lookup returned HTTP $http_code for $ghcr_repository:$tag"
        rm -f "$request_headers" "$header_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi

    manifest_digest=$(
        perl -ne 'if (/^docker-content-digest:\s*(\S+)/i) { print "$1\n"; exit }' "$header_tmp"
    )
    rm -f "$request_headers" "$header_tmp"
    [[ -n "$manifest_digest" ]] || return "$LOOKUP_UNAVAILABLE"
    printf '%s\n' "$manifest_digest"
}

# Honor the requested GHCR method while preferring the inexpensive public
# manifest check in auto mode. The Packages API fallback also supports private
# packages when gh has read:packages access.
function ghcr_digest_for_tag {
    local ghcr_repository="$1"
    local tag="$2"
    local manifest_digest package_version lookup_status

    if [[ "$opt_ghcr_method" != packages ]]; then
        if manifest_digest=$(ghcr_digest_for_tag_anonymously "$ghcr_repository" "$tag"); then
            printf '%s\n' "$manifest_digest"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
        if [[ "$lookup_status" == "$LOOKUP_NOT_FOUND" ||
                "$opt_ghcr_method" == anonymous ]]; then
            return "$lookup_status"
        fi
    fi

    if package_version=$(ghcr_package_version_by_tag "$ghcr_repository" "$tag"); then
        manifest_digest=$($JQ -r '.name // empty' <<<"$package_version")
        [[ -n "$manifest_digest" ]] || return "$LOOKUP_UNAVAILABLE"
        printf '%s\n' "$manifest_digest"
        return "$LOOKUP_SUCCEEDED"
    else
        lookup_status=$?
    fi

    if [[ "$lookup_status" == "$LOOKUP_UNAVAILABLE" &&
            "$opt_ghcr_method" == auto ]] &&
            manifest_digest=$(skopeo_digest_for_tag "ghcr.io/$ghcr_repository:$tag"); then
        notice "Resolved private GHCR tag with configured registry credentials"
        printf '%s\n' "$manifest_digest"
        return "$LOOKUP_SUCCEEDED"
    fi
    return "$lookup_status"
}

# Print current GHCR tags whose manifest has the requested digest. This uses
# only GHCR's anonymous OCI Registry API, but requires one request per tag. In
# "any" mode, skip registry_direct_tag and stop after the first other match.
function ghcr_tags_by_digest_anonymously {
    local ghcr_repository="$1"
    local digest="$2"
    local token request_headers
    local tags="" next_url next_link page_tags tag manifest_digest
    local header_tmp body_tmp checked=0 match_found
    local -a spinner=('|' '/' '-' $'\\')

    verbose "Requesting an anonymous GHCR pull token"
    token=$(ghcr_anonymous_pull_token "$ghcr_repository") || return 1
    request_headers=$(mktemp)
    ghcr_write_request_headers "$request_headers" "$token"

    header_tmp=$(mktemp)
    body_tmp=$(mktemp)
    next_url="https://ghcr.io/v2/$ghcr_repository/tags/list?n=100"
    while [[ -n "$next_url" ]]; do
        verbose "Listing GHCR tags from: $next_url"
        if ! $CURL -fsS -H "@$request_headers" \
                -D "$header_tmp" -o "$body_tmp" "$next_url"; then
            rm -f "$request_headers" "$header_tmp" "$body_tmp"
            return 1
        fi

        page_tags=$($JQ -r '.tags[]?' "$body_tmp")
        if [[ -n "$page_tags" ]]; then
            tags+="${tags:+$'\n'}$page_tags"
        fi

        next_link=$(
            perl -ne '
                if (/^Link:\s*(.*)/i) {
                    for (split /,\s*/, $1) {
                        if (/<([^>]+)>;\s*rel="next"/) {
                            print "$1\n";
                            exit;
                        }
                    }
                }
            ' "$header_tmp"
        )
        case "$next_link" in
        http://* | https://*) next_url="$next_link" ;;
        /*) next_url="https://ghcr.io$next_link" ;;
        *) next_url="" ;;
        esac
    done

    if is_interactive_session; then
        printf 'Searching GHCR tags anonymously... %s (0 checked)' "${spinner[0]}" >&2
    fi
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        if [[ "$registry_tag_scan" == any && "$tag" == "$registry_direct_tag" ]]; then
            continue
        fi
        match_found=
        verbose "Resolving GHCR tag: $tag"
        if $CURL -fsS -H "@$request_headers" \
                -D "$header_tmp" -o /dev/null \
                "https://ghcr.io/v2/$ghcr_repository/manifests/$tag" 2>/dev/null; then
            manifest_digest=$(
                perl -ne 'if (/^docker-content-digest:\s*(\S+)/i) { print "$1\n"; exit }' "$header_tmp"
            )
            if [[ "$manifest_digest" == "$digest" ]]; then
                printf '%s\n' "$tag"
                [[ "$registry_tag_scan" == any ]] && match_found=1
            fi
        fi
        ((++checked))
        if is_interactive_session; then
            printf '\rSearching GHCR tags anonymously... %s (%d checked)' \
                "${spinner[checked % 4]}" "$checked" >&2
        fi
        [[ -z "$match_found" ]] || break
    done <<<"$tags"
    if is_interactive_session; then
        printf '\rSearching GHCR tags anonymously... done (%d checked)\n' "$checked" >&2
    fi

    rm -f "$request_headers" "$header_tmp" "$body_tmp"
}

# Ask how to proceed when the Packages API cannot be used. The selected action
# is printed as "refresh", "anonymous", or "skip".
function choose_ghcr_fallback {
    local can_refresh="$1"
    local choice

    if ! is_interactive_session; then
        return 1
    fi

    echo "$SCRIPT_NAME: GitHub Packages API credentials with read:packages scope are unavailable." >&2
    if [[ -n "$can_refresh" ]]; then
        echo "  [r] Run 'gh auth refresh -s read:packages', then retry" >&2
        echo "  [a] Use the slower anonymous OCI tag scan" >&2
        echo "  [s] Skip GHCR lookup and exit" >&2
        while true; do
            printf "Choose [r/a/s]: " >&2
            IFS= read -r choice </dev/tty || return 1
            case "$choice" in
            r | R) printf 'refresh\n'; return 0 ;;
            a | A) printf 'anonymous\n'; return 0 ;;
            s | S) printf 'skip\n'; return 0 ;;
            esac
        done
    fi

    printf "The gh CLI is unavailable. [y] Use the slower anonymous OCI tag scan [s] Skip and exit. Choose [y/s]: " >&2
    IFS= read -r choice </dev/tty || return 1
    case "$choice" in
    y | Y | yes | YES | Yes) printf 'anonymous\n' ;;
    s | S) printf 'skip\n' ;;
    *) return 1 ;;
    esac
}

# Populate the shared registry result fields using the selected GHCR method.
function ghcr_tags_by_digest {
    local ghcr_repository="$1"
    local digest="$2"
    local display_repository="$3"
    local can_refresh ghcr_choice package_lookup_status

    debug "GHCR reverse lookup: repository=$ghcr_repository digest=$digest display=$display_repository method=$opt_ghcr_method scan=$registry_tag_scan"

    if [[ "$opt_ghcr_method" == anonymous ]]; then
        if ! registry_tags=$(ghcr_tags_by_digest_anonymously "$ghcr_repository" "$digest"); then
            abort "Anonymous GHCR lookup failed for $display_repository (is the package public?)"
        fi
        registry_lookup_backend=oci-registry-api
        return
    fi

    while true; do
        if registry_metadata=$(ghcr_package_version_by_digest "$ghcr_repository" "$digest"); then
            registry_lookup_backend=github-packages-api
            if [[ "$registry_tag_scan" == any ]]; then
                registry_tags=$(
                    $JQ -r --arg direct_tag "$registry_direct_tag" '
                        [
                            .metadata.container.tags[]?
                            | select(. != $direct_tag)
                        ][0] // empty
                    ' <<<"$registry_metadata"
                )
            else
                registry_tags=$($JQ -r '.metadata.container.tags[]?' <<<"$registry_metadata")
            fi
            break
        else
            package_lookup_status=$?
        fi
        case "$package_lookup_status" in
        "$LOOKUP_NOT_FOUND")
            debug "GHCR Packages API was reachable, but no active version matched $ghcr_repository@$digest"
            registry_lookup_result=not_found
            registry_lookup_backend=github-packages-api
            break
            ;;
        esac

        if [[ "$opt_ghcr_method" == auto ]]; then
            if skopeo_has_registry_credentials ghcr.io; then
                notice "Using configured registry credentials for private GHCR lookup."
                if ! registry_tags=$(skopeo_tags_by_digest "$display_repository" "$digest"); then
                    abort "Authenticated Skopeo lookup failed for $display_repository"
                fi
                registry_lookup_backend=skopeo
                break
            fi
        fi

        if [[ "$opt_ghcr_method" == packages ]]; then
            abort "GitHub Packages API lookup failed; authenticate gh with read:packages scope"
        fi

        if command -v "${GH:=gh}" &>/dev/null; then
            can_refresh=1
        else
            can_refresh=
        fi
        if ! ghcr_choice=$(choose_ghcr_fallback "$can_refresh"); then
            abort "GHCR lookup cancelled; no usable GitHub Packages credentials and anonymous scanning was not approved"
        fi

        case "$ghcr_choice" in
        refresh)
            if ! "$GH" auth refresh -s read:packages </dev/tty >/dev/tty; then
                warn "gh authentication refresh failed"
            fi
            # Retry the Packages API whether refresh succeeded or failed: the
            # authentication flow may still have updated the token.
            ;;
        anonymous)
            if ! registry_tags=$(ghcr_tags_by_digest_anonymously "$ghcr_repository" "$digest"); then
                abort "Anonymous GHCR lookup failed for $display_repository (is the package public?)"
            fi
            registry_lookup_backend=oci-registry-api
            break
            ;;
        skip)
            skip_input=1
            break
            ;;
        esac
    done
}

function ghcr_print_metadata {
    local package_current_tags

    case "$registry_lookup_result:$registry_lookup_backend" in
    completed:github-packages-api)
        package_current_tags=$(
            $JQ -r '
                .metadata.container.tags // []
                | if length == 0 then "none" else join(", ") end
            ' <<<"$registry_metadata"
        )
        echo
        echo "GHCR package info:"
        echo "Created: $($JQ -r '.created_at // "unknown"' <<<"$registry_metadata")"
        echo "Updated: $($JQ -r '.updated_at // "unknown"' <<<"$registry_metadata")"
        if [[ "$package_current_tags" == none ]]; then
            echo "Note: the digest is still an active GHCR package version, but no current tag points to it."
        fi
        ;;
    not_found:github-packages-api)
        warn "No active GHCR package version was found for $registry_digest"
        ;;
    completed:oci-registry-api)
        if [[ -z "$registry_tags" ]]; then
            warn "No current GHCR tag was found for $registry_digest"
        fi
        ;;
    esac
}
