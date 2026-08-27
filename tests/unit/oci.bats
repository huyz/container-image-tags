#!/usr/bin/env bats

load ../test-helper.bash

DIGEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

function load_oci {
    load_module oci
}

@test "OCI-001 header parsing is case-insensitive and uses the final status" {
    load_oci
    header="$TEST_ROOT/headers"
    printf 'HTTP/1.1 401 Unauthorized\r\nDocker-Content-Digest: sha256:first\r\n\r\nHTTP/2 200\r\ndocker-content-digest: sha256:second\r\n' >"$header"
    run oci_http_status "$header"
    assert_output_exact 200
    run oci_header_value "$header" Docker-Content-Digest
    assert_output_exact sha256:first
}

@test "OCI-002 next-link parser selects only rel next" {
    load_oci
    header="$TEST_ROOT/headers"
    printf 'Link: </ignored>; rel="previous", </v2/app/tags/list?last=z>; rel="next"\r\n' >"$header"
    run oci_next_link "$header"
    assert_status 0
    assert_output_exact '/v2/app/tags/list?last=z'
}

@test "OCI-004 request header files are mode 0600 with complete Accept value" {
    load_oci
    header="$TEST_ROOT/request.headers"
    oci_write_request_headers "$header" secret-token
    assert_file_mode "$header" 600
    grep -Fxq "$OCI_MANIFEST_ACCEPT_HEADER" "$header"
    grep -Fxq 'Authorization: Bearer secret-token' "$header"
}

@test "OCI-005 bearer challenge requires an HTTPS realm" {
    load_oci
    run oci_token_from_bearer_challenge 'Basic realm="x"' team/app
    assert_status "$LOOKUP_UNAVAILABLE"
    run oci_token_from_bearer_challenge 'Bearer realm="http://token.example"' team/app
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "OCI-006 wildcard bearer scope becomes repository pull scope" {
    load_oci
    export TOKEN_BODY='{"token":"token-value"}'
    write_stub curl <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/curl.args"
output=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -o ]]; then index=$((index + 1)); output="${!index}"; fi
done
printf '%s' "$TOKEN_BODY" >"$output"
printf '200'
EOF
    run oci_token_from_bearer_challenge \
        'Bearer realm="https://auth.example/token",service="registry.example",scope="*"' team/app
    assert_status 0
    assert_output_exact token-value
    args=$(tr '\0' '\n' <"$CALLS_DIR/curl.args")
    [[ "$args" == *'scope=repository:team/app:pull'* ]]
}

@test "OCI-007 token request URL-encodes advertised service and scope exactly" {
    load_oci
    export TOKEN_BODY='{"token":"token-value"}'
    write_stub curl <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/curl.args"
output=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -o ]]; then index=$((index + 1)); output="${!index}"; fi
done
printf '%s' "$TOKEN_BODY" >"$output"
printf '200'
EOF

    run oci_token_from_bearer_challenge \
        'Bearer realm="https://auth.example/token",service="registry.example/a b",scope="repository:team/app:pull,push"' \
        team/app
    assert_status 0
    assert_output_exact token-value
    args=$(tr '\0' '\n' <"$CALLS_DIR/curl.args")
    [[ "$args" == *$'--data-urlencode\nservice=registry.example/a b\n'* ]]
    [[ "$args" == *$'--data-urlencode\nscope=repository:team/app:pull,push\n'* ]]
    [[ "$args" == *'https://auth.example/token'* ]]
}

@test "OCI-008 token response accepts access_token and rejects missing token" {
    load_oci
    export TOKEN_BODY='{"access_token":"alternate"}'
    write_stub curl <<'EOF'
output=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -o ]]; then index=$((index + 1)); output="${!index}"; fi
done
printf '%s' "$TOKEN_BODY" >"$output"
printf '200'
EOF
    run oci_token_from_bearer_challenge 'Bearer realm="https://auth.example/token"' team/app
    assert_status 0
    assert_output_exact alternate
    export TOKEN_BODY='{}'
    run oci_token_from_bearer_challenge 'Bearer realm="https://auth.example/token"' team/app
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "OCI-009 tag listing retries the same page after obtaining one token" {
    load_oci
    write_stub curl <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/curl.args"
url="${!#}"
headers=
body=
for ((index = 1; index <= $#; ++index)); do
    case "${!index}" in
    -D) index=$((index + 1)); headers="${!index}" ;;
    -o) index=$((index + 1)); body="${!index}" ;;
    esac
done
if [[ "$url" == https://auth.example/token ]]; then
    printf '{"token":"repo-token"}' >"$body"; printf '200'
elif [[ ! -e "$CALLS_DIR/challenged" ]]; then
    : >"$CALLS_DIR/challenged"
    printf 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer realm="https://auth.example/token",service="registry.example",scope="repository:team/app:pull"\r\n' >"$headers"
    printf '{}' >"$body"; printf '401'
else
    printf 'HTTP/1.1 200 OK\r\n' >"$headers"
    printf '{"tags":["a","b"]}' >"$body"; printf '200'
fi
EOF
    oci_list_tags_anonymously registry.example team/app
    [[ "$oci_bearer_token" == repo-token ]]
    [[ "$oci_listed_tags" == $'a\nb' ]]
    [[ $(grep -ao 'https://registry.example/v2/team/app/tags/list?n=100' "$CALLS_DIR/curl.args" | wc -l) -eq 2 ]]
}

@test "OCI-010 tag pagination follows safe relative links" {
    load_oci
    write_stub curl <<'EOF'
url="${!#}"; headers=; body=
for ((index = 1; index <= $#; ++index)); do
    case "${!index}" in
    -D) index=$((index + 1)); headers="${!index}" ;;
    -o) index=$((index + 1)); body="${!index}" ;;
    esac
done
if [[ "$url" == *'last=a' ]]; then
    printf 'HTTP/1.1 200 OK\r\n' >"$headers"; printf '{"tags":["b"]}' >"$body"
else
    printf 'HTTP/1.1 200 OK\r\nLink: </v2/team/app/tags/list?n=100&last=a>; rel="next"\r\n' >"$headers"
    printf '{"tags":["a"]}' >"$body"
fi
printf '200'
EOF
    oci_list_tags_anonymously registry.example team/app
    [[ "$oci_listed_tags" == $'a\nb' ]]
}

@test "OCI-003 unsafe cross-host pagination is unavailable" {
    load_oci
    write_stub curl <<'EOF'
headers=; body=
for ((index = 1; index <= $#; ++index)); do
    case "${!index}" in
    -D) index=$((index + 1)); headers="${!index}" ;;
    -o) index=$((index + 1)); body="${!index}" ;;
    esac
done
printf 'HTTP/1.1 200 OK\r\nLink: <https://evil.example/next>; rel="next"\r\n' >"$headers"
printf '{"tags":["a"]}' >"$body"; printf '200'
EOF
    run oci_list_tags_anonymously registry.example team/app
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "OCI-011 malformed page cannot produce partial success" {
    load_oci
    write_stub curl <<'EOF'
headers=; body=
for ((index = 1; index <= $#; ++index)); do
    case "${!index}" in
    -D) index=$((index + 1)); headers="${!index}" ;;
    -o) index=$((index + 1)); body="${!index}" ;;
    esac
done
printf 'HTTP/1.1 200 OK\r\n' >"$headers"
printf '{"tags":"not-an-array"}' >"$body"; printf '200'
EOF
    run oci_list_tags_anonymously registry.example team/app
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "OCI-012 tag-list HTTP statuses preserve named outcomes" {
    load_oci
    for pair in '404 1' '403 3' '429 4' '500 2'; do
        set -- $pair
        export RESPONSE_CODE="$1"
        write_stub curl <<'EOF'
headers=; body=
for ((index = 1; index <= $#; ++index)); do
    case "${!index}" in
    -D) index=$((index + 1)); headers="${!index}" ;;
    -o) index=$((index + 1)); body="${!index}" ;;
    esac
done
printf 'HTTP/1.1 %s Result\r\n' "$RESPONSE_CODE" >"$headers"
printf '{}' >"$body"; printf '%s' "$RESPONSE_CODE"
EOF
        run oci_list_tags_anonymously registry.example team/app
        assert_status "$2"
    done
}

@test "OCI-013 manifest tags are URL encoded exactly" {
    load_oci
    header="$TEST_ROOT/request"; oci_write_request_headers "$header"
    write_stub curl <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/curl.args"; headers=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -D ]]; then index=$((index + 1)); headers="${!index}"; fi
done
printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:value\r\n' >"$headers"; printf '200'
EOF
    run oci_digest_for_tag_with_headers registry.example 'release candidate' team/app "$header"
    assert_status 0
    args=$(tr '\0' '\n' <"$CALLS_DIR/curl.args")
    [[ "$args" == *'/manifests/release%20candidate'* ]]
}

@test "OCI-014 manifest HEAD extracts the complete digest" {
    load_oci
    header="$TEST_ROOT/request"; oci_write_request_headers "$header"
    write_stub curl <<'EOF'
headers=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -D ]]; then index=$((index + 1)); headers="${!index}"; fi
done
printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:complete\r\n' >"$headers"; printf '200'
EOF
    run oci_digest_for_tag_with_headers registry.example stable team/app "$header"
    assert_status 0
    assert_output_exact sha256:complete
}

@test "OCI-015 missing digest header is unavailable" {
    load_oci
    header="$TEST_ROOT/request"; oci_write_request_headers "$header"
    write_stub curl <<'EOF'
headers=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -D ]]; then index=$((index + 1)); headers="${!index}"; fi
done
printf 'HTTP/1.1 200 OK\r\n' >"$headers"; printf '200'
EOF
    run oci_digest_for_tag_with_headers registry.example stable team/app "$header"
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "OCI-016 exhaustive multi-tag lookup selects curl parallel engine" {
    load_oci
    registry_tag_scan=all; registry_direct_tag=
    function oci_list_tags_anonymously { oci_listed_tags=$'a\nb'; oci_bearer_token=; }
    function registry_expensive_scan_preflight { return 0; }
    function oci_curl_supports_parallel { return 0; }
    function oci_tags_by_digest_with_curl_parallel {
        : >"$CALLS_DIR/parallel"; printf '%s\n' a
    }
    function tags_by_digest_with_rolling_pool { : >"$CALLS_DIR/pool"; }
    run oci_tags_by_digest_anonymously registry.example team/app "$DIGEST"
    assert_status 0
    assert_output_exact a
    assert_file_exists "$CALLS_DIR/parallel"
    refute_file_exists "$CALLS_DIR/pool"
}

@test "OCI-017 any mode selects the rolling pool even with parallel curl" {
    load_oci
    registry_tag_scan=any; registry_direct_tag=direct
    function oci_list_tags_anonymously { oci_listed_tags=$'direct\na\nb'; oci_bearer_token=; }
    function registry_expensive_scan_preflight { return 0; }
    function oci_curl_supports_parallel { return 0; }
    function oci_tags_by_digest_with_curl_parallel { : >"$CALLS_DIR/parallel"; }
    function tags_by_digest_with_rolling_pool { : >"$CALLS_DIR/pool"; printf '%s\n' a; }
    run oci_tags_by_digest_anonymously registry.example team/app "$DIGEST"
    assert_status 0
    assert_output_exact a
    assert_file_exists "$CALLS_DIR/pool"
    refute_file_exists "$CALLS_DIR/parallel"
}

@test "OCI-025 pool feature flag forces the rolling pool for exhaustive scans" {
    load_oci
    export CIT_OCI_SCAN_ENGINE=pool
    registry_tag_scan=all; registry_direct_tag=
    function oci_list_tags_anonymously { oci_listed_tags=$'a\nb'; oci_bearer_token=; }
    function registry_expensive_scan_preflight { return 0; }
    function oci_curl_supports_parallel { return 0; }
    function oci_tags_by_digest_with_curl_parallel { : >"$CALLS_DIR/parallel"; }
    function tags_by_digest_with_rolling_pool { : >"$CALLS_DIR/pool"; printf '%s\n' a; }

    run oci_tags_by_digest_anonymously registry.example team/app "$DIGEST"
    assert_status 0
    assert_output_exact a
    assert_file_exists "$CALLS_DIR/pool"
    refute_file_exists "$CALLS_DIR/parallel"
}

@test "OCI-026 forced parallel engine fails fast when curl lacks support" {
    load_oci
    export CIT_OCI_SCAN_ENGINE=parallel
    export TMPDIR="$TEST_ROOT/engine-tmp"
    mkdir -p "$TMPDIR"
    registry_tag_scan=all; registry_direct_tag=
    function oci_list_tags_anonymously { oci_listed_tags=$'a\nb'; oci_bearer_token=; }
    function registry_expensive_scan_preflight { return 0; }
    function oci_curl_supports_parallel { return 1; }

    run --separate-stderr oci_tags_by_digest_anonymously \
        registry.example team/app "$DIGEST"
    assert_status 1
    assert_stderr_contains 'requires curl --parallel-max support'
    [[ -z $(find "$TMPDIR" -mindepth 1 -print -quit) ]]
}

@test "OCI-027 invalid scan engine is rejected" {
    load_oci
    export CIT_OCI_SCAN_ENGINE=invalid
    export TMPDIR="$TEST_ROOT/engine-tmp"
    mkdir -p "$TMPDIR"
    registry_tag_scan=all; registry_direct_tag=
    function oci_list_tags_anonymously { oci_listed_tags=a; oci_bearer_token=; }
    function registry_expensive_scan_preflight { return 0; }

    run --separate-stderr oci_tags_by_digest_anonymously \
        registry.example team/app "$DIGEST"
    assert_status 1
    assert_stderr_contains "must be 'auto', 'parallel', or 'pool'"
    [[ -z $(find "$TMPDIR" -mindepth 1 -print -quit) ]]
}

@test "OCI-018 exhaustive OCI lookup caps curl parallelism at eight" {
    load_oci
    registry_tag_scan=all; registry_direct_tag=
    function oci_list_tags_anonymously {
        oci_listed_tags=$(printf 'tag-%02d\n' {1..20})
        oci_bearer_token=
    }
    function registry_expensive_scan_preflight { return 0; }
    function oci_curl_supports_parallel { return 0; }
    function oci_tags_by_digest_with_curl_parallel {
        printf '%s\n' "$5" >"$CALLS_DIR/parallel-jobs"
    }

    run oci_tags_by_digest_anonymously registry.example team/app "$DIGEST"
    assert_status 0
    [[ $(<"$CALLS_DIR/parallel-jobs") -eq 8 ]]
}

@test "OCI-019 curl parallel results retain candidate order" {
    load_oci
    function is_interactive_session { return 1; }
    candidates=(first second third)
    headers="$TEST_ROOT/request"; oci_write_request_headers "$headers"
    export PARALLEL_DIGEST="$DIGEST"
    write_stub curl <<'EOF'
config="$2"; index=0
while IFS= read -r line; do
    case "$line" in
    'dump-header = '* )
        path="${line#*\"}"; path="${path%\"}"
        if [[ "$index" == 1 ]]; then digest=sha256:other; else digest="$PARALLEL_DIGEST"; fi
        printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: %s\r\n' "$digest" >"$path"
        index=$((index + 1))
        ;;
    esac
done <"$config"
EOF
    run oci_tags_by_digest_with_curl_parallel registry.example team/app "$DIGEST" \
        candidates 3 "$headers"
    assert_status 0
    assert_output_exact $'first\nthird'
}

@test "OCI-020 parallel 429 cancels queued work and returns stopped promptly" {
    load_oci
    function is_interactive_session { return 1; }
    candidates=(first second third)
    headers="$TEST_ROOT/request"; oci_write_request_headers "$headers"
    write_stub curl <<'EOF'
config="$2"
while IFS= read -r line; do
    case "$line" in
    'dump-header = '* )
        path="${line#*\"}"; path="${path%\"}"
        printf 'HTTP/1.1 429 Too Many Requests\r\n' >"$path"
        break
        ;;
    esac
done <"$config"
sleep 5
EOF
    start=$SECONDS
    run oci_tags_by_digest_with_curl_parallel registry.example team/app "$DIGEST" \
        candidates 3 "$headers"
    elapsed=$((SECONDS - start))
    assert_status "$LOOKUP_STOPPED"
    ((elapsed < 3))
}

@test "OCI-023 bearer token is never present in curl argv" {
    load_oci
    header="$TEST_ROOT/request"; canary=oci-secret-canary
    oci_write_request_headers "$header" "$canary"
    write_stub curl <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/curl.args"; headers=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -D ]]; then index=$((index + 1)); headers="${!index}"; fi
done
printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:value\r\n' >"$headers"; printf '200'
EOF
    run oci_digest_for_tag_with_headers registry.example stable team/app "$header"
    assert_status 0
    ! grep -aFq "$canary" "$CALLS_DIR/curl.args"
}

@test "OCI-024 handled OCI exits remove request response and header temporary files" {
    load_oci
    export TMPDIR="$TEST_ROOT/oci-tmp"
    mkdir -p "$TMPDIR"
    write_stub curl <<'EOF'
headers=; body=
for ((index = 1; index <= $#; ++index)); do
    case "${!index}" in
    -D) index=$((index + 1)); headers="${!index}" ;;
    -o) index=$((index + 1)); body="${!index}" ;;
    esac
done
[[ -z "$headers" ]] || printf 'HTTP/1.1 500 Server Error\r\n' >"$headers"
[[ -z "$body" || "$body" == /dev/null ]] || printf '{}' >"$body"
printf '500'
EOF

    run oci_list_tags_anonymously registry.example team/app
    assert_status "$LOOKUP_UNAVAILABLE"
    [[ -z $(find "$TMPDIR" -mindepth 1 -print -quit) ]]

    run oci_digest_for_tag_anonymously registry.example team/app stable
    assert_status "$LOOKUP_UNAVAILABLE"
    [[ -z $(find "$TMPDIR" -mindepth 1 -print -quit) ]]
}
