#!/usr/bin/env bats

load ../test-helper.bash

DIGEST_A=1111111111111111111111111111111111111111111111111111111111111111
DIGEST_B=2222222222222222222222222222222222222222222222222222222222222222

function install_required_tools {
    write_static_stub curl '' 0
    write_static_stub docker '' 1
}

function install_local_output_fixtures {
    export LOCAL_IMAGE_ID=sha256:local-image
    export LOCAL_REPO_DIGEST="registry.example/app@sha256:$DIGEST_A"
    export LOCAL_REPO_TAGS=registry.example/app:stable
    export LOCAL_IMAGE_ROWS=$'registry.example/app\tsha256:local-image\n'
    export LOCAL_IMAGE_IDS=$'sha256:local-image\n'
    export REMOTE_CODE=200
    export REMOTE_DIGEST="sha256:$DIGEST_A"
    export REMOTE_TAGS='[]'

    write_stub docker <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/docker.args"
if [[ "$1 $2" == 'container inspect' ]]; then exit 1; fi
if [[ "$1 $2" == 'image ls' ]]; then
    case " $* " in
    *' --quiet '*) printf '%s' "$LOCAL_IMAGE_IDS" ;;
    *) printf '%s' "$LOCAL_IMAGE_ROWS" ;;
    esac
    exit 0
fi
if [[ "$1 $2" == 'image inspect' ]]; then
    format=
    for ((index = 4; index <= $#; ++index)); do
        argument="${!index}"
        case "$argument" in
        --format=*) format="${argument#--format=}" ;;
        --format) index=$((index + 1)); format="${!index}" ;;
        esac
    done
    case "$format" in
    '{{.Id}}') printf '%s' "$LOCAL_IMAGE_ID" ;;
    *RepoDigests*) printf '%s' "$LOCAL_REPO_DIGEST" ;;
    *RepoTags*) printf '%s' "$LOCAL_REPO_TAGS" ;;
    *opencontainers.image.version*) printf '1.2.3' ;;
    *opencontainers.image.revision*) printf 'revision-one' ;;
    *opencontainers.image.ref.name*) printf 'v1.2.3' ;;
    *) exit 97 ;;
    esac
    exit 0
fi
exit 98
EOF

    write_stub curl <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/curl.args"
if [[ " $* " == *' --help all '* ]]; then exit 0; fi
url="${!#}"; headers=; body=
for ((index = 1; index <= $#; ++index)); do
    case "${!index}" in
    -D) index=$((index + 1)); headers="${!index}" ;;
    -o) index=$((index + 1)); body="${!index}" ;;
    esac
done
if [[ "$url" == *'/tags/list'* ]]; then
    [[ -z "$headers" ]] || printf 'HTTP/1.1 %s Result\r\n' "$REMOTE_CODE" >"$headers"
    [[ -z "$body" ]] || printf '{"tags":%s}' "$REMOTE_TAGS" >"$body"
else
    [[ -z "$headers" ]] || printf 'HTTP/1.1 %s Result\r\nDocker-Content-Digest: %s\r\n' \
        "$REMOTE_CODE" "$REMOTE_DIGEST" >"$headers"
    [[ -z "$body" || "$body" == /dev/null ]] || : >"$body"
fi
printf '%s' "$REMOTE_CODE"
EOF
}

function run_cli {
    run --separate-stderr "$SYSTEM_BASH" "$REPO_ROOT/container-image-tags" "$@" </dev/null
}

@test "OUTPUT-001 interpretation notice precedes human result fields" {
    install_required_tools

    run_cli --tag-resolution=remote --tag-scan=never \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_stderr_contains 'Interpreting'
    assert_output_contains 'Repository:      registry.example/app'
}

@test "OUTPUT-002 local baseline prints metadata and exact direct-tag states" {
    install_local_output_fixtures

    run_cli --tag-resolution=local --tag-scan=never registry.example/app:stable
    assert_status 0
    assert_output_contains 'Local Image ID:  sha256:local-image'
    assert_output_contains 'OCI annotation » Version:  1.2.3'
    assert_output_contains 'Local tag:  stable'
    assert_output_contains 'Remote tag check: ✅ MATCH'

    export REMOTE_DIGEST="sha256:$DIGEST_B"
    run_cli --tag-resolution=local --tag-scan=never registry.example/app:stable
    assert_status 0
    assert_output_contains 'Remote tag check: ❗️ MISMATCH'

    export REMOTE_CODE=404
    run_cli --tag-resolution=local --tag-scan=never registry.example/app:stable
    assert_status 0
    assert_output_contains 'Remote tag check: ❌ NOT FOUND'
}

@test "OUTPUT-003 remote baseline prints resolution without a local check" {
    install_local_output_fixtures

    run_cli --tag-resolution=remote --tag-scan=never registry.example/app:stable
    assert_status 0
    assert_output_contains 'Remote tag: stable'
    assert_output_contains 'Remote tag resolution: registry.example/app:stable points to'
    refute_output_contains 'Local Image ID:'
    refute_output_contains 'Remote tag check:'
}

@test "OUTPUT-004 any and all human headings are distinct" {
    install_required_tools
    write_stub curl <<'EOF'
headers=; body=
for ((index = 1; index <= $#; ++index)); do
    case "${!index}" in
    --help) printf '%s\n' '--parallel-max'; exit 0 ;;
    -D) index=$((index + 1)); headers="${!index}" ;;
    -o) index=$((index + 1)); body="${!index}" ;;
    esac
done
[[ -z "$headers" ]] || printf 'HTTP/1.1 200 OK\r\n' >"$headers"
[[ -z "$body" || "$body" == /dev/null ]] || printf '{"tags":[]}' >"$body"
printf '200'
EOF

    run_cli --tag-resolution=remote --tag-scan=any \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_output_contains 'Remote tags (partial scan):'

    run_cli --tag-resolution=remote --tag-scan=all \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_output_contains 'Other remote tags:'
}

@test "OUTPUT-005 completed scan with no matches prints an explicit none marker" {
    install_local_output_fixtures

    run_cli --tag-resolution=remote --tag-scan=all \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_output_contains 'Other remote tags:'
    assert_output_contains '<none>'
}

@test "OUTPUT-009 confirmed durable direct tag satisfies any-durable without reverse scan" {
    install_local_output_fixtures
    export LOCAL_REPO_TAGS=registry.example/app:1.2.3

    run_cli --tag-resolution=local --tag-scan=any-durable registry.example/app:1.2.3
    assert_status 0
    assert_output_contains 'Remote tags (partial scan):'
    assert_output_contains '1.2.3'
    ! grep -aFq '/tags/list' "$CALLS_DIR/curl.args"
}

@test "OUTPUT-006 provider metadata prints only for supported GHCR package results" {
    install_required_tools
    write_stub gh <<'EOF'
printf '%s\n' '[{"name":"sha256:1111111111111111111111111111111111111111111111111111111111111111","created_at":"2026-01-01","updated_at":"2026-01-02","metadata":{"container":{"tags":["stable"]}}}]'
EOF

    run_cli --credential-policy=require --tag-resolution=remote --tag-scan=all \
        "ghcr.io/owner/app@sha256:$DIGEST_A"
    assert_status 0
    assert_output_contains 'GHCR package info:'
    assert_output_contains 'Created: 2026-01-01'

    run_cli --tag-resolution=remote --tag-scan=never \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    refute_output_contains 'GHCR package info:'
}

@test "OUTPUT-007 diagnostic classes retain prefixes streams and gating" {
    load_common

    run --separate-stderr notice changed
    assert_stderr_exact 'NOTICE: changed'
    run --separate-stderr warn caution
    assert_stderr_contains '⚠️ WARNING: caution'
    run --separate-stderr verbose hidden
    assert_stderr_exact ''
    opt_verbose=1
    run --separate-stderr verbose detail
    assert_stderr_exact detail
    opt_debug=1
    run --separate-stderr debug internals
    assert_stderr_contains '🔧 DEBUG: internals'
}

@test "OUTPUT-008 skipped provider state does not suppress a later result" {
    load_common
    # shellcheck source=../../lib/oci.sh
    source "$REPO_ROOT/lib/oci.sh"
    # shellcheck source=../../lib/ghcr.sh
    source "$REPO_ROOT/lib/ghcr.sh"
    registry_tag_scan=all; registry_direct_tag=
    function ghcr_package_version_by_digest { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_is_available { return 1; }
    function choose_ghcr_fallback { printf '%s\n' skip; }
    skip_input=; registry_tags=; registry_metadata=; registry_lookup_backend=; registry_lookup_result=completed
    ghcr_tags_by_digest owner/first "sha256:$DIGEST_A" ghcr.io/owner/first
    [[ -n "$skip_input" ]]

    skip_input=
    printf '%s\n' 'Repository:      registry.example/later'
    [[ -z "$skip_input" ]]
}

@test "JSON-001 stdout is one valid JSON array and diagnostics stay on stderr" {
    install_required_tools

    run_cli --json --tag-resolution=remote --tag-scan=never \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_valid_json
    assert_json 'type == "array" and length == 1'
    refute_output_contains 'NOTICE:'
    assert_stderr_contains 'NOTICE:'
}

@test "JSON-002 multiple complete inputs retain input order in one array" {
    install_required_tools

    run_cli --json --tag-resolution=remote --tag-scan=never \
        "registry.example/a@sha256:$DIGEST_A" \
        "registry.example/b@sha256:$DIGEST_B"
    assert_status 0
    assert_valid_json
    assert_json 'length == 2'
    assert_json '.[0].repository == "registry.example/a" and .[1].repository == "registry.example/b"'
}

@test "JSON-003 complete digest input has null local fields and input baseline" {
    install_required_tools

    run_cli --json --tag-resolution=remote --tag-scan=never \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_json '.[0].local_image == null and .[0].container == null'
    assert_json '.[0].baseline_source == "input"'
}

@test "JSON-004 direct check statuses cover resolved match mismatch not-found and unavailable" {
    install_local_output_fixtures

    run_cli --json --tag-resolution=remote --tag-scan=never registry.example/app:stable
    assert_status 0
    assert_json '.[0].remote_tag_check.status == "resolved"'

    run_cli --json --tag-resolution=local --tag-scan=never registry.example/app:stable
    assert_status 0
    assert_json '.[0].remote_tag_check.status == "match"'

    export REMOTE_DIGEST="sha256:$DIGEST_B"
    run_cli --json --tag-resolution=local --tag-scan=never registry.example/app:stable
    assert_status 0
    assert_json '.[0].remote_tag_check.status == "mismatch"'

    export REMOTE_CODE=404
    run_cli --json --tag-resolution=local --tag-scan=never registry.example/app:stable
    assert_status 0
    assert_json '.[0].remote_tag_check.status == "not_found"'

    export REMOTE_CODE=200 LOCAL_REPO_TAGS=
    run_cli --json --tag-resolution=local --tag-scan=never registry.example/app:stable
    assert_status 0
    assert_json '.[0].remote_tag_check.status == "unavailable"'
}

@test "JSON-005 never scan reports not requested with null backend" {
    install_required_tools

    run_cli --json --tag-resolution=remote --tag-scan=never \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_json '.[0].tag_scan == {"mode":"never","status":"not_requested","backend":null,"provider_metadata":null,"tags":[]}'
}

@test "JSON-006 scan backend belongs to the documented enum" {
    install_local_output_fixtures

    run_cli --json --tag-resolution=remote --tag-scan=all \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_json '.[0].tag_scan.backend as $b | ["acr-api","direct-tag-check","docker-hub-api","ecr-api","gar-api","github-packages-api","gcr-api","oci-registry-api","skopeo",null] | index($b) != null'
}

@test "JSON-007 fallback reports Skopeo as the backend that produced tags" {
    install_local_output_fixtures
    export REMOTE_CODE=500
    write_stub skopeo <<'EOF'
if [[ " $* " == *' list-tags '* ]]; then
    printf '%s\n' '{"Tags":["stable"]}'
elif [[ " $* " == *' manifest-digest '* ]]; then
    cat >/dev/null
    printf '%s\n' 'sha256:1111111111111111111111111111111111111111111111111111111111111111'
elif [[ " $* " == *' inspect '* ]]; then
    printf '%s' '{"schemaVersion":2}'
else
    exit 1
fi
EOF

    run_cli --json --tag-resolution=remote --tag-scan=all \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_json '.[0].tag_scan.backend == "skopeo" and .[0].tag_scan.tags == ["stable"]'
}

@test "JSON-008 tags remain an exact ordered array" {
    install_local_output_fixtures
    export REMOTE_TAGS='["z","a"]'

    run_cli --json --tag-resolution=remote --tag-scan=all \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_json '.[0].tag_scan.tags == ["z","a"]'
}

@test "JSON-009 GHCR provider metadata is parsed JSON and other providers use null" {
    install_required_tools
    write_stub gh <<'EOF'
printf '%s\n' '[{"name":"sha256:1111111111111111111111111111111111111111111111111111111111111111","created_at":"2026-01-01","metadata":{"container":{"tags":["stable"]}}}]'
EOF

    run_cli --json --credential-policy=require --tag-resolution=remote --tag-scan=all \
        "ghcr.io/owner/app@sha256:$DIGEST_A"
    assert_status 0
    assert_json '.[0].tag_scan.provider_metadata.name == "sha256:'"$DIGEST_A"'"'

    run_cli --json --tag-resolution=remote --tag-scan=never \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_json '.[0].tag_scan.provider_metadata == null'
}

@test "JSON-010 verbose and debug diagnostics never contaminate stdout" {
    install_required_tools

    run_cli --json --verbose --debug --tag-resolution=remote --tag-scan=never \
        "registry.example/app@sha256:$DIGEST_A"
    assert_status 0
    assert_valid_json
    refute_output_contains 'DEBUG:'
    refute_output_contains 'NOTICE:'
}

@test "JSON-011 wildcard and multiple inputs still emit one ordered array" {
    install_local_output_fixtures

    run_cli --json --tag-scan=never 'registry.example/app:*' \
        "registry.example/second@sha256:$DIGEST_B"
    assert_status 0
    assert_json 'type == "array" and length == 2'
    assert_json '.[0].input == "registry.example/app:*" and .[1].input == "registry.example/second@sha256:'"$DIGEST_B"'"'
}
