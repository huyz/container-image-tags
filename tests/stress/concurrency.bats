#!/usr/bin/env bats

load ../test-helper.bash

function lookup_stress {
    local tag="$2"
    local slow_delay
    case "$((STRESS_ITERATION % 3))" in
    0) slow_delay=0.012 ;;
    1) slow_delay=0.017 ;;
    2) slow_delay=0.022 ;;
    esac
    case "$tag" in
    first) sleep "$slow_delay"; printf '%s\n' sha256:wanted ;;
    second) sleep 0.005; printf '%s\n' sha256:wanted ;;
    *) printf '%s\n' sha256:other ;;
    esac
}

function lookup_any_stress {
    local tag="$2"
    printf '%s\n' "$tag" >>"$CALLS_DIR/iteration.log"
    case "$tag" in
    1.2.3) sleep 0.006; printf '%s\n' sha256:wanted ;;
    slow) sleep 0.02; printf '%s\n' sha256:other ;;
    *) printf '%s\n' sha256:other ;;
    esac
}

function lookup_failure_stress {
    case "$2" in
    match) printf '%s\n' sha256:wanted ;;
    failed) return "$LOOKUP_UNAVAILABLE" ;;
    *) printf '%s\n' sha256:other ;;
    esac
}

function lookup_terminal_stress {
    local tag="$2"
    printf '%s\n' "$tag" >>"$CALLS_DIR/iteration.log"
    case "$tag" in
    terminal) return "$LOOKUP_STOPPED" ;;
    slow) sleep 0.015; printf '%s\n' sha256:other ;;
    *) printf '%s\n' sha256:other ;;
    esac
}

@test "STRESS-001 scheduler preserves ordering over repeated out-of-order runs" {
    load_common
    registry_tag_scan=all
    candidates=(first other second)

    for STRESS_ITERATION in $(seq 1 25); do
        result=$(tags_by_digest_with_rolling_pool repo sha256:wanted candidates 3 \
            progress worker lookup_stress 1)
        [[ "$result" == $'first\nsecond' ]] || {
            printf 'iteration %d produced [%s]\n' "$STRESS_ITERATION" "$result" >&2
            return 1
        }
    done
}

@test "STRESS-002 any mode stops new scheduling over 25 varied runs" {
    load_common
    registry_tag_scan=any
    candidates=(1.2.3 slow never-one never-two)

    for STRESS_ITERATION in $(seq 1 25); do
        : >"$CALLS_DIR/iteration.log"
        result=$(tags_by_digest_with_rolling_pool repo sha256:wanted candidates 2 \
            progress worker lookup_any_stress '')
        [[ "$result" == 1.2.3 ]]
        ! grep -Fq never "$CALLS_DIR/iteration.log"
    done
}

@test "STRESS-003 exhaustive worker failure rejects partial results over 25 runs" {
    load_common
    registry_tag_scan=all
    candidates=(match failed)

    for STRESS_ITERATION in $(seq 1 25); do
        if result=$(tags_by_digest_with_rolling_pool repo sha256:wanted candidates 2 \
                progress worker lookup_failure_stress 1); then
            lookup_status=0
        else
            lookup_status=$?
        fi
        [[ "$lookup_status" -eq "$LOOKUP_UNAVAILABLE" ]]
        [[ "$result" == match ]]
    done
}

@test "STRESS-004 terminal worker stops scheduling and propagates over 25 runs" {
    load_common
    registry_tag_scan=all
    candidates=(terminal slow never)

    for STRESS_ITERATION in $(seq 1 25); do
        : >"$CALLS_DIR/iteration.log"
        if result=$(tags_by_digest_with_rolling_pool repo sha256:wanted candidates 2 \
                progress worker lookup_terminal_stress 1); then
            lookup_status=0
        else
            lookup_status=$?
        fi
        [[ "$lookup_status" -eq "$LOOKUP_STOPPED" ]]
        [[ -z "$result" ]]
        ! grep -Fxq never "$CALLS_DIR/iteration.log"
    done
}
