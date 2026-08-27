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

@test "GHCR-003 newest matching package version wins across paginated arrays" {
    load_ghcr
    export GH_DIGEST="$DIGEST"
    write_stub gh <<'EOF'
printf '[{"name":"%s","created_at":"2025-01-01T00:00:00Z","metadata":{"container":{"tags":["old"]}}}]\n' "$GH_DIGEST"
printf '[{"name":"%s","created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":["new"]}}}]\n' "$GH_DIGEST"
EOF

    run ghcr_package_version owner/app digest "$DIGEST"
    assert_status 0
    assert_valid_json
    assert_json '.metadata.container.tags == ["new"]'
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

@test "GHCR-007 never policy delegates direct lookup to public OCI" {
    load_ghcr
    opt_credential_policy=never
    function oci_digest_for_tag_anonymously {
        printf '%s\0' "$@" >"$CALLS_DIR/oci"
        printf '%s\n' "$DIGEST"
    }
    function ghcr_package_version_by_tag { : >"$CALLS_DIR/packages"; return 0; }

    run ghcr_digest_for_tag owner/app stable
    assert_status 0
    assert_output_exact "$DIGEST"
    assert_call_args "$CALLS_DIR/oci" ghcr.io owner/app stable
    refute_file_exists "$CALLS_DIR/packages"
}

@test "GHCR-008 require policy skips public OCI and uses Packages" {
    load_ghcr
    opt_credential_policy=require
    function oci_digest_for_tag_anonymously { : >"$CALLS_DIR/oci"; return 0; }
    function ghcr_package_version_by_tag {
        printf '{"name":"%s"}\n' "$DIGEST"
    }

    run ghcr_digest_for_tag owner/app stable
    assert_status 0
    assert_output_exact "$DIGEST"
    refute_file_exists "$CALLS_DIR/oci"
}

@test "GHCR-009 unavailable public OCI changes backend without authorizing credentials" {
    load_ghcr
    function oci_digest_for_tag_anonymously { printf '%s\n' oci >>"$CALLS_DIR/order"; return "$LOOKUP_UNAVAILABLE"; }
    function ghcr_package_version_by_tag { printf '%s\n' packages >>"$CALLS_DIR/order"; return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_is_available { return 0; }
    function skopeo_digest_for_tag_with_access_policy { printf '%s\n' skopeo >>"$CALLS_DIR/order"; printf '%s\n' "$DIGEST"; }

    run --separate-stderr ghcr_digest_for_tag owner/app stable
    assert_status 0
    assert_output_exact "$DIGEST"
    [[ $(<"$CALLS_DIR/order") == $'oci\nskopeo' ]]
}

@test "GHCR-014 stopped anonymous lookup never invokes a fallback" {
    load_ghcr
    function oci_digest_for_tag_anonymously { return "$LOOKUP_STOPPED"; }
    function ghcr_package_version_by_tag { : >"$CALLS_DIR/packages"; }
    function skopeo_digest_for_tag { : >"$CALLS_DIR/skopeo"; }

    run ghcr_digest_for_tag owner/app stable
    assert_status "$LOOKUP_STOPPED"
    refute_file_exists "$CALLS_DIR/packages"
    refute_file_exists "$CALLS_DIR/skopeo"
}

@test "GHCR-010 Packages reverse result populates tags and provider metadata" {
    load_ghcr
    registry_tag_scan=all; registry_direct_tag=stable
    registry_tags=; registry_metadata=; registry_lookup_backend=; registry_lookup_result=completed
    function ghcr_package_version_by_digest {
        printf '{"name":"%s","created_at":"2026-01-01","metadata":{"container":{"tags":["stable","v1"]}}}\n' "$DIGEST"
    }

    ghcr_tags_by_digest owner/app "$DIGEST" ghcr.io/owner/app
    [[ "$registry_lookup_backend" == github-packages-api ]]
    [[ "$registry_tags" == $'stable\nv1' ]]
    "$SYSTEM_JQ" -e '.name == "'"$DIGEST"'"' >/dev/null <<<"$registry_metadata"
}

@test "GHCR-016 Packages any retains matches through the first durable tag" {
    load_ghcr
    registry_tag_scan=any; registry_direct_tag=latest
    registry_direct_tag_confirmed=1
    registry_tags=; registry_metadata=; registry_lookup_backend=; registry_lookup_result=completed
    function ghcr_package_version_by_digest {
        printf '{"name":"%s","metadata":{"container":{"tags":["latest","1.796","1.796.0"]}}}\n' "$DIGEST"
    }

    ghcr_tags_by_digest owner/app "$DIGEST" ghcr.io/owner/app
    [[ "$registry_tags" == $'latest\n1.796\n1.796.0' ]]
}

@test "GHCR-017 if-faster any uses an OCI tag sample before Packages pagination" {
    load_ghcr
    registry_tag_scan=any; registry_direct_tag=17.6; registry_direct_tag_confirmed=1
    registry_tags=; registry_lookup_backend=; registry_lookup_result=completed
    function oci_list_tags_anonymously {
        [[ "$3" == sample ]]
        oci_direct_tag_durable=1
    }
    function ghcr_package_version_by_digest { : >"$CALLS_DIR/packages"; }

    ghcr_tags_by_digest owner/app "$DIGEST" ghcr.io/owner/app
    [[ "$registry_tags" == 17.6 ]]
    [[ "$registry_lookup_backend" == oci-registry-api ]]
    refute_file_exists "$CALLS_DIR/packages"
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

@test "GHCR-012 fallback choice dispatches generic OCI and skip" {
    load_ghcr
    registry_tag_scan=all; registry_direct_tag=; registry_lookup_result=completed
    function ghcr_package_version_by_digest { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_has_registry_credentials { return 1; }
    function choose_ghcr_fallback { printf '%s\n' anonymous; }
    function oci_tags_by_digest_anonymously {
        printf '%s\0' "$@" >"$CALLS_DIR/oci"
        printf '%s\n' found
    }
    registry_tags=; registry_metadata=; registry_lookup_backend=
    ghcr_tags_by_digest owner/app "$DIGEST" ghcr.io/owner/app
    [[ "$registry_lookup_backend" == oci-registry-api ]]
    [[ "$registry_tags" == found ]]
    assert_call_args "$CALLS_DIR/oci" ghcr.io owner/app "$DIGEST"

    function choose_ghcr_fallback { printf '%s\n' skip; }
    function oci_tags_by_digest_anonymously { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_is_available { return 1; }
    skip_input=
    registry_tags=; registry_metadata=; registry_lookup_backend=
    ghcr_tags_by_digest owner/app "$DIGEST" ghcr.io/owner/app
    [[ -n "$skip_input" ]]
}

@test "GHCR-013 a skipped lookup does not suppress the next result" {
    load_ghcr
    registry_tag_scan=all; registry_direct_tag=
    function ghcr_package_version_by_digest { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_has_registry_credentials { return 1; }
    function choose_ghcr_fallback { printf '%s\n' skip; }

    skip_input=
    registry_tags=; registry_metadata=; registry_lookup_backend=; registry_lookup_result=completed
    ghcr_tags_by_digest owner/app "$DIGEST" ghcr.io/owner/app
    [[ -n "$skip_input" ]]

    skip_input=
    function choose_ghcr_fallback { printf '%s\n' anonymous; }
    function oci_tags_by_digest_anonymously { printf '%s\n' next-result; }
    registry_tags=; registry_metadata=; registry_lookup_backend=; registry_lookup_result=completed
    ghcr_tags_by_digest owner/next "$DIGEST" ghcr.io/owner/next
    [[ -z "$skip_input" && "$registry_tags" == next-result ]]
}
