# shellcheck shell=bash

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

    response_tmp=$(mktemp)
    if ! http_code=$(
        "$CURL" -sS -H 'Accept: application/json' -o "$response_tmp" \
            -w '%{http_code}' \
            "https://$registry/acr/v1/$repository/$endpoint?api-version=2021-07-01"
    ); then
        rm -f "$response_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
    error_message=$(
        "$JQ" -r '
            (.errors[0].message // .message // .error // empty)
            | if type == "string" then gsub("[\\r\\n]+"; " ") else tostring end
        ' "$response_tmp" 2>/dev/null || true
    )
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
    error_tmp=$(mktemp)
    if response=$("$AZ" "${azure_args[@]}" 2>"$error_tmp"); then
        rm -f "$error_tmp"
    else
        if grep -Eqi 'not found|manifest unknown|tag.*unknown' "$error_tmp"; then
            rm -f "$error_tmp"
            return "$LOOKUP_NOT_FOUND"
        fi
        debug "Azure CLI metadata lookup failed for $registry/$image_reference: $(tr '\n' ' ' <"$error_tmp")"
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

    if response=$(acr_metadata_anonymously \
            "$registry" "$repository" "$reference_kind" "$reference"); then
        printf '%s\n' "$response"
        return "$LOOKUP_SUCCEEDED"
    else
        lookup_status=$?
    fi
    case "$lookup_status" in
    "$LOOKUP_NOT_FOUND" | "$LOOKUP_UNAVAILABLE" | "$LOOKUP_STOPPED")
        return "$lookup_status"
        ;;
    esac
    acr_metadata_with_azure_cli \
        "$registry" "$repository" "$reference_kind" "$reference"
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
    skopeo_digest_for_tag_with_lazy_auth "$registry" "$image_reference" acr_authenticate
}

function acr_tags_by_digest_api {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local metadata returned_digest

    metadata=$(acr_metadata "$registry" "$repository" manifest "$digest") || return $?
    returned_digest=$(
        "$JQ" -r '.manifest.digest // .digest // empty' <<<"$metadata"
    )
    if [[ "$returned_digest" != "$digest" ]]; then
        debug "ACR returned digest '$returned_digest' for $registry/$repository@$digest"
        return "$LOOKUP_UNAVAILABLE"
    fi
    "$JQ" -r \
        --arg tag_scan "$registry_tag_scan" \
        --arg direct_tag "$registry_direct_tag" '
            [(.manifest.tags // .tags // [])[]?
                | select($tag_scan != "any" or . != $direct_tag)]
            | unique
            | if $tag_scan == "any" then .[0] // empty else .[] end
        ' <<<"$metadata"
}

function acr_tags_by_digest_with_skopeo {
    local registry="$1"
    local repository="$2"
    local digest="$3"

    skopeo_tags_by_digest_with_lazy_auth \
        "$registry" "$repository" "$digest" acr_authenticate
}
