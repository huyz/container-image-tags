#!/usr/bin/env bats

load ../test-helper.bash

DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

function load_ecr {
    load_module ecr
}

function install_aws_response {
    export AWS_STDOUT="${1-}"
    export AWS_STDERR="${2-}"
    export AWS_STATUS="${3-0}"
    write_stub aws <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/aws.args"
printf '%s' "$AWS_STDOUT"
printf '%s' "$AWS_STDERR" >&2
exit "$AWS_STATUS"
EOF
}

@test "ECR-001 account extraction accepts only complete 12 digit IDs" {
    load_ecr
    run ecr_account_from_registry 123456789012.dkr.ecr.us-west-2.amazonaws.com
    assert_status 0
    assert_output_exact 123456789012
    run ecr_account_from_registry 1234.dkr.ecr.us-west-2.amazonaws.com
    assert_status 1
}

@test "ECR-002 region extraction covers standard FIPS China and on.aws hosts" {
    load_ecr
    for pair in \
        '123456789012.dkr.ecr.us-west-2.amazonaws.com us-west-2' \
        '123456789012.dkr.ecr-fips.us-gov-west-1.amazonaws.com us-gov-west-1' \
        '123456789012.dkr.ecr.cn-north-1.amazonaws.com.cn cn-north-1' \
        '123456789012.dkr-ecr.eu-west-1.on.aws eu-west-1'; do
        set -- $pair
        run ecr_region_from_registry "$1"
        assert_status 0
        assert_output_exact "$2"
    done
}

@test "ECR-003 private direct lookup sends exact DescribeImages arguments" {
    load_ecr
    install_aws_response '{"imageDetails":[{"imageDigest":"sha256:one","imageTags":["stable"]}]}'

    run ecr_digest_for_tag_api \
        123456789012.dkr.ecr.us-west-2.amazonaws.com team/app stable
    assert_status 0
    assert_output_exact sha256:one
    assert_call_args "$CALLS_DIR/aws.args" ecr describe-images --registry-id 123456789012 \
        --repository-name team/app --image-ids imageTag=stable --region us-west-2 \
        --no-cli-pager --output json
}

@test "ECR-004 reverse lookup selects the exact digest and tags" {
    load_ecr
    install_aws_response "{\"imageDetails\":[{\"imageDigest\":\"$DIGEST\",\"imageTags\":[\"stable\",\"v1\"]}]}"
    registry_tag_scan=all
    registry_direct_tag=

    run ecr_tags_by_digest_api \
        123456789012.dkr.ecr.us-west-2.amazonaws.com team/app "$DIGEST"
    assert_status 0
    assert_output_exact $'stable\nv1'
}

@test "ECR-005 ImageNotFoundException is authoritative" {
    load_ecr
    install_aws_response '' 'ImageNotFoundException: absent' 254

    run ecr_private_image_details \
        123456789012.dkr.ecr.us-west-2.amazonaws.com team/app imageTag=absent
    assert_status "$LOOKUP_NOT_FOUND"
}

@test "ECR-006 throttling errors are terminal" {
    load_ecr
    install_aws_response '' 'ThrottlingException: rate exceeded' 254

    run --separate-stderr ecr_private_image_details \
        123456789012.dkr.ecr.us-west-2.amazonaws.com team/app imageTag=stable
    assert_status "$LOOKUP_STOPPED"
    assert_stderr_contains 'rate limit reached'
}

@test "ECR-007 invalid JSON and ordinary CLI failure are unavailable" {
    load_ecr
    install_aws_response '{}' '' 0

    run ecr_private_image_details \
        123456789012.dkr.ecr.us-west-2.amazonaws.com team/app imageTag=stable
    assert_status "$LOOKUP_UNAVAILABLE"

    install_aws_response '' 'AccessDeniedException' 254
    run ecr_private_image_details \
        123456789012.dkr.ecr.us-west-2.amazonaws.com team/app imageTag=stable
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "ECR-008 multiple current digests are rejected rather than guessed" {
    load_ecr
    install_aws_response '{"imageDetails":[{"imageDigest":"sha256:one","imageTags":["stable"]},{"imageDigest":"sha256:two","imageTags":["stable"]}]}'

    run ecr_digest_for_tag_api \
        123456789012.dkr.ecr.us-west-2.amazonaws.com team/app stable
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "ECR-009 any mode excludes the direct tag and deduplicates" {
    load_ecr
    install_aws_response "{\"imageDetails\":[{\"imageDigest\":\"$DIGEST\",\"imageTags\":[\"stable\",\"z\",\"a\",\"z\"]}]}"
    registry_tag_scan=any
    registry_direct_tag=stable

    run ecr_tags_by_digest_api \
        123456789012.dkr.ecr.us-west-2.amazonaws.com team/app "$DIGEST"
    assert_status 0
    assert_output_exact a
}

@test "ECR-011 AWS login password travels through stdin not argv" {
    load_ecr
    skopeo_session_authfile="$TEST_ROOT/ecr-auth.json"
    : >"$skopeo_session_authfile"
    export AWS_CANARY=aws-password-canary
    write_stub aws <<'EOF'
printf '%s\n' "$AWS_CANARY"
EOF
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/skopeo.args"
IFS= read -r secret
printf '%s' "$secret" >"$CALLS_DIR/skopeo.stdin"
EOF

    run ecr_authenticate 123456789012.dkr.ecr.us-west-2.amazonaws.com
    assert_status 0
    [[ $(<"$CALLS_DIR/skopeo.stdin") == "$AWS_CANARY" ]]
    args=$(tr '\0' '\n' <"$CALLS_DIR/skopeo.args")
    [[ "$args" == *'--password-stdin'* ]]
    [[ "$args" != *"$AWS_CANARY"* ]]
}

@test "ECR-012 configured credentials are attempted before AWS CLI login" {
    load_common
    # shellcheck source=../../lib/skopeo.sh
    source "$REPO_ROOT/lib/skopeo.sh"
    # shellcheck source=../../lib/ecr.sh
    source "$REPO_ROOT/lib/ecr.sh"
    skopeo_anonymous_authfile="$TEST_ROOT/anonymous.json"
    skopeo_session_authfile="$TEST_ROOT/session.json"
    function skopeo_session_has_registry { return 1; }
    function skopeo_has_registry_credentials { return 0; }
    function skopeo_digest_for_tag_with_status {
        case "${2-}" in
        "$skopeo_anonymous_authfile") printf '%s\n' anonymous >>"$CALLS_DIR/order"; return "$LOOKUP_DENIED" ;;
        '') printf '%s\n' configured >>"$CALLS_DIR/order"; return "$LOOKUP_DENIED" ;;
        "$skopeo_session_authfile") printf '%s\n' session >>"$CALLS_DIR/order"; printf '%s\n' sha256:ok ;;
        esac
    }
    function fake_ecr_authenticate { printf '%s\n' aws >>"$CALLS_DIR/order"; }

    run --separate-stderr skopeo_digest_for_tag_with_lazy_auth \
        123456789012.dkr.ecr.us-west-2.amazonaws.com \
        123456789012.dkr.ecr.us-west-2.amazonaws.com/app:stable \
        fake_ecr_authenticate
    assert_status 0
    assert_output_exact sha256:ok
    assert_stderr_contains 'Using configured registry credentials'
    [[ $(<"$CALLS_DIR/order") == $'anonymous\nconfigured\naws\nsession' ]]
}

@test "ECRP-001 supported AWS credential variables enable metadata probing" {
    load_ecr
    write_stub aws <<'EOF'
exit 1
EOF
    export AWS_WEB_IDENTITY_TOKEN_FILE="$TEST_ROOT/token"

    run ecr_aws_credentials_may_be_available
    assert_status 0
}

@test "ECRP-002 configured profiles permit probing without exposing profile data" {
    load_ecr
    export PROFILE_CANARY=private-profile-canary
    write_stub aws <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/aws.args"
printf '%s\n' "$PROFILE_CANARY"
EOF

    run --separate-stderr ecr_aws_credentials_may_be_available
    assert_status 0
    assert_output_exact ''
    assert_stderr_exact ''
    assert_call_args "$CALLS_DIR/aws.args" configure list-profiles
}

@test "ECRP-003 no possible AWS credentials skips alias metadata lookup" {
    load_ecr
    write_stub aws <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/aws.args"
exit 0
EOF

    run ecr_public_registry_id_for_alias alias
    assert_status "$LOOKUP_UNAVAILABLE"
    args=$(tr '\0' '\n' <"$CALLS_DIR/aws.args")
    [[ "$args" == *'configure'* ]]
    [[ "$args" != *'describe-registries'* ]]
}

@test "ECRP-004 alias lookup uses fixed region page size and no pagination" {
    load_ecr
    export AWS_PROFILE=test
    install_aws_response '{"registries":[{"registryId":"123456789012","aliases":[{"name":"alias","status":"ACTIVE"}]}]}'

    run ecr_public_registry_id_for_alias alias
    assert_status 0
    assert_output_exact 123456789012
    assert_call_args "$CALLS_DIR/aws.args" ecr-public describe-registries --region us-east-1 \
        --page-size 1000 --no-paginate --no-cli-pager --output json
}

@test "ECRP-005 alias lookup accepts exactly one active alias and valid account ID" {
    load_ecr
    export AWS_PROFILE=test
    install_aws_response '{"registries":[{"registryId":"123456789012","aliases":[{"name":"target","status":"ACTIVE"},{"name":"target-old","status":"INACTIVE"}]}]}'

    run ecr_public_registry_id_for_alias target
    assert_status 0
    assert_output_exact 123456789012

    install_aws_response '{"registries":[{"registryId":"1234","aliases":[{"name":"target","status":"ACTIVE"}]}]}'
    run ecr_public_registry_id_for_alias target
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "ECRP-006 ambiguous aliases are unavailable" {
    load_ecr
    export AWS_PROFILE=test
    install_aws_response '{"registries":[{"registryId":"123456789012","aliases":[{"name":"alias","status":"ACTIVE"}]},{"registryId":"999999999999","aliases":[{"name":"alias","status":"ACTIVE"}]}]}'

    run ecr_public_registry_id_for_alias alias
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "ECRP-008 public reverse lookup uses registry ID repository and us-east-1" {
    load_ecr
    function ecr_public_registry_id_for_alias { printf '%s\n' 123456789012; }
    install_aws_response "{\"imageDetails\":[{\"imageDigest\":\"$DIGEST\",\"imageTags\":[\"latest\"]}]}"

    run ecr_public_image_details alias/team/app "imageDigest=$DIGEST"
    assert_status 0
    assert_call_args "$CALLS_DIR/aws.args" ecr-public describe-images \
        --registry-id 123456789012 --repository-name team/app \
        --image-ids "imageDigest=$DIGEST" --region us-east-1 --no-cli-pager --output json
}

@test "ECRP-007 public metadata strips only the alias path component" {
    load_ecr
    function ecr_public_registry_id_for_alias {
        printf '%s\n' "$1" >"$CALLS_DIR/alias"
        printf '%s\n' 123456789012
    }
    install_aws_response '{"imageDetails":[]}'

    run ecr_public_image_details alias/team/nested/app imageDigest=sha256:one
    assert_status 0
    [[ $(<"$CALLS_DIR/alias") == alias ]]
    args=$(tr '\0' '\n' <"$CALLS_DIR/aws.args")
    [[ "$args" == *$'--repository-name\nteam/nested/app\n'* ]]
}

@test "ECRP-009 public not-found and throttling statuses stay authoritative" {
    load_ecr
    function ecr_public_registry_id_for_alias { printf '%s\n' 123456789012; }
    install_aws_response '' 'ImageNotFoundException: absent' 254
    run ecr_public_image_details alias/app imageDigest=sha256:missing
    assert_status "$LOOKUP_NOT_FOUND"

    install_aws_response '' 'TooManyRequestsException: slow down' 254
    run --separate-stderr ecr_public_image_details alias/app imageDigest=sha256:one
    assert_status "$LOOKUP_STOPPED"
    assert_stderr_contains 'ECR Public API rate limit reached'
}

@test "ECRP-011 direct public tags retain the registry fallback path" {
    load_ecr
    function ecr_digest_for_tag_api { : >"$CALLS_DIR/unexpected-api"; }
    function skopeo_is_available { return 0; }
    function skopeo_digest_for_tag_with_lazy_auth { printf '%s\n' sha256:registry; }

    run ecr_digest_for_tag public.ecr.aws alias/app stable public.ecr.aws/alias/app:stable
    assert_status 0
    assert_output_exact sha256:registry
    refute_file_exists "$CALLS_DIR/unexpected-api"
}

@test "ECRP-012 public login password uses stdin and fixed us-east-1" {
    load_ecr
    skopeo_session_authfile="$TEST_ROOT/public-auth.json"
    : >"$skopeo_session_authfile"
    export AWS_CANARY=public-password-canary
    write_stub aws <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/aws.args"
printf '%s\n' "$AWS_CANARY"
EOF
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/skopeo.args"
IFS= read -r secret
printf '%s' "$secret" >"$CALLS_DIR/skopeo.stdin"
EOF

    run ecr_authenticate public.ecr.aws
    assert_status 0
    assert_call_args "$CALLS_DIR/aws.args" ecr-public get-login-password \
        --region us-east-1 --no-cli-pager
    [[ $(<"$CALLS_DIR/skopeo.stdin") == "$AWS_CANARY" ]]
    ! grep -aFq "$AWS_CANARY" "$CALLS_DIR/skopeo.args"
}
