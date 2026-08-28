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
    opt_credential_policy=require
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

@test "GHCR-016 Packages any-durable retains matches through the first durable tag" {
    load_ghcr
    opt_credential_policy=require
    registry_tag_scan=any-durable; registry_direct_tag=latest
    registry_direct_tag_confirmed=1
    registry_tags=; registry_metadata=; registry_lookup_backend=; registry_lookup_result=completed
    function ghcr_package_version_by_digest {
        printf '{"name":"%s","metadata":{"container":{"tags":["latest","1.796","1.796.0"]}}}\n' "$DIGEST"
    }

    ghcr_tags_by_digest owner/app "$DIGEST" ghcr.io/owner/app
    [[ "$registry_tags" == $'latest\n1.796\n1.796.0' ]]
}

@test "GHCR-017 if-faster any-durable uses an OCI tag sample before Packages pagination" {
    load_ghcr
    registry_tag_scan=any-durable; registry_direct_tag=17.6; registry_direct_tag_confirmed=1
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

@test "GHCR-015 denied direct lookup offers scope refresh after automatic fallbacks" {
    load_ghcr
    write_stub gh <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/gh.args"
EOF
    function oci_digest_for_tag_anonymously {
        printf 'oci\n' >>"$CALLS_DIR/order"
        return "$LOOKUP_DENIED"
    }
    function ghcr_package_version_by_tag {
        printf 'packages\n' >>"$CALLS_DIR/order"
        count=0
        [[ ! -f "$CALLS_DIR/packages.count" ]] || count=$(<"$CALLS_DIR/packages.count")
        count=$((count + 1))
        printf '%d\n' "$count" >"$CALLS_DIR/packages.count"
        (( count > 1 )) || return "$LOOKUP_UNAVAILABLE"
        printf '{"name":"%s"}\n' "$DIGEST"
    }
    function skopeo_is_available { return 0; }
    function skopeo_digest_for_tag_with_access_policy {
        printf 'skopeo\n' >>"$CALLS_DIR/order"
        return "$LOOKUP_DENIED"
    }
    function choose_ghcr_direct_authentication {
        printf 'prompt:%s\n' "$1" >>"$CALLS_DIR/order"
    }
    function ghcr_refresh_authentication {
        printf '%s\0' auth refresh -s read:packages >"$CALLS_DIR/gh.args"
    }

    run ghcr_digest_for_tag owner/app stable
    assert_status 0
    assert_output_exact "$DIGEST"
    [[ $(<"$CALLS_DIR/order") == $'oci\npackages\nskopeo\nprompt:1\npackages' ]]
    assert_call_args "$CALLS_DIR/gh.args" auth refresh -s read:packages
}

@test "GHCR-018 terminal direct fallback result does not prompt for scope refresh" {
    load_ghcr
    write_static_stub gh '' 0
    function oci_digest_for_tag_anonymously { return "$LOOKUP_DENIED"; }
    function ghcr_package_version_by_tag { return "$LOOKUP_NOT_FOUND"; }
    function skopeo_is_available { return 0; }
    function skopeo_digest_for_tag_with_access_policy { return "$LOOKUP_NOT_FOUND"; }
    function choose_ghcr_direct_authentication { : >"$CALLS_DIR/prompt"; }

    run ghcr_digest_for_tag owner/app absent
    assert_status "$LOOKUP_NOT_FOUND"
    refute_file_exists "$CALLS_DIR/prompt"
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

    ghcr_tags_by_digest_adaptively owner/app "$DIGEST" ghcr.io/owner/app
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

    ghcr_tags_by_digest_adaptively \
        owner/app "$DIGEST" ghcr.io/owner/app 2>"$TEST_ROOT/stderr"
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

    ghcr_tags_by_digest_adaptively owner/app "$DIGEST" ghcr.io/owner/app
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

    run ghcr_tags_by_digest_adaptively owner/app "$DIGEST" ghcr.io/owner/app
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

    ghcr_tags_by_digest_adaptively owner/app "$DIGEST" ghcr.io/owner/app
    [[ "$registry_lookup_backend" == github-packages-api ]]
    [[ "$registry_tags" == release ]]
}
