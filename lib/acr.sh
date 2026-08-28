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

function acr_digest_from_tag_metadata {
    local metadata="$1"
    local tag="$2"
    local digest

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
}

function acr_tags_from_manifest_metadata {
    local metadata="$1"
    local digest="$2"
    local returned_digest matching_tags

    returned_digest=$(
        "$JQ" -r '.manifest.digest // .digest // empty' <<<"$metadata"
    )
    [[ "$returned_digest" == "$digest" ]] || return "$LOOKUP_UNAVAILABLE"
    matching_tags=$("$JQ" -r \
        '[(.manifest.tags // .tags // [])[]?] | unique | .[]' <<<"$metadata")
    select_matching_tags_for_scan "$matching_tags" "$matching_tags" || true
}

function acr_policy_attempt_metadata {
    local request_name="$1"
    local result_name="$2"
    local metadata_function="$3"
    local -n request_ref="$request_name"
    local -n result_ref="$result_name"
    local metadata output status reference_kind reference

    if [[ "${request_ref[operation]}" == direct ]]; then
        reference_kind=tag
        reference="${request_ref[tag]}"
    else
        reference_kind=manifest
        reference="${request_ref[digest]}"
    fi
    if metadata=$("$metadata_function" \
            "${request_ref[registry]}" "${request_ref[repository]}" \
            "$reference_kind" "$reference"); then
        :
    else
        return $?
    fi
    if [[ "${request_ref[operation]}" == direct ]]; then
        if output=$(acr_digest_from_tag_metadata "$metadata" "$reference"); then
            result_ref[digest]="$output"
            return "$LOOKUP_SUCCEEDED"
        else
            return $?
        fi
    fi
    if output=$(acr_tags_from_manifest_metadata \
            "$metadata" "${request_ref[digest]}"); then
        result_ref[tags]="$output"
        return "$LOOKUP_SUCCEEDED"
    else
        status=$?
    fi
    return "$status"
}

function acr_policy_attempt_public {
    acr_policy_attempt_metadata "$1" "$2" acr_metadata_anonymously
}

function acr_policy_attempt_azure {
    acr_policy_attempt_metadata "$1" "$2" acr_metadata_with_azure_cli
}

function acr_register_policy_attempts {
    local request_name="$1"
    local -n request_ref="$request_name"

    request_ref[provider_auth_callback]=acr_authenticate
    policy_add_attempt acr-public acr_policy_attempt_public \
        acr-api "$POLICY_ACCESS_PUBLIC" 10
    policy_add_attempt acr-azure acr_policy_attempt_azure \
        acr-api "$POLICY_ACCESS_CREDENTIAL" 20
    skopeo_register_policy_attempts "$request_name" acr 70
}
