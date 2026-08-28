#!/usr/bin/env bats

load ../test-helper.bash

function lookup_from_tag {
    local tag="$2"
    case "$tag" in
    match | match-slow | 1.2 | 1.2.3)
        [[ "$tag" != match-slow ]] || sleep 0.08
        printf '%s\n' 'sha256:wanted'
        ;;
    terminal) return 4 ;;
    failed) return 2 ;;
    slow)
        sleep 0.12
        printf '%s\n' 'sha256:other'
        ;;
    *)
        printf '%s\n' 'sha256:other'
        ;;
    esac
}

function lookup_and_log {
    printf '%s\n' "$2" >>"$CALLS_DIR/lookups"
    lookup_from_tag "$@"
}

@test "COMMON-001 named lookup statuses retain their public values" {
    load_common

    [[ "$LOOKUP_SUCCEEDED" -eq 0 ]]
    [[ "$LOOKUP_NOT_FOUND" -eq 1 ]]
    [[ "$LOOKUP_UNAVAILABLE" -eq 2 ]]
    [[ "$LOOKUP_DENIED" -eq 3 ]]
    [[ "$LOOKUP_STOPPED" -eq 4 ]]
}

@test "COMMON-002 successful helpers return zero and write only their value" {
    load_common

    run --separate-stderr lookup_from_tag repo match
    assert_status "$LOOKUP_SUCCEEDED"
    assert_output_exact 'sha256:wanted'
    assert_stderr_exact ''
}

@test "COMMON-003 terminal helper status is distinguishable from unavailable" {
    load_common

    run lookup_from_tag repo terminal
    assert_status "$LOOKUP_STOPPED"
}

@test "COMMON-004 diagnostic helpers honor gating prefixes and streams" {
    load_common

    run --separate-stderr debug hidden
    assert_status 0
    assert_stderr_exact ''

    opt_debug=1
    run --separate-stderr debug detail
    assert_status 0
    assert_stderr_contains 'container-image-tags: 🔧 DEBUG: detail'

    run --separate-stderr notice decision
    assert_status 0
    assert_stderr_exact 'NOTICE: decision'

    run --separate-stderr warn caution
    assert_status 0
    assert_stderr_contains 'container-image-tags: ⚠️ WARNING: caution'
}

@test "COMMON-005 short interactive choices and the default normalize exactly" {
    load_common

    run remote_tag_scan_choice 1
    assert_status 0
    assert_output_exact any
    run remote_tag_scan_choice d
    assert_status 0
    assert_output_exact any-durable
    run remote_tag_scan_choice a
    assert_status 0
    assert_output_exact all
    run remote_tag_scan_choice ''
    assert_status 0
    assert_output_exact none
    run remote_tag_scan_choice n
    assert_status 0
    assert_output_exact none
}

@test "COMMON-006 choice helper fails without an interactive terminal" {
    load_common
    function is_interactive_session { return 1; }

    run --separate-stderr choose_remote_tag_scan
    assert_status 1
    assert_output_exact ''
    assert_stderr_exact ''
}

@test "COMMON-007 uppercase and long-form choices normalize to documented actions" {
    load_common

    for pair in 'ANY any' 'Any any' \
            'Any-Durable any-durable' 'Durable any-durable' \
            'D any-durable' 'All all' 'NO none' 'N none' 'A all'; do
        set -- $pair
        run remote_tag_scan_choice "$1"
        assert_status 0
        assert_output_exact "$2"
    done
    run remote_tag_scan_choice unexpected
    assert_status 1
    assert_output_exact ''
}

@test "COMMON-008 durable heuristic infers the most precise recurring semver shape" {
    load_common
    tags=$'latest\n1.796\n1.796.0\n1.795\n1.795.0\ndev'

    run durable_semver_precision_from_tags "$tags"
    assert_status 0
    assert_output_exact 3
    tag_is_assumed_durable 1.796.0 3
    ! tag_is_assumed_durable 1.796 3
    ! tag_is_assumed_durable latest 3
}

@test "COMMON-009 durable heuristic supports repositories with two-part releases" {
    load_common
    tags=$'stable\n17.5\n17.6\n17.7'

    run assumed_durable_tags "$tags"
    assert_status 0
    assert_output_exact $'17.5\n17.6\n17.7'
}

@test "COMMON-010 standalone direct-tag classification is deliberately conservative" {
    load_common

    tag_is_assumed_durable v1.2.3
    tag_is_assumed_durable 2026-08-27
    tag_is_assumed_durable a1b2c3d4e5f6
    ! tag_is_assumed_durable 1.2
    ! tag_is_assumed_durable main
}

@test "COMMON-011 any-durable includes confirmed local tag and incidental floating matches" {
    load_common
    registry_tag_scan=any-durable
    registry_direct_tag=latest
    registry_direct_tag_confirmed=1

    run select_matching_tags_for_scan \
        $'1.796\n1.796.0\n1.797.0' \
        $'latest\n1.796\n1.796.0\n1.797.0'
    assert_status 0
    assert_output_exact $'latest\n1.796\n1.796.0'
}

@test "COMMON-012 any returns a confirmed floating tag or the first provider match" {
    load_common
    registry_tag_scan=any
    registry_direct_tag=latest
    registry_direct_tag_confirmed=1

    run select_matching_tags_for_scan $'1.796\n1.796.0'
    assert_status 0
    assert_output_exact latest

    registry_direct_tag_confirmed=
    run select_matching_tags_for_scan $'stable\n1.796.0'
    assert_status 0
    assert_output_exact stable
}

@test "POOL-001 rolling pool never exceeds its configured worker cap" {
    load_common
    registry_tag_scan=all
    candidates=(one two three four five six)

    function counted_lookup {
        local lock="$TEST_ROOT/counter.lock"
        while ! mkdir "$lock" 2>/dev/null; do sleep 0.005; done
        local current=0 maximum=0
        [[ ! -f "$TEST_ROOT/current" ]] || current=$(<"$TEST_ROOT/current")
        [[ ! -f "$TEST_ROOT/maximum" ]] || maximum=$(<"$TEST_ROOT/maximum")
        current=$((current + 1))
        printf '%d\n' "$current" >"$TEST_ROOT/current"
        ((current <= maximum)) || printf '%d\n' "$current" >"$TEST_ROOT/maximum"
        rmdir "$lock"
        sleep 0.04
        while ! mkdir "$lock" 2>/dev/null; do sleep 0.005; done
        current=$(<"$TEST_ROOT/current")
        printf '%d\n' "$((current - 1))" >"$TEST_ROOT/current"
        rmdir "$lock"
        printf '%s\n' 'sha256:other'
    }

    run tags_by_digest_with_rolling_pool repo sha256:wanted candidates 2 \
        progress worker counted_lookup 1
    assert_status 0
    [[ $(<"$TEST_ROOT/maximum") -le 2 ]]
}

@test "POOL-002 out-of-order workers still emit matches in candidate order" {
    load_common
    registry_tag_scan=all
    candidates=(match-slow other match)

    run tags_by_digest_with_rolling_pool repo sha256:wanted candidates 3 \
        progress worker lookup_from_tag 1
    assert_status 0
    assert_output_exact $'match-slow\nmatch'
}

@test "POOL-003 any-durable stops scheduling after the first durable match" {
    load_common
    registry_tag_scan=any-durable
    candidates=(1.2.3 slow never-one never-two)

    run lookup_pool_any
    assert_status 0
    assert_output_exact '1.2.3'
    grep -Fxq 1.2.3 "$CALLS_DIR/lookups"
    grep -Fxq slow "$CALLS_DIR/lookups"
    ! grep -Fq never "$CALLS_DIR/lookups"
}

@test "POOL-004 caller-supplied candidate filtering is preserved before scheduling" {
    load_common
    registry_tag_scan=all
    registry_direct_tag=latest
    all_candidates=(latest stable)
    candidates=()
    for tag in "${all_candidates[@]}"; do
        [[ "$tag" == "$registry_direct_tag" ]] || candidates+=("$tag")
    done

    run tags_by_digest_with_rolling_pool repo sha256:wanted candidates 2 \
        progress worker lookup_from_tag 1
    assert_status 0
    [[ ${#candidates[@]} -eq 1 && ${candidates[0]} == stable ]]
}

function lookup_pool_any {
    tags_by_digest_with_rolling_pool repo sha256:wanted candidates 2 \
        progress worker lookup_and_log ''
}

@test "POOL-005 an exhaustive worker failure rejects partial results" {
    load_common
    registry_tag_scan=all
    candidates=(match failed)

    run tags_by_digest_with_rolling_pool repo sha256:wanted candidates 2 \
        progress worker lookup_from_tag 1
    assert_status "$LOOKUP_UNAVAILABLE"
    assert_output_exact 'match'
}

@test "POOL-006 terminal worker status stops scheduling and propagates" {
    load_common
    registry_tag_scan=all
    candidates=(terminal slow never)

    run lookup_pool_terminal
    assert_status "$LOOKUP_STOPPED"
    ! grep -Fxq never "$CALLS_DIR/lookups"
}

function lookup_pool_terminal {
    tags_by_digest_with_rolling_pool repo sha256:wanted candidates 2 \
        progress worker lookup_and_log 1
}

@test "POOL-007 any-durable can succeed after an unrelated worker failure" {
    load_common
    registry_tag_scan=any-durable
    candidates=(failed 1.2.3)

    run tags_by_digest_with_rolling_pool repo sha256:wanted candidates 2 \
        progress worker lookup_from_tag ''
    assert_status 0
    assert_output_exact '1.2.3'
}

@test "POOL-008 empty candidate set starts no workers" {
    load_common
    registry_tag_scan=all
    candidates=()

    run tags_by_digest_with_rolling_pool repo sha256:wanted candidates 8 \
        progress worker lookup_from_tag 1
    assert_status 0
    assert_output_exact ''
}

@test "POOL-009 non-interactive scans emit no spinner" {
    load_common
    function is_interactive_session { return 1; }
    registry_tag_scan=all
    candidates=(other)

    run --separate-stderr tags_by_digest_with_rolling_pool repo sha256:wanted \
        candidates 1 progress worker lookup_from_tag 1
    assert_status 0
    assert_stderr_exact ''
}

@test "POOL-010 interactive scans finish progress with a newline" {
    load_common
    function is_interactive_session { return 0; }
    registry_tag_scan=all
    candidates=(other)

    run --separate-stderr tags_by_digest_with_rolling_pool repo sha256:wanted \
        candidates 1 progress worker lookup_from_tag 1
    assert_status 0
    assert_stderr_contains 'progress... done (1 checked)'
}

@test "POOL-011 reaching zero active workers does not trip strict mode" {
    load_common
    set -e
    registry_tag_scan=all
    candidates=(other)

    run tags_by_digest_with_rolling_pool repo sha256:wanted candidates 1 \
        progress worker lookup_from_tag 1
    assert_status 0
}

@test "POOL-012 normal completion removes scheduler temporary directories" {
    load_common
    registry_tag_scan=all
    candidates=(other)
    before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | sort)

    run tags_by_digest_with_rolling_pool repo sha256:wanted candidates 1 \
        progress worker lookup_from_tag 1
    assert_status 0
    after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | sort)
    [[ "$before" == "$after" ]]
}

@test "POOL-013 any-durable retains floating matches through the first durable match" {
    load_common
    registry_tag_scan=any-durable
    registry_durable_semver_precision=3
    registry_seed_matching_tags=latest
    candidates=(1.2 1.2.3 never)

    run tags_by_digest_with_rolling_pool repo sha256:wanted candidates 1 \
        progress worker lookup_and_log ''
    assert_status 0
    assert_output_exact $'latest\n1.2\n1.2.3'
    ! grep -Fxq never "$CALLS_DIR/lookups"
}

@test "POOL-014 any stops after the first matching floating tag" {
    load_common
    registry_tag_scan=any
    candidates=(1.2 never)

    run tags_by_digest_with_rolling_pool repo sha256:wanted candidates 1 \
        progress worker lookup_and_log ''
    assert_status 0
    assert_output_exact 1.2
    ! grep -Fxq never "$CALLS_DIR/lookups"
}

@test "POOL-015 worker death before completion is detected without hanging" {
    load_common
    registry_tag_scan=all
    candidates=(one)
    function killed_lookup {
        kill -KILL "$BASHPID"
    }

    run tags_by_digest_with_rolling_pool repo sha256:wanted candidates 1 \
        progress worker killed_lookup 1
    assert_status "$LOOKUP_UNAVAILABLE"
}
