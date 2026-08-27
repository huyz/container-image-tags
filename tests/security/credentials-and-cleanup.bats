#!/usr/bin/env bats

load ../test-helper.bash

@test "SEC-001 Docker Hub bearer header is mode 0600 and contains no argv secret" {
    load_common
    # shellcheck source=../../lib/docker-hub.sh
    source "$REPO_ROOT/lib/docker-hub.sh"
    docker_hub_token=hub-security-canary
    header="$TEST_ROOT/hub.headers"

    docker_hub_write_request_headers "$header"
    assert_file_mode "$header" 600
    grep -Fxq 'Authorization: Bearer hub-security-canary' "$header"
}

@test "SEC-002 OCI bearer header is mode 0600" {
    load_module oci
    header="$TEST_ROOT/oci.headers"

    oci_write_request_headers "$header" oci-security-canary
    assert_file_mode "$header" 600
    grep -Fxq 'Authorization: Bearer oci-security-canary' "$header"
}

@test "SEC-003 Azure access token travels through stdin and never argv or output" {
    load_module acr
    skopeo_session_authfile="$TEST_ROOT/azure-auth.json"
    : >"$skopeo_session_authfile"
    chmod 600 "$skopeo_session_authfile"
    export AZURE_CANARY=azure-security-canary
    write_stub az <<'EOF'
printf '%s\n' "$AZURE_CANARY"
EOF
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/skopeo.args"
IFS= read -r secret
printf '%s' "$secret" >"$CALLS_DIR/skopeo.stdin"
EOF

    run --separate-stderr acr_authenticate vault.azurecr.io
    assert_status 0
    refute_output_contains "$AZURE_CANARY"
    refute_stderr_contains "$AZURE_CANARY"
    ! grep -aFq "$AZURE_CANARY" "$CALLS_DIR/skopeo.args"
    [[ $(<"$CALLS_DIR/skopeo.stdin") == "$AZURE_CANARY" ]]
}

@test "SEC-004 Google access token travels through stdin and never argv or output" {
    load_module gar
    skopeo_session_authfile="$TEST_ROOT/google-auth.json"
    : >"$skopeo_session_authfile"
    chmod 600 "$skopeo_session_authfile"
    export GOOGLE_CANARY=google-security-canary
    write_stub gcloud <<'EOF'
printf '%s\n' "$GOOGLE_CANARY"
EOF
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/skopeo.args"
IFS= read -r secret
printf '%s' "$secret" >"$CALLS_DIR/skopeo.stdin"
EOF

    run --separate-stderr gar_authenticate us-docker.pkg.dev
    assert_status 0
    refute_output_contains "$GOOGLE_CANARY"
    refute_stderr_contains "$GOOGLE_CANARY"
    ! grep -aFq "$GOOGLE_CANARY" "$CALLS_DIR/skopeo.args"
    [[ $(<"$CALLS_DIR/skopeo.stdin") == "$GOOGLE_CANARY" ]]
}

@test "SEC-005 AWS login password travels through stdin and never argv or output" {
    load_module ecr
    skopeo_session_authfile="$TEST_ROOT/aws-auth.json"
    : >"$skopeo_session_authfile"
    chmod 600 "$skopeo_session_authfile"
    export AWS_CANARY=aws-security-canary
    write_stub aws <<'EOF'
printf '%s\n' "$AWS_CANARY"
EOF
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/skopeo.args"
IFS= read -r secret
printf '%s' "$secret" >"$CALLS_DIR/skopeo.stdin"
EOF

    run --separate-stderr ecr_authenticate \
        123456789012.dkr.ecr.us-west-2.amazonaws.com
    assert_status 0
    refute_output_contains "$AWS_CANARY"
    refute_stderr_contains "$AWS_CANARY"
    ! grep -aFq "$AWS_CANARY" "$CALLS_DIR/skopeo.args"
    [[ $(<"$CALLS_DIR/skopeo.stdin") == "$AWS_CANARY" ]]
}

@test "SEC-007 Skopeo lazy authfiles are private and isolated" {
    load_module skopeo
    skopeo_prepare_lazy_auth
    anonymous="$skopeo_anonymous_authfile"
    session="$skopeo_session_authfile"

    assert_file_mode "$anonymous" 600
    assert_file_mode "$session" 600
    [[ "$anonymous" != "$session" ]]
    [[ $(<"$anonymous") == '{"auths":{}}' ]]
    [[ $(<"$session") == '{"auths":{}}' ]]
    skopeo_cleanup_lazy_auth
}

@test "SEC-008 normal cleanup removes temporary authfiles" {
    load_module skopeo
    skopeo_prepare_lazy_auth
    anonymous="$skopeo_anonymous_authfile"
    session="$skopeo_session_authfile"

    skopeo_cleanup_lazy_auth
    refute_file_exists "$anonymous"
    refute_file_exists "$session"
}

@test "SEC-009 Linux signal cleanup returns 130 terminates workers and removes authfiles" {
    [[ "$OSTYPE" != darwin* ]] || skip 'process-group SIGINT coverage runs in Linux CI'
    command -v setsid >/dev/null 2>&1 || skip 'setsid unavailable on this platform'
    export INTERRUPT_REPO_ROOT="$REPO_ROOT"
    write_stub interrupt-harness <<'EOF'
SCRIPT_NAME=interrupt-harness
source "$INTERRUPT_REPO_ROOT/lib/common.sh"
source "$INTERRUPT_REPO_ROOT/lib/runtime.sh"
source "$INTERRUPT_REPO_ROOT/lib/skopeo.sh"
trap 'exit 130' INT TERM
skopeo_prepare_lazy_auth
printf '%s\n' "$skopeo_anonymous_authfile" >"$CALLS_DIR/anonymous.path"
printf '%s\n' "$skopeo_session_authfile" >"$CALLS_DIR/session.path"
registry_tag_scan=all
candidates=(one two)
function slow_lookup {
    printf '%s\n' "$BASHPID" >>"$CALLS_DIR/workers"
    sleep 30
    printf '%s\n' sha256:other
}
tags_by_digest_with_rolling_pool repo sha256:wanted candidates 2 \
    progress worker slow_lookup 1
EOF

    setsid "$STUB_BIN/interrupt-harness" >"$CALLS_DIR/harness.out" \
        2>"$CALLS_DIR/harness.err" &
    harness_pid=$!
    for _ in {1..100}; do
        [[ -s "$CALLS_DIR/workers" && -s "$CALLS_DIR/session.path" ]] && break
        sleep 0.02
    done
    [[ -s "$CALLS_DIR/workers" && -s "$CALLS_DIR/session.path" ]]
    # Linux background shells launched through setsid ignore SIGINT, so use
    # SIGTERM to exercise prompt signal-driven cleanup in CI.
    kill -TERM -- "-$harness_pid"
    for _ in {1..100}; do
        kill -0 "$harness_pid" 2>/dev/null || break
        sleep 0.02
    done
    if kill -0 "$harness_pid" 2>/dev/null; then
        kill -TERM -- "-$harness_pid" 2>/dev/null || true
        wait "$harness_pid" 2>/dev/null || true
        fail_test 'interrupt harness did not exit promptly after SIGINT'
    fi
    if wait "$harness_pid"; then harness_status=0; else harness_status=$?; fi
    [[ "$harness_status" -eq 130 ]]

    while IFS= read -r worker_pid; do
        ! kill -0 "$worker_pid" 2>/dev/null
    done <"$CALLS_DIR/workers"
    refute_file_exists "$(<"$CALLS_DIR/anonymous.path")"
    refute_file_exists "$(<"$CALLS_DIR/session.path")"
}

@test "SEC-010 registry error body cannot forge records and is length bounded" {
    load_common
    # shellcheck source=../../lib/docker-hub.sh
    source "$REPO_ROOT/lib/docker-hub.sh"
    registry_tag_scan=all; registry_direct_tag=; registry_tags=; skip_input=; docker_hub_token=
    long_message=$(printf '%0600d' 0)
    export HUB_ERROR_BODY="{\"message\":\"${long_message}\\nNOTICE: forged-record\"}"
    write_stub curl <<'EOF'
output=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -o ]]; then index=$((index + 1)); output="${!index}"; fi
done
printf '%s' "$HUB_ERROR_BODY" >"$output"
printf '500'
EOF

    run --separate-stderr docker_hub_tags_by_digest \
        library/app sha256:one app
    assert_status 1
    [[ ${#stderr} -lt 700 ]]
    ! grep -Fxq 'NOTICE: forged-record' <<<"$stderr"
}

@test "SEC-011 isolated user configuration remains untouched" {
    config="$DOCKER_CONFIG/config.json"
    printf '%s\n' '{"auths":{"do-not-touch":{}}}' >"$config"
    before=$(file_sha256 "$config")
    load_module skopeo
    skopeo_prepare_lazy_auth
    skopeo_cleanup_lazy_auth
    after=$(file_sha256 "$config")

    [[ "$before" == "$after" ]]
}

@test "SEC-012 debug diagnostics do not print credential canaries" {
    load_common
    opt_debug=1
    canary=never-print-this-secret

    run --separate-stderr debug 'safe registry diagnostic'
    assert_status 0
    refute_output_contains "$canary"
    refute_stderr_contains "$canary"
}
