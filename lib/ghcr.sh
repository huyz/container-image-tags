# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # standalone module lint: shared input/output fields

# GitHub Container Registry fast paths. Anonymous access uses the shared OCI
# implementation; this module contains only the GitHub Packages API behavior.

ghcr_package_page_match=
ghcr_package_page_next=
ghcr_package_page_last=
ghcr_package_page_elapsed_ms=
ghcr_package_probe_match=
ghcr_package_probe_complete=
ghcr_package_probe_endpoint_base=
ghcr_package_probe_next=
ghcr_package_probe_last=
ghcr_package_probe_elapsed_ms=

function ghcr_split_api_response {
    local response_file="$1"
    local header_file="$2"
    local body_file="$3"

    perl -0777 -e '
        my ($input, $headers, $body) = @ARGV;
        open my $in, "<", $input or exit 1;
        local $/;
        my $value = <$in> // "";
        close $in;
        my ($header_value, $body_value) = ("", $value);
        if ($value =~ /\A(HTTP\/\S+.*?\r?\n\r?\n)(.*)\z/s) {
            ($header_value, $body_value) = ($1, $2);
        }
        open my $hout, ">", $headers or exit 1;
        print {$hout} $header_value;
        close $hout;
        open my $bout, ">", $body or exit 1;
        print {$bout} $body_value;
        close $bout;
    ' "$response_file" "$header_file" "$body_file"
}

function ghcr_link_page {
    local header_file="$1"
    local relation="$2"

    perl -ne '
        BEGIN { $relation = shift @ARGV }
        if (/^Link:\s*(.*)/i) {
            for my $link (split /,\s*/, $1) {
                next unless $link =~ /<([^>]+)>;\s*rel="\Q$relation\E"/i;
                my $url = $1;
                if ($url =~ /[?&]page=(\d+)/) {
                    print "$1\n";
                    exit;
                }
            }
        }
    ' "$relation" "$header_file"
}

# Fetch and inspect exactly one Packages page. gh --include lets the caller use
# GitHub's pagination links without issuing a separate request. Test stubs and
# older gh wrappers that emit a bare JSON array remain supported.
function ghcr_package_version_page {
    local endpoint="$1"
    local selector="$2"
    local wanted="$3"
    local response_tmp header_tmp body_tmp error_tmp
    local started_ms finished_ms api_status gh_error

    ghcr_package_page_match=
    ghcr_package_page_next=
    ghcr_package_page_last=
    ghcr_package_page_elapsed_ms=
    response_tmp=$(runtime_temp_file ghcr-response)
    header_tmp=$(runtime_temp_file ghcr-headers)
    body_tmp=$(runtime_temp_file ghcr-body)
    error_tmp=$(runtime_temp_file ghcr-error)
    started_ms=$(registry_now_milliseconds)
    if "$GH" api --include "$endpoint" >"$response_tmp" 2>"$error_tmp"; then
        finished_ms=$(registry_now_milliseconds)
    else
        api_status=$?
        finished_ms=$(registry_now_milliseconds)
        gh_error=$(command_error_single_line "$error_tmp" 1000)
        [[ -n "$gh_error" ]] || gh_error="no stderr output"
        debug "GitHub Packages API request failed: endpoint=$endpoint status=$api_status error=$gh_error"
        rm -f "$response_tmp" "$header_tmp" "$body_tmp" "$error_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
    ghcr_package_page_elapsed_ms=$(( finished_ms - started_ms ))
    (( ghcr_package_page_elapsed_ms > 0 )) || ghcr_package_page_elapsed_ms=1
    ghcr_split_api_response "$response_tmp" "$header_tmp" "$body_tmp" || {
        rm -f "$response_tmp" "$header_tmp" "$body_tmp" "$error_tmp"
        return "$LOOKUP_UNAVAILABLE"
    }
    if ! "$JQ" -e 'type == "array"' "$body_tmp" >/dev/null 2>&1; then
        debug "GitHub Packages API returned an invalid page for $endpoint"
        rm -f "$response_tmp" "$header_tmp" "$body_tmp" "$error_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
    ghcr_package_page_next=$(ghcr_link_page "$header_tmp" next || true)
    ghcr_package_page_last=$(ghcr_link_page "$header_tmp" last || true)
    # shellcheck disable=SC2016  # jq expression, not a shell expansion
    ghcr_package_page_match=$(
        "$JQ" -c --arg selector "$selector" --arg wanted "$wanted" '
            first(
                .[]
                | select(
                    if $selector == "digest" then
                        .name == $wanted
                    else
                        (.metadata.container.tags // [] | index($wanted)) != null
                    end
                )
            ) // empty
        ' "$body_tmp"
    )
    rm -f "$response_tmp" "$header_tmp" "$body_tmp" "$error_tmp"
}

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
    local owner package_name package_encoded owner_kind endpoint match page
    local remaining_pages pagination_cost_checked
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
    # A GHCR namespace can belong to either an organization or a user. Try
    # both owner-specific Packages API endpoints.
    for owner_kind in orgs users; do
        page=1
        pagination_cost_checked=
        while true; do
            endpoint="/$owner_kind/$owner/packages/container/$package_encoded/versions?per_page=100&page=$page"
            verbose "Searching GitHub package versions for $owner_kind/$owner/$package_name (page $page)"
            if ghcr_package_version_page "$endpoint" "$selector" "$wanted"; then
                queried_api=1
            else
                break
            fi
            match="$ghcr_package_page_match"
            if [[ -n "$match" ]]; then
                printf '%s\n' "$match"
                return "$LOOKUP_SUCCEEDED"
            fi
            [[ -n "$ghcr_package_page_next" ]] || break
            if [[ -z "$pagination_cost_checked" &&
                    -n "$ghcr_package_page_last" ]]; then
                remaining_pages=$(( ghcr_package_page_last - page ))
                registry_expensive_work_preflight \
                    'GitHub Packages API' "$ghcr_repository" \
                    "may request up to $remaining_pages additional package-version pages" \
                    "$remaining_pages" 1 "$ghcr_package_page_elapsed_ms" || return $?
                pagination_cost_checked=1
            fi
            page="$ghcr_package_page_next"
        done
    done

    [[ -n "$queried_api" ]] && return "$LOOKUP_NOT_FOUND"
    return "$LOOKUP_UNAVAILABLE"
}

function ghcr_package_version_by_digest {
    ghcr_package_version "$1" digest "$2"
}

function ghcr_package_version_by_tag {
    ghcr_package_version "$1" tag "$2"
}

# Inspect the first page of the applicable organization or user endpoint. A
# successful probe may contain a match, prove an exhaustive one-page miss, or
# provide continuation state for adaptive backend selection.
function ghcr_probe_package_version_by_digest {
    local ghcr_repository="$1"
    local wanted="$2"
    local owner package_name package_encoded owner_kind endpoint
    local queried_api=

    ghcr_package_probe_match=
    ghcr_package_probe_complete=
    ghcr_package_probe_endpoint_base=
    ghcr_package_probe_next=
    ghcr_package_probe_last=
    ghcr_package_probe_elapsed_ms=
    owner="${ghcr_repository%%/*}"
    package_name="${ghcr_repository#*/}"
    [[ "$ghcr_repository" == */* && -n "$owner" && -n "$package_name" ]] ||
        return "$LOOKUP_UNAVAILABLE"
    command -v "${GH:=gh}" &>/dev/null || return "$LOOKUP_UNAVAILABLE"
    package_encoded=$("$JQ" -rn --arg value "$package_name" '$value | @uri')

    for owner_kind in orgs users; do
        ghcr_package_probe_endpoint_base="/$owner_kind/$owner/packages/container/$package_encoded/versions?per_page=100"
        endpoint="$ghcr_package_probe_endpoint_base&page=1"
        verbose "Probing GitHub package versions for $owner_kind/$owner/$package_name (page 1)"
        if ! ghcr_package_version_page "$endpoint" digest "$wanted"; then
            continue
        fi
        queried_api=1
        ghcr_package_probe_match="$ghcr_package_page_match"
        ghcr_package_probe_next="$ghcr_package_page_next"
        ghcr_package_probe_last="${ghcr_package_page_last:-$ghcr_package_page_next}"
        ghcr_package_probe_elapsed_ms="$ghcr_package_page_elapsed_ms"
        [[ -z "$ghcr_package_probe_match" ]] || return "$LOOKUP_SUCCEEDED"
        [[ -z "$ghcr_package_probe_next" ]] || return "$LOOKUP_SUCCEEDED"
    done

    [[ -n "$queried_api" ]] || return "$LOOKUP_UNAVAILABLE"
    ghcr_package_probe_complete=1
}

function ghcr_continue_package_version_by_digest {
    local wanted="$1"
    local page="$ghcr_package_probe_next"
    local endpoint

    while [[ -n "$page" ]]; do
        endpoint="$ghcr_package_probe_endpoint_base&page=$page"
        verbose "Searching GitHub package versions (page $page)"
        ghcr_package_version_page "$endpoint" digest "$wanted" ||
            return "$LOOKUP_UNAVAILABLE"
        if [[ -n "$ghcr_package_page_match" ]]; then
            printf '%s\n' "$ghcr_package_page_match"
            return "$LOOKUP_SUCCEEDED"
        fi
        page="$ghcr_package_page_next"
    done
    return "$LOOKUP_NOT_FOUND"
}

function ghcr_use_package_metadata {
    local metadata="$1"
    local package_tags

    registry_metadata="$metadata"
    registry_lookup_backend=github-packages-api
    package_tags=$("$JQ" -r '.metadata.container.tags[]?' <<<"$registry_metadata")
    registry_tags=$(select_matching_tags_for_scan \
        "$package_tags" "$package_tags" || true)
}

# On the default if-faster policy, do useful work on both observable backends
# before committing to a long scan. The first Packages page is searched first;
# only an unresolved multi-page history causes a complete (cheap) OCI tag-list
# probe and a remaining-cost comparison.
function ghcr_tags_by_digest_adaptively {
    local ghcr_repository="$1"
    local digest="$2"
    local display_repository="$3"
    local package_status oci_status package_metadata
    local remaining_package_pages package_estimated_ms
    local tag_count=0 parallel_jobs oci_estimated_ms tag

    if ghcr_probe_package_version_by_digest "$ghcr_repository" "$digest"; then
        :
    else
        return $?
    fi
    if [[ -n "$ghcr_package_probe_match" ]]; then
        ghcr_use_package_metadata "$ghcr_package_probe_match"
        return "$LOOKUP_SUCCEEDED"
    fi
    [[ -z "$ghcr_package_probe_complete" ]] || return "$LOOKUP_NOT_FOUND"

    remaining_package_pages=$(( ${ghcr_package_probe_last:-2} - 1 ))
    (( remaining_package_pages > 0 )) || remaining_package_pages=1
    package_estimated_ms=$(( remaining_package_pages * ${ghcr_package_probe_elapsed_ms:-1000} ))

    if oci_list_tags_anonymously \
            ghcr.io "$ghcr_repository" inventory "$package_estimated_ms"; then
        while IFS= read -r tag; do
            [[ -n "$tag" ]] && ((++tag_count))
        done <<<"$oci_listed_tags"
        if [[ -n "$oci_direct_tag_durable" ]]; then
            registry_tags="$registry_direct_tag"
            registry_lookup_backend=oci-registry-api
            return "$LOOKUP_SUCCEEDED"
        fi
    else
        oci_status=$?
        debug "GHCR OCI inventory could not complete for $display_repository: status=$oci_status; retaining the Packages continuation"
        tag_count=0
    fi

    parallel_jobs=$OCI_MAX_PARALLEL_JOBS
    (( tag_count < parallel_jobs )) && parallel_jobs=$tag_count
    (( parallel_jobs > 0 )) || parallel_jobs=1
    oci_estimated_ms=$(registry_estimated_milliseconds \
        "$tag_count" "$parallel_jobs" "$(( OCI_ESTIMATED_SECONDS_PER_BATCH * 1000 ))")
    debug "GHCR adaptive estimate: repository=$display_repository package_remaining_pages=$remaining_package_pages package_ms=$package_estimated_ms oci_tags=$tag_count oci_ms=$oci_estimated_ms"

    if (( tag_count > 0 && oci_estimated_ms <= package_estimated_ms )); then
        notice "Selecting the anonymous OCI scan for $display_repository after comparing the measured Packages page cost with $tag_count current registry tags."
        registry_lookup_backend=oci-registry-api
        if registry_tags=$(oci_tags_by_digest_from_list \
                ghcr.io "$ghcr_repository" "$digest"); then
            return "$LOOKUP_SUCCEEDED"
        else
            return $?
        fi
    fi

    registry_expensive_work_preflight \
        'GitHub Packages API' "$display_repository" \
        "may request up to $remaining_package_pages additional package-version pages" \
        "$remaining_package_pages" 1 "${ghcr_package_probe_elapsed_ms:-1000}" || return $?
    if package_metadata=$(ghcr_continue_package_version_by_digest "$digest"); then
        ghcr_use_package_metadata "$package_metadata"
        return "$LOOKUP_SUCCEEDED"
    else
        package_status=$?
    fi
    return "$package_status"
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
        (( lookup_status == LOOKUP_STOPPED )) && return "$LOOKUP_STOPPED"
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
        if [[ "${opt_credential_policy:-if-faster}" == if-faster ]]; then
            if ghcr_tags_by_digest_adaptively \
                    "$ghcr_repository" "$digest" "$display_repository"; then
                break
            else
                package_lookup_status=$?
            fi
        else
            if registry_metadata=$(ghcr_package_version_by_digest "$ghcr_repository" "$digest"); then
                registry_lookup_backend=github-packages-api
                package_tags=$($JQ -r '.metadata.container.tags[]?' <<<"$registry_metadata")
                registry_tags=$(select_matching_tags_for_scan \
                    "$package_tags" "$package_tags" || true)
                break
            else
                package_lookup_status=$?
            fi
        fi
        case "$package_lookup_status" in
        "$LOOKUP_NOT_FOUND")
            debug "GHCR Packages API was reachable, but no active version matched $ghcr_repository@$digest"
            registry_lookup_result=not_found
            registry_lookup_backend=github-packages-api
            break
            ;;
        "$LOOKUP_STOPPED")
            abort "GHCR lookup stopped for $display_repository"
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
