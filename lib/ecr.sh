# shellcheck shell=bash

# Amazon Elastic Container Registry support. Private registries first use the
# signed metadata API; registry credentials and ECR Public access retain the
# anonymous-first Skopeo path with cloud authentication only after a challenge.

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

function ecr_account_from_registry {
    local registry="$1"
    local account="${registry%%.*}"

    [[ "$account" =~ ^[0-9]{12}$ ]] || return 1
    printf '%s\n' "$account"
}

# Query the signed ECR service API for one private-registry image identifier.
# Unlike the OCI registry API, DescribeImages returns every current tag for a
# digest in the same response. Return 0 with validated JSON, 1 when the image
# is absent, and 2 when the API is unavailable so callers can use Skopeo.
function ecr_private_image_details {
    local registry="$1"
    local repository="$2"
    local image_id="$3"
    local account region response error_tmp error_message

    [[ "$registry" != public.ecr.aws ]] || return 2
    command -v "${AWS:=aws}" &>/dev/null || return 2
    account=$(ecr_account_from_registry "$registry") || return 2
    region=$(ecr_region_from_registry "$registry") || return 2

    error_tmp=$(mktemp)
    if response=$(
        "$AWS" ecr describe-images \
            --registry-id "$account" \
            --repository-name "$repository" \
            --image-ids "$image_id" \
            --region "$region" \
            --no-cli-pager \
            --output json 2>"$error_tmp"
    ); then
        rm -f "$error_tmp"
    else
        if grep -q 'ImageNotFoundException' "$error_tmp"; then
            rm -f "$error_tmp"
            return 1
        fi
        error_message=$(tr '\n' ' ' <"$error_tmp")
        debug "ECR DescribeImages failed for $registry/$repository: $error_message"
        rm -f "$error_tmp"
        return 2
    fi

    if ! "$JQ" -e '.imageDetails | type == "array"' <<<"$response" >/dev/null; then
        debug "ECR DescribeImages returned an invalid response for $registry/$repository"
        return 2
    fi
    printf '%s\n' "$response"
}

function ecr_digest_for_tag_api {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local response digests

    response=$(ecr_private_image_details \
        "$registry" "$repository" "imageTag=$tag") || return $?
    digests=$(
        "$JQ" -r --arg tag "$tag" '
            .imageDetails[]
            | select((.imageTags // []) | index($tag) != null)
            | .imageDigest
        ' <<<"$response"
    )
    [[ -n "$digests" ]] || return 1
    if [[ "$digests" == *$'\n'* ]]; then
        debug "ECR returned multiple current digests for $registry/$repository:$tag"
        return 2
    fi
    printf '%s\n' "$digests"
}

function ecr_tags_by_digest_api {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local response matching_images

    response=$(ecr_private_image_details \
        "$registry" "$repository" "imageDigest=$digest") || return $?
    matching_images=$(
        "$JQ" -r --arg digest "$digest" '
            [.imageDetails[] | select(.imageDigest == $digest)] | length
        ' <<<"$response"
    )
    case "$matching_images" in
    0) return 1 ;;
    1) ;;
    *)
        debug "ECR returned multiple image records for $registry/$repository@$digest"
        return 2
        ;;
    esac

    "$JQ" -r \
        --arg digest "$digest" \
        --arg tag_scan "$registry_tag_scan" \
        --arg direct_tag "$registry_direct_tag" '
            [
                .imageDetails[]
                | select(.imageDigest == $digest)
                | .imageTags[]?
                | select($tag_scan != "any" or . != $direct_tag)
            ]
            | unique
            | if $tag_scan == "any" then .[0] // empty else .[] end
        ' <<<"$response"
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
    local repository="$2"
    local tag="$3"
    local image_reference="$4"
    local digest lookup_status

    if [[ "$registry" != public.ecr.aws ]]; then
        if digest=$(ecr_digest_for_tag_api "$registry" "$repository" "$tag"); then
            printf '%s\n' "$digest"
            return 0
        else
            lookup_status=$?
        fi
        (( lookup_status == 1 )) && return 1
        info "ECR API lookup is unavailable for $registry/$repository:$tag; falling back to Skopeo"
    fi

    skopeo_is_available || return 2
    skopeo_digest_for_tag_with_lazy_auth "$registry" "$image_reference" ecr_authenticate
}

function ecr_tags_by_digest_with_skopeo {
    local registry="$1"
    local repository="$2"
    local digest="$3"

    skopeo_tags_by_digest_with_lazy_auth \
        "$registry" "$repository" "$digest" ecr_authenticate
}
