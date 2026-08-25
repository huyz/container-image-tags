# shellcheck shell=bash

# Azure Container Registry support. Public access stays anonymous; private
# access obtains a short-lived Azure CLI token only after an auth challenge.

function acr_authenticate {
    local registry="$1"
    local registry_label registry_name registry_suffix
    local -a azure_login_args

    command -v "${AZ:=az}" &>/dev/null || {
        warn "Install Azure CLI and run 'az login' to access private ACR registry '$registry'"
        return 1
    }

    registry_label="${registry%%.*}"
    registry_name="${registry_label%%-*}"
    azure_login_args=(acr login --name "$registry_name" --expose-token
        --output tsv --query accessToken --only-show-errors)

    # ACR resource names cannot contain hyphens. A hyphen in the login-server
    # label introduces Azure's domain-name-label suffix.
    if [[ "$registry_label" == *-* ]]; then
        registry_suffix="${registry_label#*-}"
        azure_login_args+=(--suffix "$registry_suffix")
    fi

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
    local image_reference="$2"

    skopeo_digest_for_tag_with_lazy_auth "$registry" "$image_reference" acr_authenticate
}

function acr_tags_by_digest {
    local registry="$1"
    local repository="$2"
    local digest="$3"

    skopeo_tags_by_digest_with_lazy_auth \
        "$registry" "$repository" "$digest" acr_authenticate
}
