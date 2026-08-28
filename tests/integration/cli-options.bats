#!/usr/bin/env bats

load ../test-helper.bash

DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

function install_noop_required_tools {
    write_static_stub curl '' 0
    write_static_stub docker '' 1
}

function install_empty_oci_curl {
    write_stub curl <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/curl.args"
if [[ " $* " == *' --help all '* ]]; then
    printf '%s\n' '--parallel-max'
    exit 0
fi
header_file=
body_file=
for ((index = 1; index <= $#; ++index)); do
    argument="${!index}"
    case "$argument" in
    -D)
        index=$((index + 1)); header_file="${!index}"
        ;;
    -o)
        index=$((index + 1)); body_file="${!index}"
        ;;
    esac
done
[[ -z "$header_file" ]] || printf 'HTTP/1.1 200 OK\r\n\r\n' >"$header_file"
[[ -z "$body_file" || "$body_file" == /dev/null ]] || printf '{"tags":[]}\n' >"$body_file"
printf '200'
EOF
}

function run_cli {
    # Disconnect stdin so ordinary cases stay noninteractive even when Bats owns
    # a TTY. run_cli_with_tty_input is the sole helper that gives the child the
    # terminal input and terminal diagnostics required for prompting.
    run --separate-stderr "$SYSTEM_BASH" "$REPO_ROOT/container-image-tags" "$@" </dev/null
}

function run_cli_with_tty_input {
    # script(1) gives the child terminal-backed stdin and stderr while the CLI's
    # normal stdout is redirected, matching the descriptor contract checked by
    # is_interactive_session. Keep script's input descriptor open until the child
    # exits; closing it early hangs up the PTY and can make a later isatty(3)
    # check report false.
    local tty_input="$1"
    local stdout_file="$2"
    shift 2
    local command_string

    printf -v command_string '%q ' "$SYSTEM_BASH" \
        "$REPO_ROOT/container-image-tags" "$@"
    printf -v command_string '%s > %q' "$command_string" "$stdout_file"
    if script --help 2>&1 | grep -q -- ' -c'; then
        run "$SYSTEM_BASH" -c \
            'coproc PTY_SESSION { script -q -e -c "$2" /dev/null; }
            pty_pid=$PTY_SESSION_PID
            exec 8<&"${PTY_SESSION[0]}"
            exec 9>&"${PTY_SESSION[1]}"
            printf "%s" "$1" >&9
            cat <&8
            wait "$pty_pid"' \
            _ "$tty_input" "$command_string"
    else
        run "$SYSTEM_BASH" -c \
            'coproc PTY_SESSION { script -q /dev/null "$3" -c "$2"; }
            pty_pid=$PTY_SESSION_PID
            exec 8<&"${PTY_SESSION[0]}"
            exec 9>&"${PTY_SESSION[1]}"
            printf "%s" "$1" >&9
            cat <&8
            wait "$pty_pid"' \
            _ "$tty_input" "$command_string" "$SYSTEM_BASH"
    fi
}

@test "CLI-001 short and long help succeed and document current modes" {
    install_noop_required_tools

    run_cli --help
    assert_status 0
    assert_output_contains '--tag-resolution'
    assert_output_contains 'any: stop after finding the first matching tag, even if it is'
    assert_output_contains 'any-durable: stop after finding one matching tag heuristically'

    run_cli -h
    assert_status 0
    assert_output_contains 'repository@sha256:'
}

@test "CLI-001a version prints the single release version" {
    install_noop_required_tools

    run_cli --version
    assert_status 0
    assert_output_contains "container-image-tags 0.1.0"
}

@test "SMOKE-001 help runs with all external dependencies stubbed" {
    install_noop_required_tools

    run_cli --help
    assert_status 0
    assert_output_contains 'Usage:'
    assert_output_contains 'repository@sha256:'
    assert_output_contains '--tag-scan'
}

@test "CLI-002 missing positional input prints usage and exits one" {
    install_noop_required_tools

    run_cli --tag-resolution=remote
    assert_status 1
    assert_stderr_contains 'Usage:'
}

@test "CLI-003 unknown options use getopt status two" {
    install_noop_required_tools

    run_cli --not-an-option
    assert_status 2
    assert_stderr_contains 'unrecognized option'
    assert_stderr_contains 'Usage:'
}

@test "CLI-004 invalid tag resolution reports accepted values" {
    install_noop_required_tools

    run_cli --tag-resolution=invalid example
    assert_status 1
    assert_stderr_contains "--tag-resolution must be 'auto', 'local', or 'remote'"
}

@test "CLI-005 invalid tag scan reports accepted values" {
    install_noop_required_tools

    run_cli --help --tag-scan=any-durable
    assert_status 0

    run_cli --tag-resolution=remote --tag-scan=invalid example
    assert_status 1
    assert_stderr_contains "--tag-scan must be 'ask', 'never', 'any', 'any-durable', or 'all'"
}

@test "CLI-006 credential policy accepts four modes and rejects ambiguous legacy names" {
    install_noop_required_tools

    for policy in never if-required if-faster require; do
        run_cli --help --credential-policy="$policy"
        assert_status 0
    done

    run_cli --tag-resolution=remote --credential-policy=auto example
    assert_status 1
    assert_stderr_contains "--credential-policy must be 'never', 'if-required', 'if-faster', or 'require'"
}

@test "CLI-007 short and long verbose and debug flags enable independent diagnostics" {
    install_empty_oci_curl
    write_static_stub docker '' 1

    run_cli -v --tag-resolution=remote --tag-scan=all \
        "registry.example/app@sha256:$DIGEST"
    assert_status 0
    assert_stderr_contains 'Listing OCI registry tags from:'
    refute_stderr_contains 'DEBUG:'

    run_cli --verbose --tag-resolution=remote --tag-scan=all \
        "registry.example/app@sha256:$DIGEST"
    assert_status 0
    assert_stderr_contains 'Listing OCI registry tags from:'

    write_stub curl <<'EOF'
output=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -o ]]; then index=$((index + 1)); output="${!index}"; fi
done
[[ -z "$output" ]] || printf '{}' >"$output"
printf '500'
EOF
    run_cli --debug --tag-resolution=remote --tag-scan=never alpine
    assert_status 1
    assert_stderr_contains 'DEBUG: Docker Hub tag lookup returned HTTP 500'

    run_cli -d --tag-resolution=remote --tag-scan=never alpine
    assert_status 1
    assert_stderr_contains 'DEBUG: Docker Hub tag lookup returned HTTP 500'
}

@test "CLI-008 JSON defaults to any-durable and emits one clean array" {
    install_empty_oci_curl
    write_static_stub docker '' 1

    run_cli --json --tag-resolution=remote \
        "registry.example/team/app@sha256:$DIGEST"
    assert_status 0
    assert_valid_json
    assert_json 'length == 1 and .[0].tag_scan.mode == "any-durable"'
    assert_json '.[0].tag_scan.backend == "oci-registry-api"'
}

@test "CLI-009 non-interactive human mode defaults to any-durable even when Bats owns a TTY" {
    install_empty_oci_curl
    write_static_stub docker '' 1

    run_cli --tag-resolution=remote \
        "registry.example/team/app@sha256:$DIGEST"
    assert_status 0
    assert_output_contains 'Remote tags (partial scan):'
}

@test "CLI-010 terminal stdin and stderr default human mode to ask" {
    command -v script >/dev/null 2>&1 || skip 'script utility unavailable'
    install_empty_oci_curl
    write_static_stub docker '' 1

    run_cli_with_tty_input $'n\n' "$TEST_ROOT/tty-stdout" --tag-resolution=remote \
        "registry.example/team/app@sha256:$DIGEST"
    assert_status 0
    assert_output_contains 'Scan remote tags?'
    assert_output_contains 'Choose [1/d/a/n]:'
    refute_output_contains 'Other remote tags:'
    assert_file_exists "$TEST_ROOT/tty-stdout"
    [[ $(<"$TEST_ROOT/tty-stdout") == *'Repository:'* ]] ||
        fail_test 'redirected stdout did not contain the human result'
    refute_file_exists "$CALLS_DIR/curl.args"
}

@test "CLI-011 explicit never mode suppresses all registry calls" {
    write_stub curl <<'EOF'
: >"$CALLS_DIR/unexpected-curl"
exit 99
EOF
    write_static_stub docker '' 1

    run_cli --tag-resolution=remote --tag-scan=never \
        "registry.example/team/app@sha256:$DIGEST"
    assert_status 0
    refute_file_exists "$CALLS_DIR/unexpected-curl"
}

@test "CLI-012 non-remote resolution requires Docker before input processing" {
    write_static_stub curl '' 0
    DOCKER="$STUB_BIN/missing-docker"
    export DOCKER

    run_cli --tag-scan=never "registry.example/team/app@sha256:$DIGEST"
    assert_status 1
    assert_stderr_contains 'missing package'
}

@test "CLI-013 remote resolution does not require Docker" {
    write_static_stub curl '' 0
    DOCKER="$STUB_BIN/missing-docker"
    export DOCKER

    run_cli --tag-resolution=remote --tag-scan=never \
        "registry.example/team/app@sha256:$DIGEST"
    assert_status 0
}

@test "CLI-014 missing curl produces the documented dependency error" {
    CURL="$STUB_BIN/missing-curl"
    export CURL

    run_cli --help
    assert_status 1
    assert_stderr_contains 'missing package'
}

@test "CLI-015 Bash older than 4.4 is rejected before dependency checks" {
    [[ -x /bin/bash ]] || skip '/bin/bash unavailable'
    version=$(/bin/bash -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')
    [[ "$version" == 3.* || "$version" == 4.[0-3] ]] || skip '/bin/bash is not older than 4.4'

    run --separate-stderr /bin/bash "$REPO_ROOT/container-image-tags" --help
    assert_status 1
    assert_stderr_contains 'bash v4.4+ required'
}
