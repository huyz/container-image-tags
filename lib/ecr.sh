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

function ecr_aws_credentials_may_be_available {
    [[ -n ${AWS_ACCESS_KEY_ID-} || -n ${AWS_PROFILE-} ||
        -n ${AWS_DEFAULT_PROFILE-} || -n ${AWS_WEB_IDENTITY_TOKEN_FILE-} ||
        -n ${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI-} ||
        -n ${AWS_CONTAINER_CREDENTIALS_FULL_URI-} ]] && return 0

    "$AWS" configure list-profiles 2>/dev/null | grep -q .
}

# Query the signed ECR service API for one private-registry image identifier.
# Unlike the OCI registry API, DescribeImages returns every current tag for a
# digest in the same response. Use the shared LOOKUP_* status contract so an
# unavailable API can fall back to Skopeo while absence and terminal rate
# limiting remain distinct.
function ecr_private_image_details {
    local registry="$1"
    local repository="$2"
    local image_id="$3"
    local account region response error_tmp error_message

    [[ "$registry" != public.ecr.aws ]] || return "$LOOKUP_UNAVAILABLE"
    command -v "${AWS:=aws}" &>/dev/null || return "$LOOKUP_UNAVAILABLE"
    account=$(ecr_account_from_registry "$registry") || return "$LOOKUP_UNAVAILABLE"
    region=$(ecr_region_from_registry "$registry") || return "$LOOKUP_UNAVAILABLE"

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
            return "$LOOKUP_NOT_FOUND"
        fi
        if grep -Eqi 'ThrottlingException|TooManyRequestsException|rate exceeded' "$error_tmp"; then
            warn "ECR API rate limit reached for $registry/$repository"
            rm -f "$error_tmp"
            return "$LOOKUP_STOPPED"
        fi
        error_message=$(tr '\n' ' ' <"$error_tmp")
        debug "ECR DescribeImages failed for $registry/$repository: $error_message"
        rm -f "$error_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi

    if ! "$JQ" -e '.imageDetails | type == "array"' <<<"$response" >/dev/null; then
        debug "ECR DescribeImages returned an invalid response for $registry/$repository"
        return "$LOOKUP_UNAVAILABLE"
    fi
    printf '%s\n' "$response"
}

# Resolve an ECR Public registry alias without exhaustively paging the global
# registry catalog. A first-page hit enables the fast path; a miss is merely
# inconclusive and lets the caller retain anonymous OCI/Skopeo behavior.
function ecr_public_registry_id_for_alias {
    local alias="$1"
    local response error_tmp error_message registry_ids

    command -v "${AWS:=aws}" &>/dev/null || return "$LOOKUP_UNAVAILABLE"
    ecr_aws_credentials_may_be_available || return "$LOOKUP_UNAVAILABLE"
    error_tmp=$(mktemp)
    if response=$(
        "$AWS" ecr-public describe-registries \
            --region us-east-1 \
            --page-size 1000 \
            --no-paginate \
            --no-cli-pager \
            --output json 2>"$error_tmp"
    ); then
        rm -f "$error_tmp"
    else
        error_message=$(tr '\n' ' ' <"$error_tmp")
        debug "ECR Public registry-alias lookup failed for $alias: $error_message"
        rm -f "$error_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
    if ! "$JQ" -e '.registries | type == "array"' <<<"$response" >/dev/null; then
        debug "ECR Public DescribeRegistries returned an invalid response"
        return "$LOOKUP_UNAVAILABLE"
    fi
    registry_ids=$(
        "$JQ" -r --arg alias "$alias" '
            [
                .registries[]
                | select(any(.aliases[]?; .name == $alias and .status == "ACTIVE"))
                | .registryId
            ]
            | unique[]
        ' <<<"$response"
    )
    [[ -n "$registry_ids" && "$registry_ids" != *$'\n'* ]] ||
        return "$LOOKUP_UNAVAILABLE"
    [[ "$registry_ids" =~ ^[0-9]{12}$ ]] || return "$LOOKUP_UNAVAILABLE"
    printf '%s\n' "$registry_ids"
}

function ecr_public_image_details {
    local repository_path="$1"
    local image_id="$2"
    local alias="${repository_path%%/*}"
    local repository="${repository_path#*/}"
    local registry_id response error_tmp error_message

    [[ "$alias" != "$repository_path" && -n "$repository" ]] ||
        return "$LOOKUP_UNAVAILABLE"
    registry_id=$(ecr_public_registry_id_for_alias "$alias") || return $?

    error_tmp=$(mktemp)
    if response=$(
        "$AWS" ecr-public describe-images \
            --registry-id "$registry_id" \
            --repository-name "$repository" \
            --image-ids "$image_id" \
            --region us-east-1 \
            --no-cli-pager \
            --output json 2>"$error_tmp"
    ); then
        rm -f "$error_tmp"
    else
        if grep -q 'ImageNotFoundException' "$error_tmp"; then
            rm -f "$error_tmp"
            return "$LOOKUP_NOT_FOUND"
        fi
        if grep -Eqi 'ThrottlingException|TooManyRequestsException|rate exceeded' "$error_tmp"; then
            warn "ECR Public API rate limit reached for public.ecr.aws/$repository_path"
            rm -f "$error_tmp"
            return "$LOOKUP_STOPPED"
        fi
        error_message=$(tr '\n' ' ' <"$error_tmp")
        debug "ECR Public DescribeImages failed for $repository_path: $error_message"
        rm -f "$error_tmp"
        return "$LOOKUP_UNAVAILABLE"
    fi
    if ! "$JQ" -e '.imageDetails | type == "array"' <<<"$response" >/dev/null; then
        debug "ECR Public DescribeImages returned an invalid response for $repository_path"
        return "$LOOKUP_UNAVAILABLE"
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
    [[ -n "$digests" ]] || return "$LOOKUP_NOT_FOUND"
    if [[ "$digests" == *$'\n'* ]]; then
        debug "ECR returned multiple current digests for $registry/$repository:$tag"
        return "$LOOKUP_UNAVAILABLE"
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
    0) return "$LOOKUP_NOT_FOUND" ;;
    1) ;;
    *)
        debug "ECR returned multiple image records for $registry/$repository@$digest"
        return "$LOOKUP_UNAVAILABLE"
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

function ecr_public_tags_by_digest_api {
    local repository_path="$1"
    local digest="$2"
    local response matching_images

    response=$(ecr_public_image_details \
        "$repository_path" "imageDigest=$digest") || return $?
    matching_images=$(
        "$JQ" -r --arg digest "$digest" '
            [.imageDetails[] | select(.imageDigest == $digest)] | length
        ' <<<"$response"
    )
    case "$matching_images" in
    0) return "$LOOKUP_NOT_FOUND" ;;
    1) ;;
    *)
        debug "ECR Public returned multiple image records for $repository_path@$digest"
        return "$LOOKUP_UNAVAILABLE"
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
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
        (( lookup_status == LOOKUP_NOT_FOUND )) && return "$LOOKUP_NOT_FOUND"
        (( lookup_status == LOOKUP_STOPPED )) && return "$LOOKUP_STOPPED"
        notice "ECR API lookup is unavailable for $registry/$repository:$tag; falling back to Skopeo"
    fi

    skopeo_is_available || return "$LOOKUP_UNAVAILABLE"
    skopeo_digest_for_tag_with_lazy_auth "$registry" "$image_reference" ecr_authenticate
}

function ecr_tags_by_digest_with_skopeo {
    local registry="$1"
    local repository="$2"
    local digest="$3"

    skopeo_tags_by_digest_with_lazy_auth \
        "$registry" "$repository" "$digest" ecr_authenticate
}
