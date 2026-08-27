#!/usr/bin/env bats

load ../test-helper.bash

@test "RUNTIME-001 temporary files share one private runtime directory" {
    load_common

    first=$(runtime_temp_file first)
    second=$(runtime_temp_file second)

    [[ "${first%/*}" == "${second%/*}" ]]
    [[ $(stat -f '%Lp' "$runtime_tmp_dir" 2>/dev/null || stat -c '%a' "$runtime_tmp_dir") == 700 ]]
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
