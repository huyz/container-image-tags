function fail_test {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

function assert_status {
    local expected="$1"

    [[ "$status" -eq "$expected" ]] ||
        fail_test "expected status $expected, got $status; output=${output-}; stderr=${stderr-}"
}

function assert_output_exact {
    local expected="$1"

    [[ "${output-}" == "$expected" ]] ||
        fail_test "expected stdout [$expected], got [${output-}]"
}

function assert_stderr_exact {
    local expected="$1"

    [[ "${stderr-}" == "$expected" ]] ||
        fail_test "expected stderr [$expected], got [${stderr-}]"
}

function assert_output_contains {
    local expected="$1"

    [[ "${output-}" == *"$expected"* ]] ||
        fail_test "stdout did not contain [$expected]; got [${output-}]"
}

function assert_stderr_contains {
    local expected="$1"

    [[ "${stderr-}" == *"$expected"* ]] ||
        fail_test "stderr did not contain [$expected]; got [${stderr-}]"
}

function refute_output_contains {
    local unexpected="$1"

    [[ "${output-}" != *"$unexpected"* ]] ||
        fail_test "stdout unexpectedly contained [$unexpected]"
}

function refute_stderr_contains {
    local unexpected="$1"

    [[ "${stderr-}" != *"$unexpected"* ]] ||
        fail_test "stderr unexpectedly contained [$unexpected]"
}

function assert_file_exists {
    [[ -e "$1" ]] || fail_test "expected file to exist: $1"
}

function refute_file_exists {
    [[ ! -e "$1" ]] || fail_test "expected file not to exist: $1"
}

function file_mode {
    local path="$1"

    if stat -c '%a' "$path" >/dev/null 2>&1; then
        stat -c '%a' "$path"
    else
        stat -f '%Lp' "$path"
    fi
}

function assert_file_mode {
    local path="$1"
    local expected="$2"
    local actual

    actual=$(file_mode "$path")
    [[ "$actual" == "$expected" ]] ||
        fail_test "expected $path mode $expected, got $actual"
}

function file_sha256 {
    local path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    else
        shasum -a 256 "$path" | awk '{print $1}'
    fi
}

function assert_valid_json {
    "$SYSTEM_JQ" -e . >/dev/null <<<"${output-}" ||
        fail_test "stdout was not valid JSON: ${output-}"
}

function assert_json {
    local expression="$1"

    "$SYSTEM_JQ" -e "$expression" >/dev/null <<<"${output-}" ||
        fail_test "jq assertion failed: $expression; JSON=${output-}"
}

function assert_call_args {
    local log_file="$1"
    shift
    local expected_count=$#
    local -a actual=()
    local -a expected=("$@")

    assert_file_exists "$log_file" || return 1
    while IFS= read -r -d '' argument; do
        actual+=("$argument")
    done <"$log_file"
    [[ "${#actual[@]}" -eq "$expected_count" ]] ||
        fail_test "expected $expected_count args in $log_file, got ${#actual[@]}: ${actual[*]}" || return 1
    local index
    for ((index = 0; index < expected_count; ++index)); do
        [[ "${actual[$index]}" == "${expected[$index]}" ]] ||
            fail_test "argument $index: expected [${expected[$index]}], got [${actual[$index]}]" || return 1
    done
}

function assert_tree_excludes {
    local canary="$1"
    local match

    match=$(grep -R -F -l -- "$canary" "$TEST_ROOT" 2>/dev/null || true)
    [[ -z "$match" ]] || fail_test "secret canary found under test root: $match"
}
