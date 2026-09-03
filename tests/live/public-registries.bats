#!/usr/bin/env bats

load ../test-helper.bash

@test "LIVE-001 configured generic public OCI tag resolves and scans anonymously" {
    [[ ${CIT_LIVE_GENERIC_OCI_REF:-} == *:* &&
        ${CIT_LIVE_GENERIC_OCI_REF:-} != *@* ]] ||
        skip 'set CIT_LIVE_GENERIC_OCI_REF to a public tagged image reference'
    [[ ${CIT_LIVE_GENERIC_OCI_DIGEST:-} =~ ^sha256:[a-f0-9]{64}$ ]] ||
        skip 'set CIT_LIVE_GENERIC_OCI_DIGEST to the expected complete digest'
    local expected_tag="${CIT_LIVE_GENERIC_OCI_REF##*:}"

    run --separate-stderr env \
        PATH="$ORIGINAL_PATH" CURL=curl JQ="$SYSTEM_JQ" \
        GETOPT="$SYSTEM_GETOPT" REALPATH="$SYSTEM_REALPATH" \
        TIMEOUT="$SYSTEM_TIMEOUT" SKOPEO="$TEST_ROOT/forbidden-skopeo" \
        "$SYSTEM_BASH" "$REPO_ROOT/container-image-tags" --json \
        --credential-policy=never --tag-resolution=remote --tag-scan=all \
        --allow-expensive-scan "$CIT_LIVE_GENERIC_OCI_REF"
    assert_status 0
    assert_valid_json
    "$SYSTEM_JQ" -e \
        --arg digest "$CIT_LIVE_GENERIC_OCI_DIGEST" \
        --arg tag "$expected_tag" '
            length == 1 and
            .[0].digest == $digest and
            .[0].remote_tag_check.status == "resolved" and
            .[0].tag_scan.status == "completed" and
            .[0].tag_scan.completion == "complete" and
            .[0].tag_scan.backend == "oci-registry-api" and
            (. [0].tag_scan.tags | index($tag)) != null
        ' <<<"$output"
}
