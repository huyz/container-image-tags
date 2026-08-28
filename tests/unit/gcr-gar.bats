#!/usr/bin/env bats

load ../test-helper.bash

DIGEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

function load_gcr {
    load_module gcr
}

function install_gcr_curl {
    export GCR_HTTP_CODE="${1:-200}"
    export GCR_BODY="${2-}"
    export GCR_CURL_STATUS="${3:-0}"
    write_stub curl <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/curl.args"
output=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -o ]]; then
        index=$((index + 1)); output="${!index}"
    elif [[ "${!index}" == @* ]]; then
        cp "${!index#@}" "$CALLS_DIR/curl.headers"
    fi
done
[[ -z "$output" ]] || printf '%s' "$GCR_BODY" >"$output"
((GCR_CURL_STATUS == 0)) || exit "$GCR_CURL_STATUS"
printf '%s' "$GCR_HTTP_CODE"
EOF
}

@test "GCR-001 anonymous metadata uses the exact tags-list URL" {
    load_gcr
    install_gcr_curl 200 '{"manifest":{}}'

    run gcr_metadata_anonymously gcr.io project/app
    assert_status 0
    args=$(tr '\0' '\n' <"$CALLS_DIR/curl.args")
    [[ "$args" == *'https://gcr.io/v2/project/app/tags/list'* ]]
}

@test "GCR-002 successful response must contain a manifest object" {
    load_gcr
    install_gcr_curl 200 '{"tags":["latest"]}'

    run gcr_metadata_anonymously gcr.io project/app
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "GCR-003 direct tag selection uses exact membership and digest" {
    load_gcr
    function gcr_metadata_anonymously {
        printf '%s\n' '{"manifest":{"sha256:one":{"tag":["stable"]},"sha256:two":{"tag":["stables"]}}}'
    }

    run gcr_digest_for_tag_anonymously gcr.io project/app stable
    assert_status 0
    assert_output_exact sha256:one
}

@test "GCR-004 reverse lookup matches the full digest and any-durable returns a durable tag" {
    load_gcr
    function gcr_metadata_anonymously {
        printf '{"manifest":{"%s":{"tag":["stable","1.2.3"]},"sha256:prefix":{"tag":["1.2","wrong"]}}}\n' "$DIGEST"
    }
    registry_tag_scan=any-durable
    registry_direct_tag=stable
    registry_direct_tag_confirmed=1

    run gcr_tags_by_digest_anonymously gcr.io project/app "$DIGEST"
    assert_status 0
    assert_output_exact $'stable\n1.2.3'
}

@test "GCR-005 HTTP outcomes map not-found denied stopped and unavailable" {
    load_gcr

    install_gcr_curl 404 '{}'
    run gcr_metadata_anonymously gcr.io project/app
    assert_status "$LOOKUP_NOT_FOUND"

    install_gcr_curl 403 '{"message":"denied"}'
    run gcr_metadata_anonymously gcr.io project/app
    assert_status "$LOOKUP_DENIED"

    install_gcr_curl 429 '{"message":"slow down"}'
    run gcr_metadata_anonymously gcr.io project/app
    assert_status "$LOOKUP_STOPPED"

    install_gcr_curl 500 '{}'
    run gcr_metadata_anonymously gcr.io project/app
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "GCR-006 transport failures are unavailable for authenticated fallback" {
    load_gcr
    install_gcr_curl 000 '' 7

    run gcr_metadata_anonymously gcr.io project/app
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "GAR-001 public success uses OCI and does not invoke gcloud" {
    load_module gar
    function oci_digest_for_tag_anonymously { printf '%s\n' sha256:public; }
    write_stub gcloud <<'EOF'
: >"$CALLS_DIR/gcloud"
exit 99
EOF

    run gar_digest_for_tag us-docker.pkg.dev project/repo/app stable \
        us-docker.pkg.dev/project/repo/app:stable
    assert_status 0
    assert_output_exact sha256:public
    refute_file_exists "$CALLS_DIR/gcloud"
}

@test "GAR-002 denial tries configured credentials before requesting gcloud token" {
    load_common
    # shellcheck source=../../lib/skopeo.sh
    source "$REPO_ROOT/lib/skopeo.sh"
    # shellcheck source=../../lib/gar.sh
    source "$REPO_ROOT/lib/gar.sh"
    skopeo_anonymous_authfile="$TEST_ROOT/anonymous.json"
    skopeo_session_authfile="$TEST_ROOT/session.json"
    function skopeo_session_has_registry { return 1; }
    function skopeo_has_registry_credentials { return 0; }
    function skopeo_digest_for_tag_with_status {
        case "${2-}" in
        "$skopeo_anonymous_authfile") printf '%s\n' anonymous >>"$CALLS_DIR/order"; return "$LOOKUP_DENIED" ;;
        '') printf '%s\n' configured >>"$CALLS_DIR/order"; return "$LOOKUP_DENIED" ;;
        "$skopeo_session_authfile") printf '%s\n' session >>"$CALLS_DIR/order"; printf '%s\n' sha256:ok ;;
        esac
    }
    function fake_gar_authenticate { printf '%s\n' gcloud >>"$CALLS_DIR/order"; }

    run --separate-stderr skopeo_digest_for_tag_with_lazy_auth \
        us-docker.pkg.dev us-docker.pkg.dev/project/repo/app:stable \
        fake_gar_authenticate
    assert_status 0
    assert_output_exact sha256:ok
    assert_stderr_contains 'Using configured registry credentials'
    [[ $(<"$CALLS_DIR/order") == $'anonymous\nconfigured\ngcloud\nsession' ]]
}

@test "GAR-003 gcloud authentication uses exact quiet access-token command" {
    load_module gar
    skopeo_session_authfile="$TEST_ROOT/google-auth.json"
    : >"$skopeo_session_authfile"
    export GOOGLE_CANARY=google-token-canary
    write_stub gcloud <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/gcloud.args"
printf '%s\n' "$GOOGLE_CANARY"
EOF
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/skopeo.args"
IFS= read -r token
printf '%s' "$token" >"$CALLS_DIR/skopeo.stdin"
EOF

    run gar_authenticate us-docker.pkg.dev
    assert_status 0
    assert_call_args "$CALLS_DIR/gcloud.args" auth print-access-token --quiet
    [[ $(<"$CALLS_DIR/skopeo.stdin") == "$GOOGLE_CANARY" ]]
}

@test "GAR-004 Google token uses oauth2accesstoken and password stdin" {
    load_module gar
    skopeo_session_authfile="$TEST_ROOT/google-auth.json"
    : >"$skopeo_session_authfile"
    write_stub gcloud <<'EOF'
printf '%s\n' token
EOF
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/skopeo.args"
cat >/dev/null
EOF

    run gar_authenticate gcr.io
    assert_status 0
    args=$(tr '\0' '\n' <"$CALLS_DIR/skopeo.args")
    [[ "$args" == *'oauth2accesstoken'* ]]
    [[ "$args" == *'--password-stdin'* ]]
}

@test "GAR-005 denial detail only invokes Docker in debug mode" {
    load_module gar
    write_stub docker <<'EOF'
: >"$CALLS_DIR/docker"
printf '%s\n' 'denied: permission missing' >&2
exit 1
EOF

    run gar_debug_denial_detail gcr.io/project/app:stable
    assert_status 1
    refute_file_exists "$CALLS_DIR/docker"

    opt_debug=1
    run --separate-stderr gar_debug_denial_detail gcr.io/project/app:stable
    assert_status 0
    assert_output_exact 'permission missing'
}

@test "GAR-006 non-denial statuses propagate without debug fallback" {
    load_module gar
    function oci_digest_for_tag_anonymously { return "$LOOKUP_STOPPED"; }
    function gar_debug_denial_detail { : >"$CALLS_DIR/debug"; }

    run gar_digest_for_tag gcr.io project/app stable gcr.io/project/app:stable
    assert_status "$LOOKUP_STOPPED"
    refute_file_exists "$CALLS_DIR/debug"
}

@test "GAR-007 denial reuses a Google token with the OCI fast path" {
    load_module gar
    function oci_digest_for_tag_anonymously {
        printf '%s\n' public >>"$CALLS_DIR/order"
        return "$LOOKUP_DENIED"
    }
    function gar_access_token {
        printf '%s\n' token >>"$CALLS_DIR/order"
        printf '%s\n' short-lived-token
    }
    function oci_digest_for_tag_with_bearer_token {
        printf 'authenticated:%s\n' "$4" >>"$CALLS_DIR/order"
        printf '%s\n' sha256:authenticated
    }
    function skopeo_is_available { : >"$CALLS_DIR/unexpected-skopeo"; return 0; }

    run gar_digest_for_tag us-docker.pkg.dev project/repo/app stable \
        us-docker.pkg.dev/project/repo/app:stable
    assert_status 0
    assert_output_exact sha256:authenticated
    [[ $(<"$CALLS_DIR/order") == $'public\ntoken\nauthenticated:short-lived-token' ]]
    refute_file_exists "$CALLS_DIR/unexpected-skopeo"
}

@test "GAR-008 DockerImage metadata uses the exact digest resource and a header file" {
    load_module gar
    export GCR_BODY='{"uri":"us-docker.pkg.dev/project/repo/team/app@'"$DIGEST"'","tags":["us-docker.pkg.dev/project/repo/team/app:stable"]}'
    install_gcr_curl 200 "$GCR_BODY"

    run gar_docker_image_metadata us-docker.pkg.dev \
        us-docker.pkg.dev/project/repo/team/app "$DIGEST" google-token-canary
    assert_status 0
    assert_output_exact "$GCR_BODY"
    args=$(tr '\0' '\n' <"$CALLS_DIR/curl.args")
    [[ "$args" == *"https://artifactregistry.googleapis.com/v1/projects/project/locations/us/repositories/repo/dockerImages/team%2Fapp%40sha256%3A"* ]]
    [[ "$args" != *google-token-canary* ]]
    [[ $(<"$CALLS_DIR/curl.headers") == 'Authorization: Bearer google-token-canary' ]]
}

@test "GAR-009 API resource parsing restores domain-scoped project IDs" {
    load_module gar

    run gar_api_resource_parts us-west1-docker.pkg.dev \
        us-west1-docker.pkg.dev/example.com/my-project/my-repo/team/app
    assert_status 0
    assert_output_exact $'us-west1\nexample.com:my-project\nmy-repo\nteam/app'
}

@test "GAR-010 DockerImage response validation and HTTP statuses preserve safe fallback" {
    load_module gar

    install_gcr_curl 200 '{"uri":"us-docker.pkg.dev/project/repo/app@sha256:wrong","tags":[]}'
    run gar_docker_image_metadata us-docker.pkg.dev \
        us-docker.pkg.dev/project/repo/app "$DIGEST" token
    assert_status "$LOOKUP_UNAVAILABLE"

    install_gcr_curl 403 '{"error":{"message":"denied"}}'
    run gar_docker_image_metadata us-docker.pkg.dev \
        us-docker.pkg.dev/project/repo/app "$DIGEST" token
    assert_status "$LOOKUP_DENIED"

    # A remote or virtual repository may resolve an image that is absent from
    # its metadata index, so an API 404 must still be verified through OCI.
    install_gcr_curl 404 '{"error":{"message":"missing"}}'
    run gar_docker_image_metadata us-docker.pkg.dev \
        us-docker.pkg.dev/project/repo/app "$DIGEST" token
    assert_status "$LOOKUP_UNAVAILABLE"

    install_gcr_curl 429 '{"error":{"message":"slow down"}}'
    run gar_docker_image_metadata us-docker.pkg.dev \
        us-docker.pkg.dev/project/repo/app "$DIGEST" token
    assert_status "$LOOKUP_STOPPED"
}

@test "GAR-011 DockerImage tags preserve provider order and bounded scan semantics" {
    load_module gar
    function gar_docker_image_metadata {
        printf '{"uri":"unused","tags":["us-docker.pkg.dev/project/repo/app:latest","us-docker.pkg.dev/project/repo/app:1.2.3","us-docker.pkg.dev/project/repo/app:latest"]}\n'
    }
    registry_tag_scan=any-durable

    run gar_tags_by_digest_api us-docker.pkg.dev \
        us-docker.pkg.dev/project/repo/app "$DIGEST" token
    assert_status 0
    assert_output_exact $'latest\n1.2.3'
}

@test "GAR-012 if-faster uses available DockerImage metadata before public OCI" {
    load_module gar
    function gar_access_token_if_available { printf '%s\n' token; }
    function gar_tags_by_digest_api {
        printf '%s\n' metadata >>"$CALLS_DIR/order"
        printf '%s\n' stable
    }
    function oci_tags_by_digest_anonymously {
        : >"$CALLS_DIR/unexpected-oci"
    }

    gar_find_tags us-docker.pkg.dev us-docker.pkg.dev/project/repo/app "$DIGEST"
    [[ "$registry_lookup_backend" == gar-api ]]
    [[ "$registry_tags" == stable ]]
    [[ $(<"$CALLS_DIR/order") == metadata ]]
    refute_file_exists "$CALLS_DIR/unexpected-oci"
}

@test "GAR-013 if-faster without configured Google credentials retains public OCI" {
    load_module gar
    function gar_access_token_if_available { return "$LOOKUP_UNAVAILABLE"; }
    function gar_tags_by_digest_api { : >"$CALLS_DIR/unexpected-api"; }
    function oci_tags_by_digest_anonymously { printf '%s\n' public; }

    gar_find_tags us-docker.pkg.dev us-docker.pkg.dev/project/repo/app "$DIGEST"
    [[ "$registry_lookup_backend" == oci-registry-api ]]
    [[ "$registry_tags" == public ]]
    refute_file_exists "$CALLS_DIR/unexpected-api"
}

@test "GAR-014 if-required tries public OCI before authenticated metadata" {
    load_module gar
    opt_credential_policy=if-required
    function oci_tags_by_digest_anonymously {
        printf '%s\n' public >>"$CALLS_DIR/order"
        return "$LOOKUP_DENIED"
    }
    function gar_access_token {
        printf '%s\n' token >>"$CALLS_DIR/order"
        printf '%s\n' short-lived-token
    }
    function gar_tags_by_digest_api {
        printf 'metadata:%s\n' "$4" >>"$CALLS_DIR/order"
        printf '%s\n' private
    }

    gar_find_tags us-docker.pkg.dev us-docker.pkg.dev/project/repo/app "$DIGEST"
    [[ "$registry_lookup_backend" == gar-api ]]
    [[ "$registry_tags" == private ]]
    [[ $(<"$CALLS_DIR/order") == $'public\ntoken\nmetadata:short-lived-token' ]]
}

@test "GAR-015 unavailable metadata falls back to public OCI without claiming not-found" {
    load_module gar
    registry_lookup_result=completed
    function gar_access_token_if_available { printf '%s\n' token; }
    function gar_tags_by_digest_api { return "$LOOKUP_UNAVAILABLE"; }
    function oci_tags_by_digest_anonymously { printf '%s\n' public; }

    gar_find_tags us-docker.pkg.dev us-docker.pkg.dev/project/repo/app "$DIGEST"
    [[ "$registry_lookup_backend" == oci-registry-api ]]
    [[ "$registry_lookup_result" == completed ]]
    [[ "$registry_tags" == public ]]
}
