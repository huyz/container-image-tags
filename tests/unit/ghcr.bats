#!/usr/bin/env bats

load ../test-helper.bash

DIGEST=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

function load_ghcr {
    load_common
    # shellcheck source=../../lib/oci.sh
    source "$REPO_ROOT/lib/oci.sh"
    # shellcheck source=../../lib/ghcr.sh
    source "$REPO_ROOT/lib/ghcr.sh"
    opt_ghcr_method=auto
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

@test "GHCR-007 anonymous token challenge preserves advertised service and scope" {
    load_ghcr
    export GHCR_CALL=0
    write_stub curl <<'EOF'
count_file="$CALLS_DIR/count"
count=0; [[ ! -f "$count_file" ]] || count=$(<"$count_file")
count=$((count + 1)); printf '%d\n' "$count" >"$count_file"
if ((count == 1)); then
    printf 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:owner/app:pull"\r\n\r\n'
else
    printf '%s\0' "$@" >"$CALLS_DIR/token.args"
    printf '%s\n' '{"token":"pull-token"}'
fi
EOF

    run ghcr_anonymous_pull_token owner/app
    assert_status 0
    assert_output_exact pull-token
    args=$(tr '\0' '\n' <"$CALLS_DIR/token.args")
    [[ "$args" == *$'--data-urlencode\nservice=ghcr.io\n'* ]]
    [[ "$args" == *$'--data-urlencode\nscope=repository:owner/app:pull\n'* ]]
    [[ "$args" == *'https://ghcr.io/token'* ]]
}

@test "GHCR-008 anonymous direct lookup distinguishes success and 404" {
    load_ghcr
    function ghcr_anonymous_pull_token { printf '%s\n' token; }
    export GHCR_CODE=200 GHCR_DIGEST="$DIGEST"
    write_stub curl <<'EOF'
headers=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -D ]]; then index=$((index + 1)); headers="${!index}"; fi
done
if [[ "$GHCR_CODE" == 200 ]]; then
    printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: %s\r\n' "$GHCR_DIGEST" >"$headers"
else
    : >"$headers"
fi
printf '%s' "$GHCR_CODE"
EOF

    run ghcr_digest_for_tag_anonymously owner/app stable
    assert_status 0
    assert_output_exact "$DIGEST"
    export GHCR_CODE=404
    run ghcr_digest_for_tag_anonymously owner/app absent
    assert_status "$LOOKUP_NOT_FOUND"
}

@test "GHCR-009 forced anonymous direct lookup never calls Packages API" {
    load_ghcr
    opt_ghcr_method=anonymous
    function ghcr_digest_for_tag_anonymously { printf '%s\n' "$DIGEST"; }
    function ghcr_package_version_by_tag { : >"$CALLS_DIR/packages"; return 0; }

    run ghcr_digest_for_tag owner/app stable
    assert_status 0
    assert_output_exact "$DIGEST"
    refute_file_exists "$CALLS_DIR/packages"
}

@test "GHCR-010 forced packages mode does not call anonymous direct lookup" {
    load_ghcr
    opt_ghcr_method=packages
    function ghcr_digest_for_tag_anonymously { : >"$CALLS_DIR/anonymous"; return 0; }
    function ghcr_package_version_by_tag {
        printf '{"name":"%s"}\n' "$DIGEST"
    }

    run ghcr_digest_for_tag owner/app stable
    assert_status 0
    assert_output_exact "$DIGEST"
    refute_file_exists "$CALLS_DIR/anonymous"
}

@test "GHCR-011 auto direct lookup follows anonymous then Packages then Skopeo" {
    load_ghcr
    function ghcr_digest_for_tag_anonymously { printf '%s\n' anonymous >>"$CALLS_DIR/order"; return "$LOOKUP_UNAVAILABLE"; }
    function ghcr_package_version_by_tag { printf '%s\n' packages >>"$CALLS_DIR/order"; return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_digest_for_tag { printf '%s\n' skopeo >>"$CALLS_DIR/order"; printf '%s\n' "$DIGEST"; }

    run --separate-stderr ghcr_digest_for_tag owner/app stable
    assert_status 0
    assert_output_exact "$DIGEST"
    [[ $(<"$CALLS_DIR/order") == $'anonymous\npackages\nskopeo' ]]
}

@test "GHCR-012 anonymous tag pagination follows relative and same-host absolute links" {
    load_ghcr
    registry_tag_scan=all
    registry_direct_tag=
    function ghcr_anonymous_pull_token { printf '%s\n' token; }
    export GHCR_DIGEST="$DIGEST"
    write_stub curl <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/curl.args"
url="${!#}"; headers=; body=
for ((index = 1; index <= $#; ++index)); do
    case "${!index}" in
    -D) index=$((index + 1)); headers="${!index}" ;;
    -o) index=$((index + 1)); body="${!index}" ;;
    esac
done
if [[ "$url" == 'https://ghcr.io/v2/owner/app/tags/list?n=100' ]]; then
    printf 'Link: </v2/owner/app/tags/list?n=100&last=one>; rel="next"\r\n' >"$headers"
    printf '{"tags":["one"]}' >"$body"
elif [[ "$url" == *'last=one' ]]; then
    printf 'Link: <https://ghcr.io/v2/owner/app/tags/list?n=100&last=two>; rel="next"\r\n' >"$headers"
    printf '{"tags":["two"]}' >"$body"
elif [[ "$url" == *'last=two' ]]; then
    : >"$headers"; printf '{"tags":["three"]}' >"$body"
else
    printf 'Docker-Content-Digest: %s\r\n' "$GHCR_DIGEST" >"$headers"
fi
EOF

    run ghcr_tags_by_digest_anonymously owner/app "$DIGEST"
    assert_status 0
    assert_output_exact $'one\ntwo\nthree'
    args=$(tr '\0' '\n' <"$CALLS_DIR/curl.args")
    [[ "$args" == *'/v2/owner/app/tags/list?n=100&last=one'* ]]
    [[ "$args" == *'https://ghcr.io/v2/owner/app/tags/list?n=100&last=two'* ]]
}

@test "GHCR-013 anonymous any excludes direct tag and stops after one match" {
    load_ghcr
    registry_tag_scan=any
    registry_direct_tag=stable
    function ghcr_anonymous_pull_token { printf '%s\n' token; }
    export GHCR_DIGEST="$DIGEST"
    write_stub curl <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/curl.args"
url="${!#}"
headers=; body=
for ((index = 1; index <= $#; ++index)); do
    case "${!index}" in
    -D) index=$((index + 1)); headers="${!index}" ;;
    -o) index=$((index + 1)); body="${!index}" ;;
    esac
done
if [[ "$url" == *'/tags/list'* ]]; then
    : >"$headers"; printf '%s' '{"tags":["stable","other","unused"]}' >"$body"
else
    printf 'Docker-Content-Digest: %s\r\n' "$GHCR_DIGEST" >"$headers"
fi
EOF

    run ghcr_tags_by_digest_anonymously owner/app "$DIGEST"
    assert_status 0
    assert_output_exact other
    args=$(tr '\0' '\n' <"$CALLS_DIR/curl.args")
    [[ "$args" != *'/manifests/stable'* ]]
    [[ "$args" != *'/manifests/unused'* ]]
}

@test "GHCR-014 Packages reverse result populates tags and provider metadata" {
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

@test "GHCR-015 active untagged package metadata prints the documented note" {
    load_ghcr
    registry_lookup_result=completed
    registry_lookup_backend=github-packages-api
    registry_metadata='{"created_at":"2026-01-01","updated_at":"2026-01-02","metadata":{"container":{"tags":[]}}}'

    run ghcr_print_metadata
    assert_status 0
    assert_output_contains 'GHCR package info:'
    assert_output_contains 'still an active GHCR package version, but no current tag points to it'
}

@test "GHCR-016 fallback choice strings dispatch anonymous and skip" {
    load_ghcr
    registry_tag_scan=all; registry_direct_tag=; registry_lookup_result=completed
    function ghcr_package_version_by_digest { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_has_registry_credentials { return 1; }
    function choose_ghcr_fallback { printf '%s\n' anonymous; }
    function ghcr_tags_by_digest_anonymously { printf '%s\n' found; }
    registry_tags=; registry_metadata=; registry_lookup_backend=
    ghcr_tags_by_digest owner/app "$DIGEST" ghcr.io/owner/app
    [[ "$registry_lookup_backend" == oci-registry-api ]]
    [[ "$registry_tags" == found ]]

    function choose_ghcr_fallback { printf '%s\n' skip; }
    skip_input=
    registry_tags=; registry_metadata=; registry_lookup_backend=
    ghcr_tags_by_digest owner/app "$DIGEST" ghcr.io/owner/app
    [[ -n "$skip_input" ]]
}

@test "GHCR-017 a skipped GHCR lookup does not suppress the next result" {
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
    function ghcr_tags_by_digest_anonymously { printf '%s\n' next-result; }
    registry_tags=; registry_metadata=; registry_lookup_backend=; registry_lookup_result=completed
    ghcr_tags_by_digest owner/next "$DIGEST" ghcr.io/owner/next
    [[ -z "$skip_input" && "$registry_tags" == next-result ]]
}

@test "GHCR-018 progress is absent in noninteractive anonymous scans" {
    load_ghcr
    function is_interactive_session { return 1; }
    registry_tag_scan=all; registry_direct_tag=
    function ghcr_anonymous_pull_token { printf '%s\n' token; }
    write_stub curl <<'EOF'
url="${!#}"; headers=; body=
for ((index = 1; index <= $#; ++index)); do
    case "${!index}" in
    -D) index=$((index + 1)); headers="${!index}" ;;
    -o) index=$((index + 1)); body="${!index}" ;;
    esac
done
if [[ "$url" == *'/tags/list'* ]]; then : >"$headers"; printf '{"tags":[]}' >"$body"; fi
EOF

    run --separate-stderr ghcr_tags_by_digest_anonymously owner/app "$DIGEST"
    assert_status 0
    assert_stderr_exact ''
}

@test "GHCR-019 anonymous bearer token is supplied through a header file" {
    load_ghcr
    export GHCR_CANARY=ghcr-secret-canary GHCR_CODE=200 GHCR_DIGEST="$DIGEST"
    function ghcr_anonymous_pull_token { printf '%s\n' "$GHCR_CANARY"; }
    write_stub curl <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/curl.args"
headers=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -D ]]; then index=$((index + 1)); headers="${!index}"; fi
done
printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: %s\r\n' "$GHCR_DIGEST" >"$headers"
printf '200'
EOF

    run ghcr_digest_for_tag_anonymously owner/app stable
    assert_status 0
    ! grep -aFq "$GHCR_CANARY" "$CALLS_DIR/curl.args"
    args=$(tr '\0' '\n' <"$CALLS_DIR/curl.args")
    [[ "$args" == *'@'* ]]
}
