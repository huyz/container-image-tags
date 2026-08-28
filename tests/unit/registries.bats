#!/usr/bin/env bats

load ../test-helper.bash

function load_registry_dispatch {
    load_common
    # Load the real adapter entry points; individual tests replace the backend
    # operation they need to observe.
    # shellcheck source=../../lib/skopeo.sh
    source "$REPO_ROOT/lib/skopeo.sh"
    # shellcheck source=../../lib/oci.sh
    source "$REPO_ROOT/lib/oci.sh"
    # shellcheck source=../../lib/docker-hub.sh
    source "$REPO_ROOT/lib/docker-hub.sh"
    # shellcheck source=../../lib/ghcr.sh
    source "$REPO_ROOT/lib/ghcr.sh"
    # shellcheck source=../../lib/acr.sh
    source "$REPO_ROOT/lib/acr.sh"
    # shellcheck source=../../lib/gar.sh
    source "$REPO_ROOT/lib/gar.sh"
    # shellcheck source=../../lib/gcr.sh
    source "$REPO_ROOT/lib/gcr.sh"
    # shellcheck source=../../lib/ecr.sh
    source "$REPO_ROOT/lib/ecr.sh"
    function skopeo_prepare_lazy_auth { :; }
    # shellcheck source=../../lib/registries.sh
    source "$REPO_ROOT/lib/registries.sh"
}

function assert_classification {
    local repository="$1" expected_kind="$2" expected_repository="$3" expected_host="$4"
    registry_classify "$repository"
    [[ "$registry_kind" == "$expected_kind" ]]
    [[ "$registry_repository" == "$expected_repository" ]]
    [[ "$registry_host" == "$expected_host" ]]
}

@test "DISPATCH-001 registry classification covers provider aliases and near misses" {
    load_registry_dispatch

    assert_classification alpine docker-hub library/alpine docker.io
    assert_classification docker.io/team/app docker-hub team/app docker.io
    assert_classification index.docker.io/team/app docker-hub team/app docker.io
    assert_classification registry-1.docker.io/team/app docker-hub team/app docker.io
    assert_classification ghcr.io/team/app ghcr team/app ghcr.io
    assert_classification vault.azurecr.io/team/app acr vault.azurecr.io/team/app vault.azurecr.io
    assert_classification vault.azurecr.cn/team/app acr vault.azurecr.cn/team/app vault.azurecr.cn
    assert_classification gcr.io/project/app gcr project/app gcr.io
    assert_classification us.gcr.io/project/app gcr project/app us.gcr.io
    assert_classification us-docker.pkg.dev/project/repo/app gar us-docker.pkg.dev/project/repo/app us-docker.pkg.dev
    assert_classification public.ecr.aws/alias/app ecr public.ecr.aws/alias/app public.ecr.aws
    assert_classification 123456789012.dkr.ecr.us-west-2.amazonaws.com/app ecr \
        123456789012.dkr.ecr.us-west-2.amazonaws.com/app \
        123456789012.dkr.ecr.us-west-2.amazonaws.com
    assert_classification 123456789012.dkr-ecr-fips.us-gov-west-1.on.aws/app ecr \
        123456789012.dkr-ecr-fips.us-gov-west-1.on.aws/app \
        123456789012.dkr-ecr-fips.us-gov-west-1.on.aws
    assert_classification localhost:5000/team/app other localhost:5000/team/app localhost:5000
    assert_classification ghcr.io.example/team/app other ghcr.io.example/team/app ghcr.io.example
}

@test "DISPATCH-002 direct lookup calls only the classified Docker Hub adapter" {
    load_registry_dispatch
    function docker_hub_digest_for_tag {
        printf '%s\0' "$@" >"$CALLS_DIR/hub"
        printf '%s\n' sha256:hub
    }
    function skopeo_digest_for_tag { : >"$CALLS_DIR/skopeo"; return 1; }
    registry_classify alpine

    registry_resolve_tag_digest alpine latest
    [[ "$remote_tag_status" -eq "$LOOKUP_SUCCEEDED" ]]
    [[ "$remote_tag_digest" == sha256:hub ]]
    assert_call_args "$CALLS_DIR/hub" library/alpine latest
    refute_file_exists "$CALLS_DIR/skopeo"
}

@test "DISPATCH-003 reverse lookup records the actual initial backend" {
    load_registry_dispatch
    function docker_hub_tags_by_digest { registry_tags=stable; }
    registry_classify alpine

    registry_find_tags_by_digest alpine sha256:full all latest
    [[ "$registry_lookup_backend" == docker-hub-api ]]
    [[ "$registry_tags" == stable ]]
}

@test "DISPATCH-004 authoritative generic not-found does not fall back" {
    load_registry_dispatch
    function oci_digest_for_tag_anonymously { return "$LOOKUP_NOT_FOUND"; }
    function skopeo_is_available { : >"$CALLS_DIR/skopeo-available"; return 0; }
    registry_classify registry.example/team/app

    registry_resolve_tag_digest registry.example/team/app absent
    [[ "$remote_tag_status" -eq "$LOOKUP_NOT_FOUND" ]]
    refute_file_exists "$CALLS_DIR/skopeo-available"
}

@test "DISPATCH-005 unavailable generic lookup falls back once and updates result" {
    load_registry_dispatch
    function oci_digest_for_tag_anonymously { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_is_available { return 0; }
    function skopeo_digest_for_tag_with_access_policy {
        printf '%s\n' "$2" >>"$CALLS_DIR/skopeo"
        printf '%s\n' sha256:fallback
    }
    registry_classify registry.example/team/app

    run --separate-stderr registry_resolve_tag_digest registry.example/team/app stable
    assert_status 0
    [[ $(wc -l <"$CALLS_DIR/skopeo") -eq 1 ]]
}

@test "DISPATCH-006 denied GCR metadata invokes only its intended auth fallback" {
    load_registry_dispatch
    function gcr_digest_for_tag_anonymously { return "$LOOKUP_DENIED"; }
    function gar_access_token { printf '%s\n' token; }
    function gcr_digest_for_tag_with_bearer_token {
        printf '%s\0' "$@" >"$CALLS_DIR/gcr-authenticated"
        printf '%s\n' sha256:authenticated
    }
    registry_classify gcr.io/project/app

    registry_resolve_tag_digest gcr.io/project/app stable
    [[ "$remote_tag_status" -eq "$LOOKUP_SUCCEEDED" ]]
    [[ "$remote_tag_digest" == sha256:authenticated ]]
    assert_call_args "$CALLS_DIR/gcr-authenticated" \
        gcr.io project/app stable token
}

@test "DISPATCH-007 stopped generic lookup aborts without Skopeo fallback" {
    load_registry_dispatch
    function oci_digest_for_tag_anonymously { return "$LOOKUP_STOPPED"; }
    function skopeo_is_available { : >"$CALLS_DIR/skopeo"; return 0; }
    registry_classify registry.example/team/app

    run --separate-stderr registry_resolve_tag_digest registry.example/team/app stable
    assert_status 1
    assert_stderr_contains "OCI registry lookup stopped"
    refute_file_exists "$CALLS_DIR/skopeo"
}

@test "OCI-021 rate limiting never invokes Skopeo fallback" {
    load_registry_dispatch
    function oci_digest_for_tag_anonymously { return "$LOOKUP_STOPPED"; }
    function skopeo_is_available { : >"$CALLS_DIR/skopeo"; return 0; }
    registry_classify registry.example/team/app

    run --separate-stderr registry_resolve_tag_digest registry.example/team/app stable
    assert_status 1
    assert_stderr_contains 'OCI registry lookup stopped'
    refute_file_exists "$CALLS_DIR/skopeo"
}

@test "OCI-022 unavailable OCI fast path falls back to Skopeo exactly once" {
    load_registry_dispatch
    function oci_digest_for_tag_anonymously { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_is_available { return 0; }
    function skopeo_digest_for_tag_with_access_policy {
        printf '%s\n' call >>"$CALLS_DIR/skopeo"
        printf '%s\n' sha256:fallback
    }
    registry_classify registry.example/team/app

    registry_resolve_tag_digest registry.example/team/app stable
    [[ "$remote_tag_status" -eq "$LOOKUP_SUCCEEDED" ]]
    [[ "$remote_tag_digest" == sha256:fallback ]]
    [[ $(wc -l <"$CALLS_DIR/skopeo") -eq 1 ]]
}

@test "POLICY-001 require skips public OCI and enters credentialed Skopeo" {
    load_registry_dispatch
    opt_credential_policy=require
    function oci_digest_for_tag_anonymously { : >"$CALLS_DIR/unexpected-oci"; }
    function skopeo_is_available { return 0; }
    function skopeo_digest_for_tag_with_access_policy {
        printf '%s\0' "$@" >"$CALLS_DIR/skopeo-policy"
        printf '%s\n' sha256:credentialed
    }
    registry_classify registry.example/team/app

    registry_resolve_tag_digest registry.example/team/app stable
    [[ "$remote_tag_status" -eq "$LOOKUP_SUCCEEDED" ]]
    [[ "$remote_tag_digest" == sha256:credentialed ]]
    refute_file_exists "$CALLS_DIR/unexpected-oci"
    assert_call_args "$CALLS_DIR/skopeo-policy" \
        registry.example registry.example/team/app:stable '' "$LOOKUP_DENIED"
}

@test "DISPATCH-008 every reverse lookup resets shared result and metadata fields" {
    load_registry_dispatch
    function ghcr_tags_by_digest {
        registry_tags=one
        registry_metadata='{"name":"sha256:one"}'
        registry_lookup_backend=github-packages-api
    }
    registry_classify ghcr.io/team/app
    registry_find_tags_by_digest ghcr.io/team/app sha256:one all '<none>'
    [[ -n "$registry_metadata" ]]

    function docker_hub_tags_by_digest { registry_tags=two; }
    registry_classify alpine
    registry_find_tags_by_digest alpine sha256:two all '<none>'
    [[ -z "$registry_metadata" ]]
    [[ "$registry_lookup_result" == completed ]]
}

@test "DISPATCH-009 any-durable short-circuits on a confirmed durable direct tag" {
    load_registry_dispatch
    function docker_hub_tags_by_digest {
        : >"$CALLS_DIR/scanned"
    }
    registry_classify alpine
    registry_direct_tag_confirmed=1

    registry_find_tags_by_digest alpine sha256:one any-durable 1.2.3
    [[ "$registry_tags" == 1.2.3 ]]
    [[ "$registry_lookup_backend" == direct-tag-check ]]
    refute_file_exists "$CALLS_DIR/scanned"
}

@test "DISPATCH-016 any short-circuits on a confirmed floating direct tag" {
    load_registry_dispatch
    function docker_hub_tags_by_digest {
        : >"$CALLS_DIR/scanned"
    }
    registry_classify alpine
    registry_direct_tag_confirmed=1

    registry_find_tags_by_digest alpine sha256:one any latest
    [[ "$registry_tags" == latest ]]
    [[ "$registry_lookup_backend" == direct-tag-check ]]
    refute_file_exists "$CALLS_DIR/scanned"
}

@test "DISPATCH-010 absent provider metadata remains empty" {
    load_registry_dispatch
    function docker_hub_tags_by_digest { registry_tags=stable; }
    registry_classify alpine

    registry_find_tags_by_digest alpine sha256:one all '<none>'
    [[ -z "$registry_metadata" ]]
}

@test "DISPATCH-011 ACR unavailable reverse API records Skopeo fallback backend" {
    load_registry_dispatch
    function acr_tags_by_digest_api { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_is_available { return 0; }
    function acr_tags_by_digest_with_skopeo { printf '%s\n' fallback-tag; }
    registry_classify vault.azurecr.io/team/app

    registry_find_tags_by_digest vault.azurecr.io/team/app sha256:one all '<none>'
    [[ "$registry_lookup_backend" == skopeo ]]
    [[ "$registry_tags" == fallback-tag ]]
}

@test "ACR-014 unavailable ACR metadata falls back once and records Skopeo" {
    load_registry_dispatch
    function acr_tags_by_digest_api { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_is_available { return 0; }
    function acr_tags_by_digest_with_skopeo {
        printf '%s\n' "$*" >"$CALLS_DIR/acr-fallback"
        printf '%s\n' fallback
    }
    registry_classify vault.azurecr.io/team/app

    registry_find_tags_by_digest vault.azurecr.io/team/app sha256:one all '<none>'
    [[ "$registry_lookup_backend" == skopeo ]]
    [[ "$registry_tags" == fallback ]]
    [[ $(wc -l <"$CALLS_DIR/acr-fallback") -eq 1 ]]
}

@test "ACR-017 successful ACR metadata reverse lookup records acr-api" {
    load_registry_dispatch
    function acr_tags_by_digest_api { printf '%s\n' stable; }
    registry_classify vault.azurecr.io/team/app

    registry_find_tags_by_digest vault.azurecr.io/team/app sha256:one all '<none>'
    [[ "$registry_lookup_backend" == acr-api ]]
    [[ "$registry_tags" == stable ]]
}

@test "DISPATCH-012 ECR not-found reverse API is authoritative" {
    load_registry_dispatch
    function ecr_tags_by_digest_api { return "$LOOKUP_NOT_FOUND"; }
    function skopeo_is_available { : >"$CALLS_DIR/skopeo"; return 0; }
    registry_classify 123456789012.dkr.ecr.us-west-2.amazonaws.com/app

    registry_find_tags_by_digest \
        123456789012.dkr.ecr.us-west-2.amazonaws.com/app sha256:one all '<none>'
    [[ "$registry_lookup_result" == not_found ]]
    [[ "$registry_lookup_backend" == ecr-api ]]
    refute_file_exists "$CALLS_DIR/skopeo"
}

@test "ECR-010 unavailable private ECR metadata falls back and updates backend" {
    load_registry_dispatch
    function ecr_tags_by_digest_api { return "$LOOKUP_UNAVAILABLE"; }
    function oci_tags_by_digest_anonymously { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_is_available { return 0; }
    function ecr_tags_by_digest_with_skopeo { printf '%s\n' fallback; }
    registry_classify 123456789012.dkr.ecr.us-west-2.amazonaws.com/app

    registry_find_tags_by_digest \
        123456789012.dkr.ecr.us-west-2.amazonaws.com/app sha256:one all '<none>'
    [[ "$registry_lookup_backend" == skopeo ]]
    [[ "$registry_tags" == fallback ]]
}

@test "ECRP-010 successful public metadata and unavailable fallback report actual backends" {
    load_registry_dispatch
    function ecr_public_tags_by_digest_api { printf '%s\n' metadata; }
    registry_classify public.ecr.aws/alias/app
    registry_find_tags_by_digest public.ecr.aws/alias/app sha256:one all '<none>'
    [[ "$registry_lookup_backend" == ecr-api && "$registry_tags" == metadata ]]

    function ecr_public_tags_by_digest_api { return "$LOOKUP_UNAVAILABLE"; }
    function oci_tags_by_digest_anonymously { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_is_available { return 0; }
    function ecr_tags_by_digest_with_skopeo { printf '%s\n' fallback; }
    registry_find_tags_by_digest public.ecr.aws/alias/app sha256:one all '<none>'
    [[ "$registry_lookup_backend" == skopeo && "$registry_tags" == fallback ]]
}

@test "ECRP-013 unavailable signed metadata uses public OCI before Skopeo" {
    load_registry_dispatch
    function ecr_public_tags_by_digest_api { return "$LOOKUP_UNAVAILABLE"; }
    function oci_tags_by_digest_anonymously { printf '%s\n' public-oci; }
    function skopeo_is_available { : >"$CALLS_DIR/unexpected-skopeo"; return 0; }
    registry_classify public.ecr.aws/alias/app

    registry_find_tags_by_digest public.ecr.aws/alias/app sha256:one all '<none>'
    [[ "$registry_lookup_backend" == oci-registry-api ]]
    [[ "$registry_tags" == public-oci ]]
    refute_file_exists "$CALLS_DIR/unexpected-skopeo"
}

@test "GCR-007 GCR metadata and authenticated fallback report actual backends" {
    load_registry_dispatch
    function gcr_tags_by_digest_anonymously { printf '%s\n' metadata; }
    registry_classify gcr.io/project/app
    registry_find_tags_by_digest gcr.io/project/app sha256:one all '<none>'
    [[ "$registry_lookup_backend" == gcr-api && "$registry_tags" == metadata ]]

    function gcr_tags_by_digest_anonymously { return "$LOOKUP_UNAVAILABLE"; }
    function skopeo_is_available { return 0; }
    function skopeo_tags_by_digest_with_access_policy { printf '%s\n' fallback; }
    registry_find_tags_by_digest gcr.io/project/app sha256:one all '<none>'
    [[ "$registry_lookup_backend" == skopeo && "$registry_tags" == fallback ]]
}

@test "DISPATCH-013 stopped GCR reverse lookup never invokes Skopeo" {
    load_registry_dispatch
    function gcr_tags_by_digest_anonymously { return "$LOOKUP_STOPPED"; }
    function skopeo_is_available { : >"$CALLS_DIR/skopeo"; return 0; }
    registry_classify gcr.io/project/app

    run --separate-stderr registry_find_tags_by_digest \
        gcr.io/project/app sha256:one all '<none>'
    assert_status 1
    assert_stderr_contains 'GCR API lookup stopped'
    refute_file_exists "$CALLS_DIR/skopeo"
}

@test "DISPATCH-014 direct dispatch exports an explicit lookup context" {
    load_registry_dispatch
    function docker_hub_digest_for_tag { printf '%s\n' sha256:context; }
    registry_classify alpine
    local -A lookup=()

    registry_resolve_tag_digest alpine latest lookup
    [[ "${lookup[status]}" -eq "$LOOKUP_SUCCEEDED" ]]
    [[ "${lookup[digest]}" == sha256:context ]]
    [[ -z "${lookup[error]}" ]]
}

@test "DISPATCH-015 reverse dispatch exports an explicit lookup context" {
    load_registry_dispatch
    function docker_hub_tags_by_digest { registry_tags=$'latest\n1.2.3'; }
    registry_classify alpine
    local -A lookup=()

    registry_find_tags_by_digest alpine sha256:context all latest lookup
    [[ "${lookup[result]}" == completed ]]
    [[ "${lookup[backend]}" == docker-hub-api ]]
    [[ "${lookup[tags]}" == $'latest\n1.2.3' ]]
}
