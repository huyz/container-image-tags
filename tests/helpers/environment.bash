function setup_test_environment {
    TEST_ROOT="$BATS_TEST_TMPDIR/cit"
    STUB_BIN="$TEST_ROOT/bin"
    CALLS_DIR="$TEST_ROOT/calls"
    FIXTURE_DIR="$TEST_ROOT/fixtures"
    mkdir -p "$STUB_BIN" "$CALLS_DIR" "$FIXTURE_DIR" \
        "$TEST_ROOT/home" "$TEST_ROOT/xdg" "$TEST_ROOT/docker"

    export TEST_ROOT STUB_BIN CALLS_DIR FIXTURE_DIR
    export HOME="$TEST_ROOT/home"
    export XDG_CONFIG_HOME="$TEST_ROOT/xdg"
    export DOCKER_CONFIG="$TEST_ROOT/docker"
    export PATH="$STUB_BIN:$ORIGINAL_PATH"
    export SCRIPT_NAME=container-image-tags
    export JQ="$SYSTEM_JQ"
    export GETOPT="$SYSTEM_GETOPT"
    export REALPATH="$SYSTEM_REALPATH"
    export DOCKER="$STUB_BIN/docker"
    export CURL="$STUB_BIN/curl"
    export SKOPEO="$STUB_BIN/skopeo"
    export GH="$STUB_BIN/gh"
    export GCLOUD="$STUB_BIN/gcloud"
    export AZ="$STUB_BIN/az"
    export AWS="$STUB_BIN/aws"
    export COLUMNS=72

    unset DOCKER_HUB_USERNAME DOCKER_HUB_PAT AWS_ACCESS_KEY_ID AWS_PROFILE
    unset AWS_DEFAULT_PROFILE AWS_WEB_IDENTITY_TOKEN_FILE
    unset AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI
    opt_verbose=
    opt_debug=
    opt_json=
    opt_allow_expensive_scan=
    opt_credential_policy=if-faster
    opt_tag_scan=
    opt_tag_resolution=auto
}

function cleanup_test_environment {
    local child
    for child in $(jobs -p 2>/dev/null); do
        kill "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    done
    if declare -F runtime_cleanup >/dev/null; then
        runtime_cleanup
    fi
    [[ ! -d ${TEST_ROOT-} ]] || rm -rf -- "$TEST_ROOT"
}

function write_stub {
    local name="$1"
    local path="$STUB_BIN/$name"

    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
        cat
    } >"$path"
    chmod +x "$path"
}

function write_static_stub {
    local name="$1"
    local stdout_value="${2-}"
    local status_value="${3-0}"
    local path="$STUB_BIN/$name"

    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
        printf 'printf %s %q\n' '%s' "$stdout_value"
        printf 'exit %d\n' "$status_value"
    } >"$path"
    chmod +x "$path"
}

function load_common {
    # shellcheck source=../../lib/common.sh
    source "$REPO_ROOT/lib/common.sh"
    # shellcheck source=../../lib/runtime.sh
    CIT_RUNTIME_NO_EXIT_TRAP=1
    source "$REPO_ROOT/lib/runtime.sh"
    unset CIT_RUNTIME_NO_EXIT_TRAP
    # shellcheck source=../../lib/access-policy.sh
    source "$REPO_ROOT/lib/access-policy.sh"
}

function load_module {
    local module="$1"

    load_common
    case "$module" in
    acr | docker-hub)
        source "$REPO_ROOT/lib/skopeo.sh"
        ;;
    gar | ecr)
        source "$REPO_ROOT/lib/skopeo.sh"
        source "$REPO_ROOT/lib/oci.sh"
        ;;
    gcr)
        source "$REPO_ROOT/lib/oci.sh"
        ;;
    esac
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/$module.sh"
}
