#!/usr/bin/env bats

load ../test-helper.bash

@test "LIVE-001 configured generic public OCI digest lookup succeeds" {
    [[ ${CIT_LIVE_GENERIC_OCI_REF:-} == *@sha256:* ]] ||
        skip 'set CIT_LIVE_GENERIC_OCI_REF to a complete public digest reference'

    PATH="$ORIGINAL_PATH" CURL=curl JQ="$SYSTEM_JQ" GETOPT="$SYSTEM_GETOPT" REALPATH="$SYSTEM_REALPATH" TIMEOUT="$SYSTEM_TIMEOUT" \
        run "$SYSTEM_BASH" "$REPO_ROOT/container-image-tags" \
            --tag-resolution=remote --tag-scan=any-durable "$CIT_LIVE_GENERIC_OCI_REF"
    assert_status 0
}
