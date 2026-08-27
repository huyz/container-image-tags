#!/usr/bin/env bats

load ../test-helper.bash

DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

function load_acr {
    load_module acr
}

function install_acr_curl {
    export FAKE_HTTP_CODE="${1:-200}"
    if (($# >= 2)); then
        export FAKE_HTTP_BODY="$2"
    else
        export FAKE_HTTP_BODY='{}'
    fi
    export FAKE_CURL_STATUS="${3:-0}"
    write_stub curl <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/curl.args"
output=
for ((index = 1; index <= $#; ++index)); do
    argument="${!index}"
    if [[ "$argument" == -o ]]; then
        index=$((index + 1)); output="${!index}"
    fi
done
[[ -z "$output" ]] || printf '%s' "$FAKE_HTTP_BODY" >"$output"
((FAKE_CURL_STATUS == 0)) || exit "$FAKE_CURL_STATUS"
printf '%s' "$FAKE_HTTP_CODE"
EOF
}

@test "ACR-001 registry name and sovereign suffix extraction are exact" {
    load_acr

    run acr_registry_name vault.azurecr.io
    assert_output_exact vault
    run acr_registry_name vault-microsoft.azurecr.us
    assert_output_exact vault
    run acr_registry_suffix vault-microsoft.azurecr.us
    assert_output_exact microsoft
    run acr_registry_suffix vault.azurecr.io
    assert_status 1
}

@test "ACR-002 anonymous tag metadata uses the exact documented URL" {
    load_acr
    install_acr_curl 200 '{"digest":"sha256:a"}'

    run acr_metadata_anonymously vault.azurecr.io team/app tag stable
    assert_status 0
    assert_output_exact '{"digest":"sha256:a"}'
    args=$(tr '\0' '\n' <"$CALLS_DIR/curl.args")
    [[ "$args" == *'https://vault.azurecr.io/acr/v1/team/app/_tags/stable?api-version=2021-07-01'* ]]
}

@test "ACR-003 HTTP 200 returns artifact metadata body" {
    load_acr
    install_acr_curl 200 '{"manifest":{"digest":"sha256:a"}}'

    run acr_metadata_anonymously vault.azurecr.io team/app manifest sha256:a
    assert_status "$LOOKUP_SUCCEEDED"
    assert_output_exact '{"manifest":{"digest":"sha256:a"}}'
}

@test "ACR-004 anonymous denial permits Azure CLI metadata lookup" {
    load_acr
    install_acr_curl 401 '{"errors":[{"message":"authorization required"}]}'
    write_stub az <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/az.args"
printf '%s\n' '{"digest":"sha256:authenticated"}'
EOF

    run --separate-stderr acr_metadata vault.azurecr.io team/app tag stable
    assert_status 0
    assert_output_exact '{"digest":"sha256:authenticated"}'
    assert_stderr_contains 'requesting artifact metadata through Azure CLI'
    assert_file_exists "$CALLS_DIR/az.args"
}

@test "ACR-005 HTTP 404 is authoritative and does not invoke Azure" {
    load_acr
    install_acr_curl 404 '{}'
    write_stub az <<'EOF'
: >"$CALLS_DIR/az"
EOF

    run acr_metadata vault.azurecr.io team/app tag absent
    assert_status "$LOOKUP_NOT_FOUND"
    refute_file_exists "$CALLS_DIR/az"
}

@test "ACR-006 HTTP 429 is terminal and does not invoke Azure" {
    load_acr
    install_acr_curl 429 '{"message":"slow down"}'
    write_stub az <<'EOF'
: >"$CALLS_DIR/az"
EOF

    run --separate-stderr acr_metadata vault.azurecr.io team/app tag stable
    assert_status "$LOOKUP_STOPPED"
    assert_stderr_contains 'rate limit reached'
    refute_file_exists "$CALLS_DIR/az"
}

@test "ACR-007 transport and server failures are unavailable" {
    load_acr
    install_acr_curl 500 '{}' 7

    run acr_metadata_anonymously vault.azurecr.io team/app tag stable
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "ACR-008 Azure CLI receives exact registry image and sovereign suffix" {
    load_acr
    write_stub az <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/az.args"
printf '%s\n' '{"digest":"sha256:a"}'
EOF

    run acr_metadata_with_azure_cli vault-microsoft.azurecr.us team/app tag stable
    assert_status 0
    assert_call_args "$CALLS_DIR/az.args" acr manifest show-metadata --registry vault \
        --name team/app:stable --output json --only-show-errors --suffix microsoft
}

@test "ACR-009 Azure CLI not-found output maps to not found" {
    load_acr
    write_stub az <<'EOF'
printf '%s\n' 'manifest unknown' >&2
exit 3
EOF

    run acr_metadata_with_azure_cli vault.azurecr.io team/app tag absent
    assert_status "$LOOKUP_NOT_FOUND"
}

@test "ACR-010 Azure CLI failures are unavailable with single-line debug context" {
    load_acr
    opt_debug=1
    write_stub az <<'EOF'
printf 'first line\nsecond line with context\n' >&2
exit 3
EOF

    run --separate-stderr acr_metadata_with_azure_cli \
        vault.azurecr.io team/app tag stable
    assert_status "$LOOKUP_UNAVAILABLE"
    assert_stderr_contains 'DEBUG: Azure CLI metadata lookup failed'
    assert_stderr_contains 'first line second line with context'
    [[ $(grep -c 'DEBUG:' <<<"$stderr") -eq 1 ]]
}

@test "ACR-011 direct metadata accepts both response shapes" {
    load_acr
    function acr_metadata { printf '%s\n' '{"tag":{"name":"stable","digest":"sha256:one"}}'; }

    run acr_digest_for_tag vault.azurecr.io team/app stable vault.azurecr.io/team/app:stable
    assert_status 0
    assert_output_exact sha256:one

    function acr_metadata { printf '%s\n' '{"digest":"sha256:two"}'; }
    run acr_digest_for_tag vault.azurecr.io team/app stable vault.azurecr.io/team/app:stable
    assert_output_exact sha256:two
}

@test "ACR-012 reverse metadata requires the complete requested digest" {
    load_acr
    registry_tag_scan=all
    registry_direct_tag=
    function acr_metadata { printf '%s\n' '{"manifest":{"digest":"sha256:different","tags":["stable"]}}'; }

    run acr_tags_by_digest_api vault.azurecr.io team/app "$DIGEST"
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "ACR-013 any returns matches through a durable tag and all deduplicates" {
    load_acr
    function acr_metadata {
        printf '{"manifest":{"digest":"%s","tags":["stable","1.2","1.2.3","1.2.3"]}}\n' "$DIGEST"
    }
    registry_direct_tag=stable
    registry_direct_tag_confirmed=1
    registry_tag_scan=any

    run acr_tags_by_digest_api vault.azurecr.io team/app "$DIGEST"
    assert_status 0
    assert_output_exact $'stable\n1.2\n1.2.3'

    registry_tag_scan=all
    run acr_tags_by_digest_api vault.azurecr.io team/app "$DIGEST"
    assert_output_exact $'1.2\n1.2.3\nstable'
}

@test "ACR-015 anonymous and configured Skopeo attempts precede Azure login" {
    load_common
    # shellcheck source=../../lib/skopeo.sh
    source "$REPO_ROOT/lib/skopeo.sh"
    # shellcheck source=../../lib/acr.sh
    source "$REPO_ROOT/lib/acr.sh"
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
    function fake_acr_authenticate { printf '%s\n' azure >>"$CALLS_DIR/order"; }

    run --separate-stderr skopeo_digest_for_tag_with_lazy_auth \
        vault.azurecr.io vault.azurecr.io/team/app:stable fake_acr_authenticate
    assert_status 0
    assert_output_exact sha256:ok
    assert_stderr_contains 'Using configured registry credentials'
    [[ $(<"$CALLS_DIR/order") == $'anonymous\nconfigured\nazure\nsession' ]]
}

@test "ACR-016 Azure login token travels through stdin to a mode-0600 authfile" {
    load_acr
    skopeo_session_authfile="$TEST_ROOT/session-auth.json"
    : >"$skopeo_session_authfile"
    chmod 600 "$skopeo_session_authfile"
    export AZURE_CANARY=azure-secret-canary
    write_stub az <<'EOF'
printf '%s\n' "$AZURE_CANARY"
EOF
    write_stub skopeo <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/skopeo.args"
IFS= read -r secret
printf '%s' "$secret" >"$CALLS_DIR/skopeo.stdin"
EOF

    run acr_authenticate vault.azurecr.io
    assert_status 0
    [[ $(<"$CALLS_DIR/skopeo.stdin") == "$AZURE_CANARY" ]]
    args=$(tr '\0' '\n' <"$CALLS_DIR/skopeo.args")
    [[ "$args" == *'--password-stdin'* ]]
    [[ "$args" != *"$AZURE_CANARY"* ]]
    assert_file_mode "$skopeo_session_authfile" 600
}
