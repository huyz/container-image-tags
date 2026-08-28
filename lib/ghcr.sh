# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # standalone module lint: shared input/output fields

# GitHub Container Registry fast paths. Anonymous access uses the shared OCI
# implementation; this module contains only the GitHub Packages API behavior.

# Look up an active GHCR package version by content digest or current tag.
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
    response_tmp=$(runtime_temp_file ghcr-response)
    error_tmp=$(runtime_temp_file ghcr-error)

    # A GHCR namespace can belong to either an organization or a user. Try
    # both owner-specific Packages API endpoints.
    for owner_kind in orgs users; do
        endpoint="/$owner_kind/$owner/packages/container/$package_encoded/versions?per_page=100"
        verbose "Searching GitHub package versions for $owner_kind/$owner/$package_name"
        if "$GH" api --paginate "$endpoint" >"$response_tmp" 2>"$error_tmp"; then
            queried_api=1
        else
            api_status=$?
            gh_error=$(command_error_single_line "$error_tmp" 1000)
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

# Keep the terminal attachment in one helper so both direct and reverse
# recovery use the same interactive gh authentication flow.
function ghcr_refresh_authentication {
    "$GH" auth refresh -s read:packages </dev/tty >/dev/tty
}

# Prefer the inexpensive public manifest check for direct lookups. The Packages
# API supports private packages after an explicit denial, while Skopeo remains
# the compatibility fallback selected by the registry-wide credential policy.
function ghcr_digest_for_tag {
    local ghcr_repository="$1"
    local tag="$2"
    local manifest_digest package_version lookup_status auth_trigger_status
    local can_refresh

    if credential_policy_allows_public; then
        if manifest_digest=$(oci_digest_for_tag_anonymously \
                ghcr.io "$ghcr_repository" "$tag"); then
            printf '%s\n' "$manifest_digest"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
        if [[ "$lookup_status" == "$LOOKUP_NOT_FOUND" ||
                "$lookup_status" == "$LOOKUP_STOPPED" ]]; then
            return "$lookup_status"
        fi
    else
        lookup_status=$LOOKUP_DENIED
    fi

    auth_trigger_status=$lookup_status
    if [[ "${opt_credential_policy:-if-faster}" == require ]] ||
            credential_policy_allows_auth_after "$lookup_status"; then
        if package_version=$(ghcr_package_version_by_tag "$ghcr_repository" "$tag"); then
            manifest_digest=$($JQ -r '.name // empty' <<<"$package_version")
            [[ -n "$manifest_digest" ]] || return "$LOOKUP_UNAVAILABLE"
            printf '%s\n' "$manifest_digest"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
    fi

    if skopeo_is_available; then
        if manifest_digest=$(skopeo_digest_for_tag_with_access_policy \
                ghcr.io "ghcr.io/$ghcr_repository:$tag" '' \
                "$auth_trigger_status"); then
            notice "Resolved GHCR tag with the Skopeo fallback"
            printf '%s\n' "$manifest_digest"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
    fi

    # Existing gh and registry credentials are automatic. If public access was
    # explicitly denied and neither credentialed path worked, an interactive
    # caller can grant gh the missing Packages scope and retry this exact tag.
    if (( auth_trigger_status == LOOKUP_DENIED )) &&
            (( lookup_status != LOOKUP_NOT_FOUND &&
                lookup_status != LOOKUP_STOPPED )) &&
            credential_policy_allows_credentials; then
        if command -v "${GH:=gh}" &>/dev/null; then
            can_refresh=1
        else
            can_refresh=
        fi
        if choose_ghcr_direct_authentication "$can_refresh"; then
            if ! ghcr_refresh_authentication; then
                warn "gh authentication refresh failed"
            fi
            if package_version=$(ghcr_package_version_by_tag \
                    "$ghcr_repository" "$tag"); then
                manifest_digest=$($JQ -r '.name // empty' <<<"$package_version")
                [[ -n "$manifest_digest" ]] || return "$LOOKUP_UNAVAILABLE"
                printf '%s\n' "$manifest_digest"
                return "$LOOKUP_SUCCEEDED"
            else
                lookup_status=$?
            fi
        fi
    fi
    return "$lookup_status"
}

function ghcr_resolve_tag {
    local ghcr_repository="$1"
    local tag="$2"

    if remote_tag_digest=$(ghcr_digest_for_tag "$ghcr_repository" "$tag"); then
        remote_tag_status=$LOOKUP_SUCCEEDED
    else
        remote_tag_status=$?
    fi
}

# Offer the one interactive action that can make an existing gh installation
# usable for a denied direct lookup. Declining leaves the original denial
# intact; there is no useful anonymous fallback for a private package.
function choose_ghcr_direct_authentication {
    local can_refresh="$1"
    local choice

    if ! is_interactive_session || [[ -z "$can_refresh" ]]; then
        return 1
    fi
    echo "$SCRIPT_NAME: GHCR denied the direct tag lookup and existing credentials were not usable." >&2
    echo "  [r] Run 'gh auth refresh -s read:packages', then retry" >&2
    echo "  [s] Stop without refreshing authentication" >&2
    while true; do
        printf 'Choose [r/s]: ' >&2
        IFS= read -r choice </dev/tty || return 1
        case "$choice" in
        r | R) return ;;
        s | S) return 1 ;;
        esac
    done
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

# Populate the shared registry result fields using the credential policy.
function ghcr_tags_by_digest {
    local ghcr_repository="$1"
    local digest="$2"
    local display_repository="$3"
    local can_refresh ghcr_choice package_lookup_status package_tags

    debug "GHCR reverse lookup: repository=$ghcr_repository digest=$digest display=$display_repository credential_policy=${opt_credential_policy:-if-faster} scan=$registry_tag_scan"

    if [[ "$registry_tag_scan" == any-durable &&
            -n "${registry_direct_tag_confirmed-}" &&
            -n "$registry_direct_tag" ]] &&
            credential_policy_allows_public &&
            oci_list_tags_anonymously ghcr.io "$ghcr_repository" sample &&
            [[ -n "$oci_direct_tag_durable" ]]; then
        registry_tags="$registry_direct_tag"
        registry_lookup_backend=oci-registry-api
        return
    fi

    if [[ "${opt_credential_policy:-if-faster}" == never ]]; then
        if ! registry_tags=$(oci_tags_by_digest_anonymously \
                ghcr.io "$ghcr_repository" "$digest"); then
            abort "Anonymous GHCR lookup failed for $display_repository (is the package public?)"
        fi
        registry_lookup_backend=oci-registry-api
        return
    fi

    if [[ "${opt_credential_policy:-if-faster}" == if-required ]]; then
        if registry_tags=$(oci_tags_by_digest_anonymously \
                ghcr.io "$ghcr_repository" "$digest"); then
            registry_lookup_backend=oci-registry-api
            return
        else
            package_lookup_status=$?
        fi
        case "$package_lookup_status" in
        "$LOOKUP_NOT_FOUND") registry_lookup_result=not_found; registry_lookup_backend=oci-registry-api; return ;;
        "$LOOKUP_STOPPED") abort "GHCR OCI lookup stopped for $display_repository" ;;
        "$LOOKUP_UNAVAILABLE")
            registry_lookup_backend=skopeo
            if registry_tags=$(skopeo_tags_by_digest_with_access_policy \
                    ghcr.io "$display_repository" "$digest" '' \
                    "$package_lookup_status"); then
                return
            else
                package_lookup_status=$?
            fi
            (( package_lookup_status == LOOKUP_DENIED )) ||
                abort "Public GHCR lookup failed for $display_repository"
            ;;
        esac
    fi

    while true; do
        if registry_metadata=$(ghcr_package_version_by_digest "$ghcr_repository" "$digest"); then
            registry_lookup_backend=github-packages-api
            package_tags=$($JQ -r '.metadata.container.tags[]?' <<<"$registry_metadata")
            registry_tags=$(select_matching_tags_for_scan \
                "$package_tags" "$package_tags" || true)
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

        if [[ "${opt_credential_policy:-if-faster}" == if-required ]]; then
            if skopeo_is_available &&
                    registry_tags=$(skopeo_tags_by_digest_with_access_policy \
                        ghcr.io "$display_repository" "$digest" '' \
                        "$LOOKUP_DENIED"); then
                registry_lookup_backend=skopeo
                break
            fi
        else
            if credential_policy_allows_public; then
                if registry_tags=$(oci_tags_by_digest_anonymously \
                        ghcr.io "$ghcr_repository" "$digest"); then
                    registry_lookup_backend=oci-registry-api
                    break
                else
                    package_lookup_status=$?
                fi
                case "$package_lookup_status" in
                "$LOOKUP_NOT_FOUND") registry_lookup_result=not_found; registry_lookup_backend=oci-registry-api; break ;;
                "$LOOKUP_STOPPED") abort "GHCR OCI lookup stopped for $display_repository" ;;
                esac
            else
                package_lookup_status=$LOOKUP_DENIED
            fi

            if skopeo_is_available &&
                    registry_tags=$(skopeo_tags_by_digest_with_access_policy \
                        ghcr.io "$display_repository" "$digest" '' \
                        "$package_lookup_status"); then
                registry_lookup_backend=skopeo
                break
            fi
        fi

        if [[ "${opt_credential_policy:-if-faster}" == require ]]; then
            abort "Credentialed GHCR lookup failed; configure gh or registry credentials"
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
            if ! ghcr_refresh_authentication; then
                warn "gh authentication refresh failed"
            fi
            # Retry the Packages API whether refresh succeeded or failed: the
            # authentication flow may still have updated the token.
            ;;
        anonymous)
            if ! registry_tags=$(oci_tags_by_digest_anonymously \
                    ghcr.io "$ghcr_repository" "$digest"); then
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

function ghcr_find_tags {
    ghcr_tags_by_digest "$@"
}

function ghcr_print_metadata {
    local result_name="${1-}"
    local lookup_result="$registry_lookup_result"
    local lookup_backend="$registry_lookup_backend"
    local metadata="$registry_metadata"
    local digest="$registry_digest"
    local tags="$registry_tags"
    local package_current_tags

    if [[ -n "$result_name" ]]; then
        local -n result_ref="$result_name"
        lookup_result="${result_ref[scan_status]}"
        lookup_backend="${result_ref[scan_backend]}"
        metadata="${result_ref[provider_metadata]}"
        digest="${result_ref[digest]}"
        tags="${result_ref[tags]}"
    fi

    case "$lookup_result:$lookup_backend" in
    completed:github-packages-api)
        package_current_tags=$(
            $JQ -r '
                .metadata.container.tags // []
                | if length == 0 then "none" else join(", ") end
            ' <<<"$metadata"
        )
        echo
        echo "GHCR package info:"
        echo "Created: $($JQ -r '.created_at // "unknown"' <<<"$metadata")"
        echo "Updated: $($JQ -r '.updated_at // "unknown"' <<<"$metadata")"
        if [[ "$package_current_tags" == none ]]; then
            echo "Note: the digest is still an active GHCR package version, but no current tag points to it."
        fi
        ;;
    not_found:github-packages-api)
        warn "No active GHCR package version was found for $digest"
        ;;
    completed:oci-registry-api)
        if [[ -z "$tags" ]]; then
            warn "No current GHCR tag was found for $digest"
        fi
        ;;
    esac
}
