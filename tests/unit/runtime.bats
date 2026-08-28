#!/usr/bin/env bats

load ../test-helper.bash

@test "RUNTIME-001 temporary files share one private runtime directory" {
    load_common

    first=$(runtime_temp_file first)
    second=$(runtime_temp_file second)

    [[ "${first%/*}" == "${second%/*}" ]]
    assert_file_mode "$runtime_tmp_dir" 700
}

@test "RUNTIME-002 cleanup removes every registered runtime resource" {
    load_common

    file=$(runtime_temp_file response)
    directory=$(runtime_temp_dir workers)
    printf 'value\n' >"$file"
    printf 'value\n' >"$directory/result"
    root="$runtime_tmp_dir"

    runtime_cleanup
    [[ ! -e "$root" ]]
}

@test "RUNTIME-003 registry JSON errors are single-line and bounded" {
    load_common
    response=$(runtime_temp_file response)
    printf '{"errors":[{"message":"first\\nsecond and more"}]}' >"$response"

    run registry_json_error_message "$response" 12
    assert_status 0
    assert_output_exact 'first second'
}

@test "RUNTIME-004 command errors are flattened without changing content order" {
    load_common
    error_file=$(runtime_temp_file error)
    printf 'first\nsecond\n' >"$error_file"

    run command_error_single_line "$error_file"
    assert_status 0
    assert_output_exact 'first second '
}

@test "RUNTIME-005 network command preserves streams and exit status" {
    load_common
    write_stub network-command <<'EOF'
read -r value
printf 'out:%s\n' "$value"
printf 'err:%s\n' "$value" >&2
exit 7
EOF

    run --separate-stderr run_network_command network-command <<<payload
    assert_status 7
    assert_output_exact 'out:payload'
    assert_stderr_exact 'err:payload'
}

@test "RUNTIME-006 network command deadline terminates the child process group" {
    export CIT_NETWORK_TIMEOUT_SECONDS=1
    load_common
    write_stub slow-network-command <<'EOF'
printf '%s\n' "$BASHPID" >"$CALLS_DIR/network-child.pid"
sleep 30
EOF

    run run_network_command slow-network-command
    assert_status 124
    child_pid=$(<"$CALLS_DIR/network-child.pid")
    ! kill -0 "$child_pid" 2>/dev/null
}

@test "RUNTIME-007 cleanup terminates registered child processes" {
    load_common
    write_stub stubborn-child <<'EOF'
trap '' TERM
: >"$CALLS_DIR/stubborn-child.ready"
sleep 30
EOF
    stubborn-child &
    child_pid=$!
    runtime_register_child "$child_pid"
    for _ in {1..100}; do
        [[ -e "$CALLS_DIR/stubborn-child.ready" ]] && break
        sleep 0.01
    done

    start=$SECONDS
    runtime_cleanup
    (( SECONDS - start < 2 ))
    ! kill -0 "$child_pid" 2>/dev/null
    [[ ${#runtime_child_pids[@]} -eq 0 ]]
}
