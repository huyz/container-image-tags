#!/usr/bin/env bats

load ../test-helper.bash

DIGEST=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

function load_ghcr {
    load_common
    # shellcheck source=../../lib/skopeo.sh
    source "$REPO_ROOT/lib/skopeo.sh"
    # shellcheck source=../../lib/oci.sh
    source "$REPO_ROOT/lib/oci.sh"
    # shellcheck source=../../lib/ghcr.sh
    source "$REPO_ROOT/lib/ghcr.sh"
    # shellcheck source=../../lib/policy-engine.sh
    source "$REPO_ROOT/lib/policy-engine.sh"
}

function ghcr_adaptive_lookup {
    local repository="${1:-owner/app}"
    local digest="${2:-$DIGEST}"
    local -A request=(
        [operation]=reverse
        [repository]="$repository"
        [digest]="$digest"
        [display_repository]="ghcr.io/$repository"
        [direct_tag]="${registry_direct_tag-}"
        [scan_mode]="${registry_tag_scan-}"
    ) result=()
    local status

    opt_credential_policy=if-faster
    policy_plan_reset
    policy_add_attempt ghcr-packages-adaptive \
        ghcr_policy_attempt_adaptive_probe github-packages-api \
        "$POLICY_ACCESS_FAST_CREDENTIAL" 10
    if policy_execute_lookup request result; then
        status=$LOOKUP_SUCCEEDED
    else
        status=$?
    fi
    registry_tags="${result[tags]-}"
    registry_metadata="${result[metadata]-}"
    registry_lookup_backend="${result[backend]-}"
    return "$status"
}

@test "GHCR-001 package names are URL encoded in the Packages API endpoint" {
    load_ghcr
    write_stub gh <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/gh.args"
printf '%s\n' '[]'
EOF

    run ghcr_package_version 'owner/team/app' digest "$DIGEST"
    assert_status "$LOOKUP_NOT_FOUND"
    args=$(tr '\0' '\n' <"$CALLS_DIR/gh.args")
    [[ "$args" == *'owner/packages/container/team%2Fapp/versions?per_page=100'* ]]
}

@test "GHCR-002 organization and user endpoints are both tried" {
    load_ghcr
    write_stub gh <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/gh.args"
printf '%s\n' '[]'
EOF

    run ghcr_package_version owner/app digest "$DIGEST"
    assert_status "$LOOKUP_NOT_FOUND"
    args=$(tr '\0' '\n' <"$CALLS_DIR/gh.args")
    [[ "$args" == *'/orgs/owner/packages/container/app/versions?per_page=100'* ]]
    [[ "$args" == *'/users/owner/packages/container/app/versions?per_page=100'* ]]
}

@test "GHCR-003 incremental Packages lookup stops on the first matching page" {
    load_ghcr
    export GH_DIGEST="$DIGEST"
    write_stub gh <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/gh.args"
endpoint="${!#}"
if [[ "$endpoint" == *'page=1' ]]; then
    base="${endpoint%&page=*}"
    printf 'HTTP/2 200\r\nLink: <%s&page=2>; rel="next", <%s&page=2>; rel="last"\r\n\r\n' "$base" "$base"
    printf '[{"name":"sha256:other","metadata":{"container":{"tags":[]}}}]\n'
else
    printf '[{"name":"%s","metadata":{"container":{"tags":["found"]}}}]\n' "$GH_DIGEST"
fi
EOF

    run ghcr_package_version owner/app digest "$DIGEST"
    assert_status 0
    assert_valid_json
    assert_json '.metadata.container.tags == ["found"]'
    [[ $(grep -ao -- '--include' "$CALLS_DIR/gh.args" | wc -l) -eq 2 ]]
    ! grep -aFq -- '--paginate' "$CALLS_DIR/gh.args"
}

@test "GHCR-004 Packages API selects exact current tag membership" {
    load_ghcr
    write_stub gh <<'EOF'
printf '%s\n' '[{"name":"sha256:one","created_at":"2026-01-01","metadata":{"container":{"tags":["stable"]}}},{"name":"sha256:two","created_at":"2026-01-02","metadata":{"container":{"tags":["stables"]}}}]'
EOF

    run ghcr_package_version owner/app tag stable
    assert_status 0
    assert_json '.name == "sha256:one"'
}

@test "GHCR-005 reachable Packages API with no match is not found" {
    load_ghcr
    write_static_stub gh '[]' 0

    run ghcr_package_version owner/app digest "$DIGEST"
    assert_status "$LOOKUP_NOT_FOUND"
}

@test "GHCR-006 unavailable gh command returns unavailable" {
    load_ghcr
    GH="$STUB_BIN/missing-gh"

    run ghcr_package_version owner/app digest "$DIGEST"
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "GHCR-011 active untagged package metadata prints the documented note" {
    load_ghcr
    registry_lookup_result=completed
    registry_lookup_backend=github-packages-api
    registry_metadata='{"created_at":"2026-01-01","updated_at":"2026-01-02","metadata":{"container":{"tags":[]}}}'

    run ghcr_print_metadata
    assert_status 0
    assert_output_contains 'GHCR package info:'
    assert_output_contains 'still an active GHCR package version, but no current tag points to it'
}

@test "GHCR-019 adaptive lookup finishes from the first Packages page" {
    load_ghcr
    registry_tag_scan=all; registry_direct_tag=
    registry_tags=; registry_metadata=; registry_lookup_backend=
    function ghcr_probe_package_version_by_digest {
        ghcr_package_probe_match='{"name":"sha256:match","metadata":{"container":{"tags":["stable"]}}}'
        ghcr_package_probe_complete=
    }
    function oci_list_tags_anonymously { : >"$CALLS_DIR/oci"; }

    ghcr_adaptive_lookup
    [[ "$registry_lookup_backend" == github-packages-api ]]
    [[ "$registry_tags" == stable ]]
    refute_file_exists "$CALLS_DIR/oci"
}

@test "GHCR-020 adaptive lookup selects OCI when package continuation costs more" {
    load_ghcr
    registry_tag_scan=all; registry_direct_tag=
    registry_tags=; registry_metadata=; registry_lookup_backend=
    function ghcr_probe_package_version_by_digest {
        ghcr_package_probe_match=
        ghcr_package_probe_complete=
        ghcr_package_probe_endpoint_base=/endpoint
        ghcr_package_probe_next=2
        ghcr_package_probe_last=100
        ghcr_package_probe_elapsed_ms=1000
    }
    function oci_list_tags_anonymously {
        oci_listed_tags=$(printf 'tag-%d\n' {1..8})
        oci_direct_tag_durable=
    }
    function oci_tags_by_digest_from_list {
        printf '%s\n' tag-8
    }
    function ghcr_continue_package_version_by_digest { : >"$CALLS_DIR/packages"; }

    ghcr_adaptive_lookup 2>"$TEST_ROOT/stderr"
    grep -Fq 'Selecting the anonymous OCI scan' "$TEST_ROOT/stderr"
    [[ "$registry_lookup_backend" == oci-registry-api ]]
    [[ "$registry_tags" == tag-8 ]]
    refute_file_exists "$CALLS_DIR/packages"
}

@test "GHCR-021 adaptive lookup selects incremental Packages when it costs less" {
    load_ghcr
    registry_tag_scan=all; registry_direct_tag=
    registry_tags=; registry_metadata=; registry_lookup_backend=
    function ghcr_probe_package_version_by_digest {
        ghcr_package_probe_match=
        ghcr_package_probe_complete=
        ghcr_package_probe_endpoint_base=/endpoint
        ghcr_package_probe_next=2
        ghcr_package_probe_last=2
        ghcr_package_probe_elapsed_ms=1
    }
    function oci_list_tags_anonymously {
        oci_listed_tags=$(printf 'tag-%03d\n' {1..100})
        oci_direct_tag_durable=
    }
    function oci_tags_by_digest_from_list { : >"$CALLS_DIR/oci-scan"; }
    function ghcr_continue_package_version_by_digest {
        printf '{"name":"%s","metadata":{"container":{"tags":["release"]}}}\n' "$DIGEST"
    }

    ghcr_adaptive_lookup
    [[ "$registry_lookup_backend" == github-packages-api ]]
    [[ "$registry_tags" == release ]]
    refute_file_exists "$CALLS_DIR/oci-scan"
}

@test "GHCR-022 adaptive package refusal remains terminal" {
    load_ghcr
    registry_tag_scan=all; registry_direct_tag=
    function ghcr_probe_package_version_by_digest {
        ghcr_package_probe_match=
        ghcr_package_probe_complete=
        ghcr_package_probe_endpoint_base=/endpoint
        ghcr_package_probe_next=2
        ghcr_package_probe_last=1000
        ghcr_package_probe_elapsed_ms=1000
    }
    function oci_list_tags_anonymously { return "$LOOKUP_UNAVAILABLE"; }
    function registry_expensive_work_preflight { return "$LOOKUP_STOPPED"; }
    function ghcr_continue_package_version_by_digest { : >"$CALLS_DIR/packages"; }

    run ghcr_adaptive_lookup
    assert_status "$LOOKUP_STOPPED"
    refute_file_exists "$CALLS_DIR/packages"
}

@test "GHCR-023 failed OCI inventory retains a viable Packages continuation" {
    load_ghcr
    registry_tag_scan=all; registry_direct_tag=
    registry_tags=; registry_metadata=; registry_lookup_backend=
    function ghcr_probe_package_version_by_digest {
        ghcr_package_probe_match=
        ghcr_package_probe_complete=
        ghcr_package_probe_endpoint_base=/endpoint
        ghcr_package_probe_next=2
        ghcr_package_probe_last=2
        ghcr_package_probe_elapsed_ms=1
    }
    function oci_list_tags_anonymously { return "$LOOKUP_STOPPED"; }
    function ghcr_continue_package_version_by_digest {
        printf '{"name":"%s","metadata":{"container":{"tags":["release"]}}}\n' "$DIGEST"
    }

    ghcr_adaptive_lookup
    [[ "$registry_lookup_backend" == github-packages-api ]]
    [[ "$registry_tags" == release ]]
}
