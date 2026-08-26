#!/usr/bin/env bats

load ../test-helper.bash

DIGEST=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

function install_required_tools {
    write_static_stub curl '' 0
    write_static_stub docker '' 1
}

@test "SMOKE-002 installation symlink resolves modules from the physical checkout" {
    install_required_tools
    mkdir -p "$TEST_ROOT/install/bin"
    ln -s "$REPO_ROOT/container-image-tags" "$TEST_ROOT/install/bin/cit"

    run --separate-stderr "$SYSTEM_BASH" "$TEST_ROOT/install/bin/cit" \
        --tag-resolution=remote --tag-scan=never \
        "registry.example/app@sha256:$DIGEST" </dev/null
    assert_status 0
    assert_output_contains 'Repository:      registry.example/app'
}

@test "SMOKE-003 executable behavior does not depend on current directory" {
    install_required_tools

    cd "$TEST_ROOT"
    run --separate-stderr "$SYSTEM_BASH" "$REPO_ROOT/container-image-tags" \
        --tag-resolution=remote --tag-scan=never \
        "registry.example/app@sha256:$DIGEST" </dev/null
    assert_status 0
    assert_output_contains "Manifest digest: sha256:$DIGEST"
}
