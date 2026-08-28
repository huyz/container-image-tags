# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # standalone module lint: shared input/output fields

# Azure Container Registry support. Public access stays anonymous; private
# access obtains a short-lived Azure CLI token only after an auth challenge.

function acr_registry_name {
    local registry="$1"
    local registry_label="${registry%%.*}"

    printf '%s\n' "${registry_label%%-*}"
}

function acr_registry_suffix {
    local registry="$1"
    local registry_label="${registry%%.*}"

    [[ "$registry_label" == *-* ]] || return 1
    printf '%s\n' "${registry_label#*-}"
}

# Query one documented ACR artifact-metadata endpoint without credentials.
# Return LOOKUP_SUCCEEDED with the response body, LOOKUP_NOT_FOUND when absent,
# LOOKUP_UNAVAILABLE for an unusable response, LOOKUP_DENIED for access denial,
# and LOOKUP_STOPPED for rate limiting.
function acr_metadata_anonymously {
    local registry="$1"
    local repository="$2"
    local reference_kind="$3"
    local reference="$4"
    local endpoint response_tmp http_code error_message

    case "$reference_kind" in
    manifest) endpoint="_manifests/$reference" ;;
    tag) endpoint="_tags/$reference" ;;
    *) return "$LOOKUP_UNAVAILABLE" ;;
    esac

    response_tmp=$(runtime_temp_file acr-response)
    if ! http_code=$(registry_http_request GET \
            "https://$registry/acr/v1/$repository/$endpoint?api-version=2021-07-01" \
            "$response_tmp" '' -H 'Accept: application/json'); then
        rm -f "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
    error_message=$(registry_json_error_message "$response_tmp")
    case "$http_code" in
    200)
        cat "$response_tmp"
        rm -f "$response_tmp"
        ;;
    401 | 403)
        debug "Anonymous ACR metadata lookup was denied for $registry/$repository (HTTP $http_code)${error_message:+: $error_message}"
        rm -f "$response_tmp"
        return "$LOOKUP_DENIED"
        ;;
    404)
        rm -f "$response_tmp"
        return "$LOOKUP_NOT_FOUND"
        ;;
    429)
        warn "ACR rate limit reached for $registry/$repository (HTTP 429)${error_message:+: $error_message}"
        rm -f "$response_tmp"
        return "$LOOKUP_STOPPED"
        ;;
    *)
        debug "ACR metadata lookup failed for $registry/$repository (HTTP $http_code)${error_message:+: $error_message}"
        rm -f "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
        ;;
    esac
}

# Let Azure CLI perform the authenticated data-plane exchange after an
# anonymous denial. `az acr manifest show-metadata` uses the same manifest
# properties API while avoiding long-lived credentials and Docker state.
function acr_metadata_with_azure_cli {
    local registry="$1"
    local repository="$2"
    local reference_kind="$3"
    local reference="$4"
    local registry_name registry_suffix image_reference response error_tmp
    local -a azure_args

    command -v "${AZ:=az}" &>/dev/null || return "$LOOKUP_UNAVAILABLE"
    registry_name=$(acr_registry_name "$registry")
    registry_suffix=$(acr_registry_suffix "$registry" || true)
    case "$reference_kind" in
    manifest) image_reference="$repository@$reference" ;;
    tag) image_reference="$repository:$reference" ;;
    *) return "$LOOKUP_UNAVAILABLE" ;;
    esac
    azure_args=(acr manifest show-metadata --registry "$registry_name"
        --name "$image_reference" --output json --only-show-errors)
    [[ -z "$registry_suffix" ]] || azure_args+=(--suffix "$registry_suffix")

    notice "ACR requires authentication; requesting artifact metadata through Azure CLI."
    error_tmp=$(runtime_temp_file acr-error)
    if response=$("$AZ" "${azure_args[@]}" 2>"$error_tmp"); then
        rm -f "$error_tmp"
    else
        if grep -Eqi 'not found|manifest unknown|tag.*unknown' "$error_tmp"; then
            rm -f "$error_tmp"
            return "$LOOKUP_NOT_FOUND"
        fi
        debug "Azure CLI metadata lookup failed for $registry/$image_reference: $(command_error_single_line "$error_tmp")"
        rm -f "$error_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
    printf '%s\n' "$response"
}

function acr_metadata {
    local registry="$1"
    local repository="$2"
    local reference_kind="$3"
    local reference="$4"
    local response lookup_status

    if credential_policy_allows_public; then
        if response=$(acr_metadata_anonymously \
                "$registry" "$repository" "$reference_kind" "$reference"); then
            printf '%s\n' "$response"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
    else
        lookup_status=$LOOKUP_DENIED
    fi
    case "$lookup_status" in
    "$LOOKUP_NOT_FOUND" | "$LOOKUP_UNAVAILABLE" | "$LOOKUP_STOPPED")
        return "$lookup_status"
        ;;
    esac
    if credential_policy_allows_auth_after "$lookup_status"; then
        acr_metadata_with_azure_cli \
            "$registry" "$repository" "$reference_kind" "$reference"
    else
        return "$lookup_status"
    fi
}

function acr_authenticate {
    local registry="$1"
    local registry_name registry_suffix
    local -a azure_login_args

    command -v "${AZ:=az}" &>/dev/null || {
        warn "Install Azure CLI and run 'az login' to access private ACR registry '$registry'"
        return 1
    }

    registry_name=$(acr_registry_name "$registry")
    registry_suffix=$(acr_registry_suffix "$registry" || true)
    azure_login_args=(acr login --name "$registry_name" --expose-token
        --output tsv --query accessToken --only-show-errors)

    [[ -z "$registry_suffix" ]] || azure_login_args+=(--suffix "$registry_suffix")

    notice "ACR requires authentication; requesting a short-lived token from Azure CLI."
    if ! "$AZ" "${azure_login_args[@]}" |
            "$SKOPEO" login --authfile "$skopeo_session_authfile" \
                --username 00000000-0000-0000-0000-000000000000 \
                --password-stdin "$registry" >/dev/null; then
        warn "Azure CLI authentication failed for ACR registry '$registry'"
        return 1
    fi
}

function acr_digest_for_tag {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local image_reference="$4"
    local metadata digest lookup_status

    if metadata=$(acr_metadata "$registry" "$repository" tag "$tag"); then
        digest=$(
            "$JQ" -r --arg tag "$tag" '
                if .tag? then
                    .tag | select(.name == $tag) | .digest
                else
                    .digest // empty
                end
            ' <<<"$metadata"
        )
        [[ -n "$digest" && "$digest" != *$'\n'* ]] ||
            return "$LOOKUP_UNAVAILABLE"
        printf '%s\n' "$digest"
        return "$LOOKUP_SUCCEEDED"
    else
        lookup_status=$?
    fi
    (( lookup_status == LOOKUP_NOT_FOUND )) && return "$LOOKUP_NOT_FOUND"
    (( lookup_status == LOOKUP_STOPPED )) && return "$LOOKUP_STOPPED"
    notice "ACR metadata lookup is unavailable for $registry/$repository:$tag; falling back to Skopeo"

    skopeo_is_available || return "$LOOKUP_UNAVAILABLE"
    skopeo_digest_for_tag_with_access_policy \
        "$registry" "$image_reference" acr_authenticate "$lookup_status"
}

function acr_resolve_tag {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local display_reference="$4"

    if remote_tag_digest=$(acr_digest_for_tag \
            "$registry" "$repository" "$tag" "$display_reference"); then
        remote_tag_status=$LOOKUP_SUCCEEDED
    else
        remote_tag_status=$?
    fi
}

function acr_tags_by_digest_api {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local metadata returned_digest matching_tags

    metadata=$(acr_metadata "$registry" "$repository" manifest "$digest") || return $?
    returned_digest=$(
        "$JQ" -r '.manifest.digest // .digest // empty' <<<"$metadata"
    )
    if [[ "$returned_digest" != "$digest" ]]; then
        debug "ACR returned digest '$returned_digest' for $registry/$repository@$digest"
        return "$LOOKUP_UNAVAILABLE"
    fi
    matching_tags=$("$JQ" -r \
        '[(.manifest.tags // .tags // [])[]?] | unique | .[]' <<<"$metadata")
    select_matching_tags_for_scan "$matching_tags" "$matching_tags" || true
}

function acr_tags_by_digest_with_skopeo {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local prior_status="${4-}"

    skopeo_tags_by_digest_with_access_policy \
        "$registry" "$repository" "$digest" acr_authenticate "$prior_status"
}

function acr_find_tags {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local display_repository="$4"
    local lookup_status

    registry_lookup_backend=acr-api
    if registry_tags=$(acr_tags_by_digest_api "$registry" "$repository" "$digest"); then
        return
    else
        lookup_status=$?
    fi
    case "$lookup_status" in
    "$LOOKUP_NOT_FOUND") registry_lookup_result=not_found ;;
    "$LOOKUP_STOPPED") abort "ACR API lookup stopped for $display_repository" ;;
    *)
        notice "ACR metadata lookup is unavailable for $display_repository; falling back to Skopeo"
        registry_lookup_backend=skopeo
        skopeo_is_available || abort "Install skopeo to query registry '$registry'"
        registry_tags=$(acr_tags_by_digest_with_skopeo \
            "$registry" "$display_repository" "$digest" "$lookup_status") ||
            abort "ACR lookup failed for $display_repository"
        ;;
    esac
}
