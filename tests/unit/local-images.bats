#!/usr/bin/env bats

load ../test-helper.bash

function install_docker_fixture {
    write_stub docker <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/docker.args"
if [[ "$1 $2" == 'image inspect' ]]; then
    reference="$3"
    format="${4#--format=}"
    if [[ "$4" == --format ]]; then format="$5"; fi
    [[ "$reference" != missing ]] || exit 1
    case "$format" in
    '{{.Id}}') printf '%s\n' "${DOCKER_IMAGE_ID:-sha256:image}" ;;
    *RepoDigests*) printf '%s' "${DOCKER_REPO_DIGESTS-}" ;;
    *RepoTags*) printf '%s' "${DOCKER_REPO_TAGS-}" ;;
    *opencontainers.image.version*) printf '%s' "${DOCKER_IMAGE_VERSION-}" ;;
    *opencontainers.image.revision*) printf '%s' "${DOCKER_IMAGE_REVISION-}" ;;
    *opencontainers.image.ref.name*) printf '%s' "${DOCKER_IMAGE_REFNAME-}" ;;
    *) exit 97 ;;
    esac
elif [[ "$1 $2" == 'image ls' ]]; then
    case " $* " in
    *' --quiet '*) printf '%s' "${DOCKER_IMAGE_IDS-}" ;;
    *) printf '%s' "${DOCKER_IMAGE_ROWS-}" ;;
    esac
else
    exit 98
fi
EOF
}

@test "INPUT-010 local image inspection selects exact preferred repository and tag" {
    load_module local-images
    install_docker_fixture
    export DOCKER_REPO_DIGESTS=$'example/app@sha256:111\nexample/application@sha256:222\n'
    export DOCKER_REPO_TAGS=$'example/app:stable\nexample/application:stable\n'
    export DOCKER_IMAGE_VERSION=1.2.3
    export DOCKER_IMAGE_REVISION=abc123
    export DOCKER_IMAGE_REFNAME=v1.2.3

    inspect_local_image example/app:stable example/app example/app:stable
    [[ "$image_id" == sha256:image ]]
    [[ "$repo_digest" == 'example/app@sha256:111' ]]
    [[ "$local_tag" == 'example/app:stable' ]]
    [[ "$local_image_version" == 1.2.3 ]]
    [[ "$local_image_revision" == abc123 ]]
    [[ "$local_image_refname" == v1.2.3 ]]
}

@test "INPUT-011 local image inspection succeeds even without a RepoDigest" {
    load_module local-images
    install_docker_fixture
    export DOCKER_REPO_DIGESTS=
    export DOCKER_REPO_TAGS=$'example/app:latest\n'

    inspect_local_image example/app example/app example/app:latest
    [[ "$image_id" == sha256:image ]]
    [[ -z "$repo_digest" ]]
    [[ "$local_tag" == example/app:latest ]]
}

@test "INPUT-014 preferred latest tag wins without broadening repository" {
    load_module local-images
    install_docker_fixture
    export DOCKER_REPO_DIGESTS=$'example/app@sha256:111\n'
    export DOCKER_REPO_TAGS=$'example/app:old\nexample/app:latest\n'

    inspect_local_image example/app example/app example/app:latest
    [[ "$local_tag" == example/app:latest ]]
}

@test "INPUT-015 repository image IDs use exact names and sort unique values" {
    load_module local-images
    install_docker_fixture
    export DOCKER_IMAGE_ROWS=$'example/application\tsha256:wrong\nexample/app\tsha256:b\nexample/app\tsha256:a\nexample/app\tsha256:b\n'

    run image_ids_for_repository example/app
    assert_status 0
    assert_output_exact $'sha256:a\nsha256:b'
}

@test "INPUT-017 explicit repository lookup fails when no exact local images exist" {
    load_module local-images
    install_docker_fixture
    export DOCKER_IMAGE_ROWS=$'example/application\tsha256:wrong\n'

    run image_ids_for_repository example/app
    assert_status 1
    assert_output_exact ''
}

@test "INPUT-019 repository parser strips final tags but preserves registry ports" {
    load_module local-images

    run repository_from_image_reference localhost:5000/team/app:tag
    assert_status 0
    assert_output_exact localhost:5000/team/app

    run repository_from_image_reference localhost:5000/team/app
    assert_output_exact localhost:5000/team/app
}

@test "INPUT-001 repository parser strips an attached digest" {
    load_module local-images

    run repository_from_image_reference example/app@sha256:abc
    assert_status 0
    assert_output_exact example/app
}

@test "INPUT-006 bare digest recovery requires complete SHA equality" {
    load_module local-images
    install_docker_fixture
    export DOCKER_IMAGE_IDS=$'sha256:image\n'
    export DOCKER_REPO_DIGESTS=$'example/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nexample/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab\n'

    run repo_digests_for_sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    assert_status 0
    assert_output_exact 'example/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
}

@test "INPUT-008 digest recovery never accepts a prefix" {
    load_module local-images
    install_docker_fixture
    export DOCKER_IMAGE_IDS=$'sha256:image\n'
    export DOCKER_REPO_DIGESTS=$'example/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'

    run repo_digests_for_sha aaaaaaaaaaaa
    assert_status 1
}

@test "INPUT-007 recovered repository digests are unique and deterministic" {
    load_module local-images
    install_docker_fixture
    digest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    export DOCKER_IMAGE_IDS=$'sha256:image\n'
    export DOCKER_REPO_DIGESTS=$'z/app@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\na/app@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nz/app@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'

    run repo_digests_for_sha "$digest"
    assert_status 0
    assert_output_exact $'a/app@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nz/app@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
}
