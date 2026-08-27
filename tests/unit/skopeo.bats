#!/usr/bin/env bats

load ../test-helper.bash

function load_skopeo {
    load_module skopeo
}

@test "SKOPEO-001 availability and configured login probes use exact commands" {
    load_skopeo
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/skopeo.args"
EOF

    run skopeo_has_registry_credentials registry.example
    assert_status 0
    assert_call_args "$CALLS_DIR/skopeo.args" login --get-login registry.example
}

@test "SKOPEO-002 raw manifest bytes feed manifest-digest without reserialization" {
    load_skopeo
    export RAW_MANIFEST='{"schemaVersion":2, "exact spacing": true}'
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/skopeo.args"
if [[ "$1" == manifest-digest ]]; then
    body=$(cat)
    printf '%s' "$body" >"$CALLS_DIR/manifest.stdin"
    printf '%s\n' sha256:calculated
else
    printf '%s' "$RAW_MANIFEST"
fi
EOF

    run skopeo_digest_for_tag registry.example/app:stable
    assert_status 0
    assert_output_exact sha256:calculated
    [[ $(<"$CALLS_DIR/manifest.stdin") == "$RAW_MANIFEST" ]]
}

@test "SKOPEO-003 Darwin inspect paths add override-os linux exactly once" {
    OSTYPE=darwin24
    load_skopeo
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/skopeo.args"
if [[ "$1" == manifest-digest ]]; then cat >/dev/null; printf '%s\n' sha256:value; else printf '{}'; fi
EOF

    run skopeo_digest_for_tag registry.example/app:stable
    assert_status 0
    args=$(tr '\0' '\n' <"$CALLS_DIR/skopeo.args")
    [[ $(grep -c -- '--override-os' <<<"$args") -eq 1 ]]
    [[ "$args" == *$'--override-os\nlinux'* ]]
}

@test "SKOPEO-004 non-Darwin inspect omits platform override" {
    OSTYPE=linux-gnu
    load_skopeo
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/skopeo.args"
if [[ "$1" == manifest-digest ]]; then cat >/dev/null; printf '%s\n' sha256:value; else printf '{}'; fi
EOF

    run skopeo_digest_for_tag registry.example/app:stable
    assert_status 0
    ! grep -aFq -- '--override-os' "$CALLS_DIR/skopeo.args"
}

@test "SKOPEO-005 inspect errors map denial not-found and unavailable" {
    load_skopeo
    for pair in 'unauthorized 3' 'manifest_unknown 1' 'network_failure 2'; do
        set -- $pair
        export SKOPEO_ERROR="${1//_/ }"
        write_stub skopeo <<'EOF'
if [[ "$1" == manifest-digest ]]; then cat >/dev/null; exit 1; fi
printf '%s\n' "$SKOPEO_ERROR" >&2
exit 1
EOF
        run skopeo_digest_for_tag_with_status registry.example/app:stable
        assert_status "$2"
    done
}

@test "SKOPEO-006 list-tags runs once and candidates use the shared pool" {
    load_skopeo
    registry_tag_scan=all
    registry_direct_tag=
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/skopeo.args"
printf '%s\n' '{"Tags":["a","b"]}'
EOF
    function skopeo_expensive_scan_preflight { return 0; }
    function tags_by_digest_with_rolling_pool {
        local -n received="$3"
        printf '%s\n' "${received[*]}" >"$CALLS_DIR/candidates"
    }

    run skopeo_tags_by_digest registry.example/app sha256:value
    assert_status 0
    [[ $(<"$CALLS_DIR/candidates") == 'a b' ]]
    [[ $(grep -ao 'list-tags' "$CALLS_DIR/skopeo.args" | wc -l) -eq 1 ]]
}

@test "SKOPEO-007 any mode schedules floating tags until a durable match" {
    load_skopeo
    registry_tag_scan=any
    registry_direct_tag=latest
    write_stub skopeo <<'EOF'
printf '%s\n' '{"Tags":["latest","1.2","1.2.3","1.3.0"]}'
EOF
    function skopeo_expensive_scan_preflight { return 0; }
    function tags_by_digest_with_rolling_pool {
        local -n received="$3"
        printf '%s\n' "${received[*]}"
    }

    run skopeo_tags_by_digest registry.example/app sha256:value
    assert_status 0
    assert_output_exact 'latest 1.2 1.2.3 1.3.0'
}

@test "SKOPEO-008 lazy authfiles are isolated mode 0600 files" {
    load_skopeo
    skopeo_prepare_lazy_auth

    assert_file_mode "$skopeo_anonymous_authfile" 600
    assert_file_mode "$skopeo_session_authfile" 600
    [[ $(<"$skopeo_anonymous_authfile") == '{"auths":{}}' ]]
    [[ $(<"$skopeo_session_authfile") == '{"auths":{}}' ]]
    [[ "$skopeo_anonymous_authfile" != "$skopeo_session_authfile" ]]
    skopeo_cleanup_lazy_auth
}

@test "SKOPEO-009 lazy direct auth follows anonymous configured and provider order" {
    load_skopeo
    skopeo_anonymous_authfile=anonymous
    skopeo_session_authfile=session
    function skopeo_session_has_registry { printf '%s\n' session-check >>"$CALLS_DIR/order"; return 1; }
    function skopeo_digest_for_tag_with_status {
        printf 'inspect:%s\n' "${2:-configured}" >>"$CALLS_DIR/order"
        [[ "${2-}" != session ]] || { printf '%s\n' sha256:success; return 0; }
        return "$LOOKUP_DENIED"
    }
    function skopeo_has_registry_credentials { printf '%s\n' configured-check >>"$CALLS_DIR/order"; return 0; }
    function provider_auth { printf '%s\n' provider-auth >>"$CALLS_DIR/order"; return 0; }

    run --separate-stderr skopeo_digest_for_tag_with_lazy_auth registry.example registry.example/app:stable provider_auth
    assert_status 0
    assert_output_exact sha256:success
    assert_stderr_contains 'Using configured registry credentials'
    [[ $(<"$CALLS_DIR/order") == $'session-check\ninspect:anonymous\nconfigured-check\ninspect:configured\nprovider-auth\ninspect:session' ]]
}

@test "SKOPEO-010 not-found does not acquire credentials" {
    load_skopeo
    skopeo_anonymous_authfile=anonymous
    skopeo_session_authfile=session
    function skopeo_session_has_registry { return 1; }
    function skopeo_digest_for_tag_with_status { return "$LOOKUP_NOT_FOUND"; }
    function skopeo_has_registry_credentials { : >"$CALLS_DIR/configured"; return 0; }
    function provider_auth { : >"$CALLS_DIR/provider"; }

    run skopeo_digest_for_tag_with_lazy_auth registry.example registry.example/app:absent provider_auth
    assert_status "$LOOKUP_NOT_FOUND"
    refute_file_exists "$CALLS_DIR/configured"
    refute_file_exists "$CALLS_DIR/provider"
}

@test "SKOPEO-011 cleanup removes both authfiles" {
    load_skopeo
    skopeo_prepare_lazy_auth
    anonymous="$skopeo_anonymous_authfile"
    session="$skopeo_session_authfile"
    skopeo_cleanup_lazy_auth
    refute_file_exists "$anonymous"
    refute_file_exists "$session"
}

@test "SKOPEO-012 duration formatting covers seconds minutes and mixed values" {
    load_skopeo
    run skopeo_format_estimated_duration 59
    assert_output_exact 59s
    run skopeo_format_estimated_duration 120
    assert_output_exact 2m
    run skopeo_format_estimated_duration 125
    assert_output_exact '2m 5s'
}

@test "SKOPEO-013 expensive interactive scan warns and continues" {
    load_skopeo
    function is_interactive_session { return 0; }
    registry_tag_scan=all

    run --separate-stderr registry_expensive_scan_preflight Skopeo repo 1000 1 2
    assert_status 0
    assert_stderr_contains 'Continuing because this is an interactive run'
}

@test "SKOPEO-014 expensive non-interactive scan stops before work" {
    load_skopeo
    function is_interactive_session { return 1; }
    registry_tag_scan=all

    run --separate-stderr registry_expensive_scan_preflight Skopeo repo 1000 1 2
    assert_status "$LOOKUP_STOPPED"
    assert_stderr_contains 'Rerun with --allow-expensive-scan'
}

@test "SKOPEO-015 allow-expensive-scan overrides only the preflight guard" {
    load_skopeo
    function is_interactive_session { return 1; }
    registry_tag_scan=all
    opt_allow_expensive_scan=1

    run --separate-stderr registry_expensive_scan_preflight Skopeo repo 1000 1 2
    assert_status 0
    assert_stderr_contains '--allow-expensive-scan was specified'
}

@test "SKOPEO-016 below-threshold scans emit no advisory" {
    load_skopeo
    function is_interactive_session { return 1; }
    registry_tag_scan=all

    run --separate-stderr registry_expensive_scan_preflight Skopeo repo 8 8 1
    assert_status 0
    assert_stderr_exact ''
}
