#!/usr/bin/env bats

load ../test-helper.bash

function load_policy_engine {
    load_common
    # shellcheck source=../../lib/policy-engine.sh
    source "$REPO_ROOT/lib/policy-engine.sh"
    declare -gA policy_request=() policy_result=()
    declare -ga policy_attempt_ids=()
    declare -gA policy_attempt_callback=() policy_attempt_backend=()
    declare -gA policy_attempt_access=() policy_attempt_cost=()
    declare -gA policy_attempt_authoritative=() policy_attempt_available=()
    declare -gA policy_attempt_sequence=() policy_attempt_finished=()
    policy_request[operation]=direct
}

function record_attempt {
    local id="$1"
    local status="$2"
    local result_name="$4"
    local -n result_ref="$result_name"

    printf '%s\n' "$id" >>"$CALLS_DIR/order"
    if (( status == LOOKUP_SUCCEEDED )); then
        result_ref[digest]="sha256:$id"
    fi
    return "$status"
}

function attempt_public_denied { record_attempt public "$LOOKUP_DENIED" "$@"; }
function attempt_public_unavailable { record_attempt public "$LOOKUP_UNAVAILABLE" "$@"; }
function attempt_public_not_found { record_attempt public "$LOOKUP_NOT_FOUND" "$@"; }
function attempt_public_stopped { record_attempt public "$LOOKUP_STOPPED" "$@"; }
function attempt_public_success { record_attempt public "$LOOKUP_SUCCEEDED" "$@"; }
function attempt_public_compat_success { record_attempt compatibility "$LOOKUP_SUCCEEDED" "$@"; }
function attempt_compat_success { record_attempt compatibility "$LOOKUP_SUCCEEDED" "$@"; }
function attempt_fast_success { record_attempt fast "$LOOKUP_SUCCEEDED" "$@"; }
function attempt_credential_success { record_attempt credential "$LOOKUP_SUCCEEDED" "$@"; }
function attempt_interactive_success { record_attempt interactive "$LOOKUP_SUCCEEDED" "$@"; }

@test "POLICY-ENGINE-001 if-required unlocks credentials only after public denial" {
    load_policy_engine
    opt_credential_policy=if-required
    policy_add_attempt public attempt_public_denied public-api "$POLICY_ACCESS_PUBLIC" 10
    policy_add_attempt credential attempt_credential_success private-api "$POLICY_ACCESS_CREDENTIAL" 5

    policy_execute_lookup policy_request policy_result
    [[ $(cat "$CALLS_DIR/order") == $'public\ncredential' ]]
    [[ "${policy_result[backend]}" == private-api ]]
}

@test "POLICY-ENGINE-002 unavailable changes public backend without authorizing credentials" {
    load_policy_engine
    opt_credential_policy=if-required
    policy_add_attempt public attempt_public_unavailable public-api "$POLICY_ACCESS_PUBLIC" 10
    policy_add_attempt credential attempt_credential_success private-api "$POLICY_ACCESS_CREDENTIAL" 15
    policy_add_attempt compatibility attempt_compat_success compatibility-api "$POLICY_ACCESS_PUBLIC" 20

    policy_execute_lookup policy_request policy_result
    [[ $(cat "$CALLS_DIR/order") == $'public\ncompatibility' ]]
}

@test "POLICY-ENGINE-003 if-faster prefers a declared fast credential mechanism" {
    load_policy_engine
    opt_credential_policy=if-faster
    policy_add_attempt public attempt_public_success public-api "$POLICY_ACCESS_PUBLIC" 10
    policy_add_attempt fast attempt_fast_success fast-api "$POLICY_ACCESS_FAST_CREDENTIAL" 5

    policy_execute_lookup policy_request policy_result
    [[ $(cat "$CALLS_DIR/order") == fast ]]
}

@test "POLICY-ENGINE-004 never excludes every credential class" {
    load_policy_engine
    opt_credential_policy=never
    policy_add_attempt fast attempt_fast_success fast-api "$POLICY_ACCESS_FAST_CREDENTIAL" 1
    policy_add_attempt credential attempt_credential_success private-api "$POLICY_ACCESS_CREDENTIAL" 2
    policy_add_attempt public attempt_public_success public-api "$POLICY_ACCESS_PUBLIC" 10

    policy_execute_lookup policy_request policy_result
    [[ $(cat "$CALLS_DIR/order") == public ]]
}

@test "POLICY-ENGINE-005 require excludes public mechanisms" {
    load_policy_engine
    opt_credential_policy=require
    policy_add_attempt public attempt_public_success public-api "$POLICY_ACCESS_PUBLIC" 1
    policy_add_attempt credential attempt_credential_success private-api "$POLICY_ACCESS_CREDENTIAL" 10

    policy_execute_lookup policy_request policy_result
    [[ $(cat "$CALLS_DIR/order") == credential ]]
}

@test "POLICY-ENGINE-006 authoritative not-found is terminal" {
    load_policy_engine
    policy_add_attempt public attempt_public_not_found public-api "$POLICY_ACCESS_PUBLIC" 10
    policy_add_attempt compatibility attempt_compat_success compatibility-api "$POLICY_ACCESS_PUBLIC" 20

    run policy_execute_lookup policy_request policy_result
    assert_status "$LOOKUP_NOT_FOUND"
    [[ $(cat "$CALLS_DIR/order") == public ]]
}

@test "POLICY-ENGINE-007 non-authoritative miss selects another mechanism" {
    load_policy_engine
    policy_add_attempt advisory attempt_public_not_found advisory-api "$POLICY_ACCESS_PUBLIC" 10 0
    policy_add_attempt compatibility attempt_compat_success compatibility-api "$POLICY_ACCESS_PUBLIC" 20

    policy_execute_lookup policy_request policy_result
    [[ $(cat "$CALLS_DIR/order") == $'public\ncompatibility' ]]
}

@test "POLICY-ENGINE-008 stopped is terminal" {
    load_policy_engine
    policy_add_attempt public attempt_public_stopped public-api "$POLICY_ACCESS_PUBLIC" 10
    policy_add_attempt compatibility attempt_compat_success compatibility-api "$POLICY_ACCESS_PUBLIC" 20

    run policy_execute_lookup policy_request policy_result
    assert_status "$LOOKUP_STOPPED"
    [[ $(cat "$CALLS_DIR/order") == public ]]
}

@test "POLICY-ENGINE-009 interactive recovery runs only after denial" {
    load_policy_engine
    function is_interactive_session { return 0; }
    policy_add_attempt public attempt_public_denied public-api "$POLICY_ACCESS_PUBLIC" 10
    policy_add_attempt interactive attempt_interactive_success recovery "$POLICY_ACCESS_INTERACTIVE" 100

    policy_execute_lookup policy_request policy_result
    [[ $(cat "$CALLS_DIR/order") == $'public\ninteractive' ]]
}

@test "POLICY-ENGINE-010 confirmed direct tags are a built-in reverse shortcut" {
    load_policy_engine
    policy_request[operation]=reverse
    policy_request[scan_mode]=any
    policy_request[direct_tag]=latest
    policy_request[direct_tag_confirmed]=1
    policy_add_attempt public attempt_public_success public-api "$POLICY_ACCESS_PUBLIC" 10

    policy_execute_lookup policy_request policy_result
    [[ "${policy_result[backend]}" == direct-tag-check ]]
    [[ "${policy_result[tags]}" == latest ]]
    refute_file_exists "$CALLS_DIR/order"
}

@test "POLICY-ENGINE-011 complete plans leave no process-wide attempt state" {
    load_common
    source "$REPO_ROOT/lib/policy-engine.sh"
    declare -A request=([operation]=direct) result=()
    function register_attempts {
        policy_add_attempt public attempt_public_success public-api \
            "$POLICY_ACCESS_PUBLIC" 10
    }

    policy_build_and_execute_lookup request result register_attempts
    [[ "${result[backend]}" == public-api ]]
    ! declare -p policy_attempt_ids >/dev/null 2>&1
    ! declare -p policy_attempt_callback >/dev/null 2>&1
}

@test "POLICY-ENGINE-012 public denial does not suppress another public mechanism" {
    load_policy_engine
    policy_add_attempt public attempt_public_denied public-api "$POLICY_ACCESS_PUBLIC" 10
    policy_add_attempt compatibility attempt_public_compat_success \
        compatibility-api "$POLICY_ACCESS_PUBLIC" 20

    policy_execute_lookup policy_request policy_result
    [[ $(cat "$CALLS_DIR/order") == $'public\ncompatibility' ]]
    [[ "${policy_result[backend]}" == compatibility-api ]]
}

@test "POLICY-ENGINE-013 if-required exhausts public mechanisms after denial" {
    load_policy_engine
    opt_credential_policy=if-required
    policy_add_attempt public attempt_public_denied public-api "$POLICY_ACCESS_PUBLIC" 10
    policy_add_attempt credential attempt_credential_success private-api \
        "$POLICY_ACCESS_CREDENTIAL" 5
    policy_add_attempt compatibility attempt_public_compat_success \
        compatibility-api "$POLICY_ACCESS_PUBLIC" 20

    policy_execute_lookup policy_request policy_result
    [[ $(cat "$CALLS_DIR/order") == $'public\ncompatibility' ]]
    [[ "${policy_result[backend]}" == compatibility-api ]]
}
