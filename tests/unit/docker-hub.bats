#!/usr/bin/env bats

load ../test-helper.bash

DIGEST=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

function load_hub {
    load_module docker-hub
    docker_hub_token=
}

function install_hub_response {
    export HUB_CODE="${1:-200}"
    export HUB_BODY="${2-}"
    write_stub curl <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/curl.args"
output=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -o ]]; then index=$((index + 1)); output="${!index}"; fi
done
[[ -z "$output" ]] || printf '%s' "$HUB_BODY" >"$output"
printf '%s' "$HUB_CODE"
EOF
}

@test "HUB-001 repository normalization handles aliases and official images" {
    load_hub
    for pair in 'alpine library/alpine' 'team/app team/app' \
        'docker.io/team/app team/app' 'index.docker.io/alpine library/alpine' \
        'registry-1.docker.io/team/app team/app'; do
        set -- $pair
        run docker_hub_repository "$1"
        assert_status 0
        assert_output_exact "$2"
    done
}

@test "HUB-002 direct tag lookup returns one complete digest" {
    load_hub
    install_hub_response 200 "{\"digest\":\"sha256:$DIGEST\"}"

    run docker_hub_digest_for_tag library/alpine latest
    assert_status 0
    assert_output_exact "sha256:$DIGEST"
}

@test "HUB-003 direct tag lookup distinguishes not-found from unavailable" {
    load_hub
    install_hub_response 404 '{}'
    run docker_hub_digest_for_tag library/alpine absent
    assert_status "$LOOKUP_NOT_FOUND"

    install_hub_response 200 '{}'
    run docker_hub_digest_for_tag library/alpine latest
    assert_status "$LOOKUP_UNAVAILABLE"
}

@test "HUB-004 reverse lookup follows pagination until next is empty" {
    load_hub
    registry_tag_scan=all; registry_direct_tag=; registry_tags=; skip_input=
    write_stub curl <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/curl.args"
url="${!#}"; output=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -o ]]; then index=$((index + 1)); output="${!index}"; fi
done
if [[ "$url" == *'page=2' ]]; then
    printf '{"results":[{"name":"v2","digest":"sha256:%s"}],"next":null}' "$HUB_DIGEST" >"$output"
else
    printf '{"results":[{"name":"v1","digest":"sha256:%s"}],"next":"https://hub.example/page=2"}' "$HUB_DIGEST" >"$output"
fi
printf '200'
EOF
    export HUB_DIGEST="$DIGEST"

    docker_hub_tags_by_digest library/app "sha256:$DIGEST" app
    [[ "$registry_tags" == $'v1\nv2' ]]
    [[ $(grep -ao 'https://' "$CALLS_DIR/curl.args" | wc -l) -eq 2 ]]
}

@test "HUB-005 reverse lookup rejects an equal-prefix different digest" {
    load_hub
    registry_tag_scan=all; registry_direct_tag=; registry_tags=; skip_input=
    install_hub_response 200 \
        "{\"results\":[{\"name\":\"wrong\",\"digest\":\"sha256:${DIGEST%?}f\"}],\"next\":null}"

    docker_hub_tags_by_digest library/app "sha256:$DIGEST" app
    [[ -z "$registry_tags" ]]
}

@test "HUB-006 any-durable retains floating aliases and stops at a durable match" {
    load_hub
    registry_tag_scan=any-durable; registry_direct_tag=latest; registry_tags=; skip_input=
    registry_direct_tag_confirmed=1
    install_hub_response 200 \
        "{\"results\":[{\"name\":\"latest\",\"digest\":\"sha256:$DIGEST\"},{\"name\":\"1.2\",\"digest\":\"sha256:$DIGEST\"},{\"name\":\"1.2.3\",\"digest\":\"sha256:$DIGEST\"},{\"name\":\"1.3.0\",\"digest\":\"sha256:other\"}],\"next\":\"https://unused.example\"}"

    docker_hub_tags_by_digest library/app "sha256:$DIGEST" app
    [[ "$registry_tags" == $'latest\n1.2\n1.2.3' ]]
}

@test "HUB-007 all mode retains matches across pages in response order" {
    load_hub
    registry_tag_scan=all; registry_direct_tag=latest; registry_tags=; skip_input=
    export HUB_DIGEST="$DIGEST"
    write_stub curl <<'EOF'
url="${!#}"; output=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -o ]]; then index=$((index + 1)); output="${!index}"; fi
done
if [[ "$url" == *page=2* ]]; then
    printf '{"results":[{"name":"third","digest":"sha256:%s"}],"next":null}' "$HUB_DIGEST" >"$output"
else
    printf '{"results":[{"name":"first","digest":"sha256:%s"},{"name":"second","digest":"sha256:%s"}],"next":"https://hub.example/page=2"}' "$HUB_DIGEST" "$HUB_DIGEST" >"$output"
fi
printf '200'
EOF

    docker_hub_tags_by_digest library/app "sha256:$DIGEST" app
    [[ "$registry_tags" == $'first\nsecond\nthird' ]]
}

@test "HUB-008 direct public lookup starts without Authorization" {
    load_hub
    install_hub_response 200 "{\"digest\":\"sha256:$DIGEST\"}"

    run docker_hub_digest_for_tag library/app latest
    assert_status 0
    ! grep -aFq 'Authorization' "$CALLS_DIR/curl.args"
}

@test "HUB-009 environment credential attempt exchanges a token and retries the tag" {
    load_hub
    export DOCKER_HUB_USERNAME=user DOCKER_HUB_PAT=pat
    function docker_hub_token_from_credentials {
        printf '%s\0' "$@" >"$CALLS_DIR/credentials.args"
        printf '%s\n' exchanged-token
    }
    export HUB_CALL=0
    write_stub curl <<'EOF'
printf '%s\0' "$@" >>"$CALLS_DIR/curl.args"
output=
for ((index = 1; index <= $#; ++index)); do
    if [[ "${!index}" == -o ]]; then index=$((index + 1)); output="${!index}"; fi
done
count_file="$CALLS_DIR/count"; count=0; [[ ! -f "$count_file" ]] || count=$(<"$count_file")
count=$((count + 1)); printf '%d\n' "$count" >"$count_file"
if ((count == 1)); then printf '{}' >"$output"; printf '403'; else printf '{"digest":"sha256:ok"}' >"$output"; printf '200'; fi
EOF

    declare -A request=(
        [operation]=direct [repository]=library/app [tag]=latest
    ) result=()
    run docker_hub_policy_attempt_api request result
    assert_status "$LOOKUP_DENIED"
    docker_hub_policy_attempt_environment request result
    assert_call_args "$CALLS_DIR/credentials.args" user pat
    [[ $(<"$CALLS_DIR/count") -eq 2 ]]
    [[ "${result[digest]}" == sha256:ok ]]
}

@test "HUB-010 credential exchange validates token and keeps PAT off argv" {
    load_hub
    export HUB_PAT=pat-secret-canary
    write_stub curl <<'EOF'
printf '%s\0' "$@" >"$CALLS_DIR/curl.args"
cat >"$CALLS_DIR/curl.stdin"
printf '%s\n%s\n' '{"access_token":"short-token"}' 200
EOF

    run docker_hub_token_from_credentials user "$HUB_PAT"
    assert_status 0
    assert_output_exact short-token
    ! grep -aFq "$HUB_PAT" "$CALLS_DIR/curl.args"
    grep -Fq "$HUB_PAT" "$CALLS_DIR/curl.stdin"
}

@test "HUB-011 bearer token uses a header file rather than process argv" {
    load_hub
    export HUB_CANARY=hub-bearer-secret
    docker_hub_token="$HUB_CANARY"
    export docker_hub_token
    install_hub_response 200 "{\"digest\":\"sha256:$DIGEST\"}"

    run docker_hub_digest_for_tag library/app latest
    assert_status 0
    ! grep -aFq "$HUB_CANARY" "$CALLS_DIR/curl.args"
    args=$(tr '\0' '\n' <"$CALLS_DIR/curl.args")
    [[ "$args" == *'@'* ]]
}

@test "HUB-013 reverse API refusal is normalized as denied" {
    load_hub
    registry_tag_scan=all; registry_direct_tag=; registry_tags=; skip_input=
    install_hub_response 403 '{"message":"pagination refused"}'
    run docker_hub_tags_by_digest library/app "sha256:$DIGEST" app
    assert_status "$LOOKUP_DENIED"
}

@test "HUB-014 interactive choice spellings map to authenticated Skopeo or skip actions" {
    load_hub

    run docker_hub_authentication_action a 1
    assert_status 0
    assert_output_exact authenticate
    run docker_hub_authentication_action F 1
    assert_status 0
    assert_output_exact skopeo
    run docker_hub_authentication_action s ''
    assert_status 0
    assert_output_exact skip
    run docker_hub_authentication_action f ''
    assert_status 1
}

@test "HUB-016 registry errors are normalized without rendering untrusted bodies" {
    load_hub
    registry_tag_scan=all; registry_direct_tag=; registry_tags=; skip_input=
    long_message=$(printf '%0600d' 0)
    install_hub_response 500 \
        "{\"message\":\"${long_message}\\nNOTICE: forged-record\"}"

    run docker_hub_tags_by_digest \
        library/app "sha256:$DIGEST" app
    assert_status "$LOOKUP_UNAVAILABLE"
    assert_output_exact ''
}

@test "HUB-017 HTTP 429 is normalized as stopped" {
    load_hub
    registry_tag_scan=all; registry_direct_tag=; registry_tags=; skip_input=
    install_hub_response 429 '{"message":"slow down"}'
    run docker_hub_tags_by_digest library/app "sha256:$DIGEST" app
    assert_status "$LOOKUP_STOPPED"
}

@test "HUB-018 any stops at the first matching floating tag" {
    load_hub
    registry_tag_scan=any; registry_direct_tag=; registry_tags=; skip_input=
    install_hub_response 200 \
        "{\"results\":[{\"name\":\"stable\",\"digest\":\"sha256:$DIGEST\"},{\"name\":\"1.2.3\",\"digest\":\"sha256:$DIGEST\"}],\"next\":\"https://unused.example\"}"

    docker_hub_tags_by_digest library/app "sha256:$DIGEST" app
    [[ "$registry_tags" == stable ]]
}

@test "HUB-021 exhaustive pagination uses the shared cost guard" {
    load_hub
    registry_tag_scan=all; registry_direct_tag=; registry_tags=; skip_input=
    install_hub_response 200 \
        '{"count":1000000,"results":[{"name":"one","digest":"sha256:other"}],"next":"https://unused.example"}'
    function registry_expensive_work_preflight {
        printf '%s\0' "$@" >"$CALLS_DIR/preflight.args"
        return "$LOOKUP_STOPPED"
    }

    run docker_hub_tags_by_digest library/app "sha256:$DIGEST" app
    assert_status "$LOOKUP_STOPPED"
    args=$(tr '\0' '\n' <"$CALLS_DIR/preflight.args")
    [[ "$args" == *$'Docker Hub API\napp\nmay request up to 9999 additional tag pages\n9999\n1'* ]]
}
