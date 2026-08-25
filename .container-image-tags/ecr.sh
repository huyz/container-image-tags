# shellcheck shell=bash

# Amazon Elastic Container Registry support. The initial OCI request is
# anonymous; AWS CLI credentials are consulted only after an auth challenge.

function ecr_region_from_registry {
    local registry="$1"

    if [[ "$registry" =~ \.dkr\.ecr(-fips)?\.([^.]+)\.amazonaws\.com(\.cn)?$ ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
    elif [[ "$registry" =~ \.dkr-ecr(-fips)?\.([^.]+)\.on\.aws$ ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
    else
        return 1
    fi
}

function ecr_authenticate {
    local registry="$1"
    local region

    command -v "${AWS:=aws}" &>/dev/null || {
        warn "Install and configure AWS CLI to authenticate to ECR registry '$registry'"
        return 1
    }

    if [[ "$registry" == public.ecr.aws ]]; then
        notice "ECR Public requires authentication for this request; requesting a short-lived token from AWS CLI."
        if ! "$AWS" ecr-public get-login-password --region us-east-1 --no-cli-pager |
                "$SKOPEO" login --authfile "$skopeo_session_authfile" \
                    --username AWS --password-stdin public.ecr.aws >/dev/null; then
            warn "AWS CLI authentication failed for Amazon ECR Public"
            return 1
        fi
        return
    fi

    region=$(ecr_region_from_registry "$registry") || {
        warn "Cannot determine the AWS Region from ECR registry '$registry'"
        return 1
    }
    notice "ECR requires authentication; requesting a short-lived token from AWS CLI."
    if ! "$AWS" ecr get-login-password --region "$region" --no-cli-pager |
            "$SKOPEO" login --authfile "$skopeo_session_authfile" \
                --username AWS --password-stdin "$registry" >/dev/null; then
        warn "AWS CLI authentication failed for ECR registry '$registry'"
        return 1
    fi
}

function ecr_digest_for_tag {
    local registry="$1"
    local image_reference="$2"

    skopeo_digest_for_tag_with_lazy_auth "$registry" "$image_reference" ecr_authenticate
}

function ecr_tags_by_digest {
    local registry="$1"
    local repository="$2"
    local digest="$3"

    skopeo_tags_by_digest_with_lazy_auth \
        "$registry" "$repository" "$digest" ecr_authenticate
}
