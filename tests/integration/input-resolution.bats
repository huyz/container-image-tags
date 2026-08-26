#!/usr/bin/env bats

load ../test-helper.bash

DIGEST_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DIGEST_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

function install_resolution_stubs {
    mkdir -p "$FIXTURE_DIR/docker-images"
    : >"$FIXTURE_DIR/docker-aliases"
    : >"$FIXTURE_DIR/docker-containers"
    : >"$FIXTURE_DIR/docker-image-rows"
    : >"$FIXTURE_DIR/docker-image-ids"
    export REMOTE_DIGEST="sha256:$DIGEST_A"

    write_stub docker <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/docker.args"

if [[ "$1 $2" == 'container inspect' ]]; then
    while IFS=$'\t' read -r name image; do
        if [[ "$name" == "$3" ]]; then
            printf '%s\n' "$image"
            exit 0
        fi
    done <"$FIXTURE_DIR/docker-containers"
    exit 1
fi

if [[ "$1 $2" == 'image ls' ]]; then
    case " $* " in
    *' --quiet '*) cat "$FIXTURE_DIR/docker-image-ids" ;;
    *) cat "$FIXTURE_DIR/docker-image-rows" ;;
    esac
    exit 0
fi

if [[ "$1 $2" == 'image inspect' ]]; then
    reference="$3"
    key=
    while IFS=$'\t' read -r alias candidate_key; do
        if [[ "$alias" == "$reference" ]]; then key="$candidate_key"; break; fi
    done <"$FIXTURE_DIR/docker-aliases"
    [[ -n "$key" ]] || exit 1
    format=
    for ((index = 4; index <= $#; ++index)); do
        argument="${!index}"
        case "$argument" in
        --format=*) format="${argument#--format=}" ;;
        --format) index=$((index + 1)); format="${!index}" ;;
        esac
    done
    case "$format" in
    '{{.Id}}') cat "$FIXTURE_DIR/docker-images/$key.id" ;;
    *RepoDigests*) cat "$FIXTURE_DIR/docker-images/$key.repodigests" ;;
    *RepoTags*) cat "$FIXTURE_DIR/docker-images/$key.repotags" ;;
    *opencontainers.image.version*) cat "$FIXTURE_DIR/docker-images/$key.version" ;;
    *opencontainers.image.revision*) cat "$FIXTURE_DIR/docker-images/$key.revision" ;;
    *opencontainers.image.ref.name*) cat "$FIXTURE_DIR/docker-images/$key.refname" ;;
    *) exit 97 ;;
    esac
    exit 0
fi
exit 98
EOF

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
if [[ "$url" == https://hub.docker.com/* ]]; then
    [[ -z "$body" ]] || printf '{"digest":"%s"}' "$REMOTE_DIGEST" >"$body"
else
    [[ -z "$headers" ]] || printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: %s\r\n\r\n' "$REMOTE_DIGEST" >"$headers"
    [[ -z "$body" || "$body" == /dev/null ]] || : >"$body"
fi
printf '200'
EOF
}

function add_image_fixture {
    local key="$1" id="$2" repo_digests="$3" repo_tags="$4"
    shift 4
    printf '%s' "$id" >"$FIXTURE_DIR/docker-images/$key.id"
    printf '%s' "$repo_digests" >"$FIXTURE_DIR/docker-images/$key.repodigests"
    printf '%s' "$repo_tags" >"$FIXTURE_DIR/docker-images/$key.repotags"
    : >"$FIXTURE_DIR/docker-images/$key.version"
    : >"$FIXTURE_DIR/docker-images/$key.revision"
    : >"$FIXTURE_DIR/docker-images/$key.refname"
    printf '%s\t%s\n' "$id" "$key" >>"$FIXTURE_DIR/docker-aliases"
    local alias
    for alias in "$@"; do
        printf '%s\t%s\n' "$alias" "$key" >>"$FIXTURE_DIR/docker-aliases"
    done
}

function run_cli {
    run --separate-stderr "$SYSTEM_BASH" "$REPO_ROOT/container-image-tags" "$@" </dev/null
}

@test "INPUT-002 unsupported digest algorithms fail before registry work" {
    install_resolution_stubs

    run_cli --tag-resolution=remote --tag-scan=never \
        "registry.example/app@sha512:$DIGEST_A"
    assert_status 1
    assert_stderr_contains "Digest algorithm 'sha512'"
    refute_file_exists "$CALLS_DIR/curl.args"
}

@test "INPUT-003 short uppercase and malformed repository digests are rejected exactly" {
    install_resolution_stubs

    for reference in \
        'registry.example/app@sha256:abc' \
        "registry.example/app@sha256:${DIGEST_A^^}" \
        "registry.example/app@sha256:${DIGEST_A}x"; do
        run_cli --tag-resolution=remote --tag-scan=never "$reference"
        assert_status 1
        assert_stderr_contains 'expected repository@sha256:<64 lowercase hex characters>'
    done
    refute_file_exists "$CALLS_DIR/curl.args"
}

@test "INPUT-004 SHA-like container matches take precedence over image matches" {
    install_resolution_stubs
    sha=cccccccccccc
    printf '%s\t%s\n' "$sha" sha256:container-image >>"$FIXTURE_DIR/docker-containers"
    add_image_fixture image sha256:container-image \
        "registry.example/app@sha256:$DIGEST_A" 'registry.example/app:stable' \
        sha256:container-image "$sha"

    run_cli --json --tag-scan=never "$sha"
    assert_status 0
    assert_json '.[0].container == "cccccccccccc"'
    assert_json '.[0].local_image.id == "sha256:container-image"'
}

@test "INPUT-005 SHA-like local image matches are used after container misses" {
    install_resolution_stubs
    sha=dddddddddddd
    add_image_fixture image sha256:image-id \
        "registry.example/app@sha256:$DIGEST_A" 'registry.example/app:stable' "$sha"

    run_cli --json --tag-scan=never "$sha"
    assert_status 0
    assert_json '.[0].container == null and .[0].local_image.id == "sha256:image-id"'
}

@test "INPUT-009 SHA-like remote input is rejected before Docker or registry access" {
    install_resolution_stubs

    run_cli --tag-resolution=remote --tag-scan=never cccccccccccc
    assert_status 1
    assert_stderr_contains 'Cannot resolve SHA-like'
    refute_file_exists "$CALLS_DIR/docker.args"
    refute_file_exists "$CALLS_DIR/curl.args"
}

@test "INPUT-012 auto tagged local miss announces and uses the remote baseline" {
    install_resolution_stubs

    run_cli --json --tag-scan=never registry.example/app:stable
    assert_status 0
    assert_stderr_contains "No local image 'registry.example/app:stable' was found"
    assert_json '.[0].baseline_source == "remote" and .[0].local_image == null'
    assert_json '.[0].local_image == null and .[0].remote_tag_check.status == "resolved"'
    assert_file_exists "$CALLS_DIR/curl.args"
}

@test "INPUT-013 remote tagged input ignores a matching local Docker image" {
    install_resolution_stubs
    add_image_fixture local sha256:local \
        "registry.example/app@sha256:$DIGEST_B" 'registry.example/app:stable' \
        registry.example/app:stable

    run_cli --json --tag-resolution=remote --tag-scan=never registry.example/app:stable
    assert_status 0
    assert_json '.[0].baseline_source == "remote" and .[0].digest == "sha256:'"$DIGEST_A"'"'
    refute_file_exists "$CALLS_DIR/docker.args"
}

@test "INPUT-016 missing untagged local repository falls back to remote latest" {
    install_resolution_stubs

    run_cli --json --tag-scan=never registry.example/app
    assert_status 0
    assert_stderr_contains "falling back to remote tag resolution for 'registry.example/app:latest'"
    assert_json '.[0].baseline_source == "remote" and .[0].remote_tag_check.reference == "registry.example/app:latest"'
}

@test "INPUT-018 explicit wildcard in remote mode is rejected before network work" {
    install_resolution_stubs

    run_cli --tag-resolution=remote --tag-scan=never 'registry.example/app:*'
    assert_status 1
    assert_stderr_contains "Cannot use wildcard 'registry.example/app:*'"
    refute_file_exists "$CALLS_DIR/curl.args"
}

@test "INPUT-020 bare names in remote mode always resolve implicit latest" {
    install_resolution_stubs

    run_cli --json --tag-resolution=remote --tag-scan=never alpine
    assert_status 0
    assert_json '.[0].baseline_source == "remote" and .[0].repository == "alpine"'
    assert_json '.[0].remote_tag_check.reference == "alpine:latest"'
    refute_file_exists "$CALLS_DIR/docker.args"
}

@test "INPUT-021 wildcard images sharing a repository digest are processed once" {
    install_resolution_stubs
    add_image_fixture one sha256:one \
        "registry.example/app@sha256:$DIGEST_A" 'registry.example/app:one' sha256:one
    add_image_fixture two sha256:two \
        "registry.example/app@sha256:$DIGEST_A" 'registry.example/app:two' sha256:two
    printf '%s\n' sha256:one sha256:two >"$FIXTURE_DIR/docker-image-ids"
    printf '%s\n' $'registry.example/app\tsha256:one' \
        $'registry.example/app\tsha256:two' >"$FIXTURE_DIR/docker-image-rows"

    run_cli --json --verbose --tag-scan=never 'registry.example/app:*'
    assert_status 0
    assert_json 'length == 1 and .[0].digest == "sha256:'"$DIGEST_A"'"'
    assert_stderr_contains 'was already checked'
}

@test "INPUT-022 wildcard image without RepoDigest warns and remaining matches continue" {
    install_resolution_stubs
    add_image_fixture empty sha256:empty '' 'registry.example/app:empty' sha256:empty
    add_image_fixture valid sha256:valid \
        "registry.example/app@sha256:$DIGEST_A" 'registry.example/app:valid' sha256:valid
    printf '%s\n' sha256:empty sha256:valid >"$FIXTURE_DIR/docker-image-ids"
    printf '%s\n' $'registry.example/app\tsha256:empty' \
        $'registry.example/app\tsha256:valid' >"$FIXTURE_DIR/docker-image-rows"

    run_cli --json --tag-scan=never 'registry.example/app:*'
    assert_status 0
    assert_json 'length == 1 and .[0].local_image.id == "sha256:valid"'
    assert_stderr_contains "No repository digest found for wildcard image 'sha256:empty'"
}

@test "INPUT-023 a single local image without RepoDigest fails with image context" {
    install_resolution_stubs
    add_image_fixture empty sha256:empty '' 'registry.example/app:stable' \
        registry.example/app:stable

    run_cli --tag-resolution=local --tag-scan=never registry.example/app:stable
    assert_status 1
    assert_stderr_contains "No repository digest found for image 'sha256:empty'"
}

@test "INPUT-024 multiple positional inputs reset state and preserve result order" {
    install_resolution_stubs

    run_cli --json --tag-resolution=remote --tag-scan=never \
        "registry.example/a@sha256:$DIGEST_A" \
        "registry.example/b@sha256:$DIGEST_B"
    assert_status 0
    assert_json 'length == 2 and .[0].repository == "registry.example/a" and .[1].repository == "registry.example/b"'
    assert_json '.[0].local_image == null and .[1].local_image == null'
}

@test "INPUT-025 multiple human results use the fixed COLUMNS separator width" {
    install_resolution_stubs
    export COLUMNS=72

    run_cli --tag-resolution=remote --tag-scan=never \
        "registry.example/a@sha256:$DIGEST_A" \
        "registry.example/b@sha256:$DIGEST_B"
    assert_status 0
    separator=$(printf '%72s' '' | tr ' ' '-')
    [[ "$output" == *$'\n'"$separator"$'\n'* ]]
}

@test "INPUT-026 invalid remote digest is rejected before reverse lookup" {
    install_resolution_stubs
    export REMOTE_DIGEST=sha512:not-supported

    run_cli --tag-resolution=remote --tag-scan=never docker.io/team/app:stable
    assert_status 1
    assert_stderr_contains "Digest algorithm 'sha512'"
}
