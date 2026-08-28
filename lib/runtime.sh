# shellcheck shell=bash

# Runtime-owned temporary resources and small transport helpers. Callers may
# remove individual paths as soon as they are done; the EXIT cleanup is the
# final safety net for interrupts and handled early exits.

runtime_tmp_dir=
declare -ga runtime_child_pids=()
readonly NETWORK_OPERATION_TIMEOUT_SECONDS=${CIT_NETWORK_TIMEOUT_SECONDS-600}

[[ "$NETWORK_OPERATION_TIMEOUT_SECONDS" =~ ^(0|[1-9][0-9]*)$ ]] ||
    abort "CIT_NETWORK_TIMEOUT_SECONDS must be a non-negative integer"

function runtime_init {
    [[ -n "$runtime_tmp_dir" ]] && return
    runtime_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/container-image-tags.XXXXXX")
    chmod 700 "$runtime_tmp_dir"
    [[ -n ${CIT_RUNTIME_NO_EXIT_TRAP-} ]] || trap runtime_cleanup EXIT
}

function runtime_temp_file {
    local label="${1:-tmp}"

    runtime_init
    mktemp "$runtime_tmp_dir/$label.XXXXXX"
}

function runtime_temp_dir {
    local label="${1:-tmp}"

    runtime_init
    mktemp -d "$runtime_tmp_dir/$label.XXXXXX"
}

function runtime_remove {
    local path

    for path in "$@"; do
        [[ -n "$path" ]] || continue
        if [[ -d "$path" ]]; then
            rmdir "$path" 2>/dev/null || true
        else
            rm -f "$path"
        fi
    done
}

function runtime_register_child {
    runtime_child_pids+=("$1")
}

function runtime_unregister_child {
    local completed_pid="$1"
    local pid
    local -a remaining_pids=()

    for pid in "${runtime_child_pids[@]}"; do
        [[ "$pid" == "$completed_pid" ]] || remaining_pids+=("$pid")
    done
    runtime_child_pids=("${remaining_pids[@]}")
}

function runtime_terminate_children {
    local pid attempt any_alive

    for pid in "${runtime_child_pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for (( attempt = 0; attempt < 25; ++attempt )); do
        any_alive=
        for pid in "${runtime_child_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                any_alive=1
                break
            fi
        done
        [[ -n "$any_alive" ]] || break
        sleep 0.01
    done
    for pid in "${runtime_child_pids[@]}"; do
        kill -KILL "$pid" 2>/dev/null || true
    done
    for pid in "${runtime_child_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    runtime_child_pids=()
}

function runtime_cleanup {
    runtime_terminate_children
    [[ -n "$runtime_tmp_dir" && -d "$runtime_tmp_dir" ]] || return 0
    # Every path here was created beneath the validated runtime directory.
    find "$runtime_tmp_dir" -type f -delete 2>/dev/null || true
    find "$runtime_tmp_dir" -depth -type d -exec rmdir {} + 2>/dev/null || true
    runtime_tmp_dir=
}

# Run one external operation with a portable wall-clock deadline. TIMEOUT is
# selected by the entrypoint as GNU timeout on macOS and timeout elsewhere.
# Standard streams are inherited, and the default process-group behavior keeps
# a timed-out CLI from leaving helpers behind.
function run_network_command {
    [[ "$NETWORK_OPERATION_TIMEOUT_SECONDS" == 0 ]] && {
        "$@"
        return
    }
    "$TIMEOUT" --kill-after=0.25s "$NETWORK_OPERATION_TIMEOUT_SECONDS" "$@"
}

# Execute one registry HTTP request while keeping response capture mechanics
# out of provider modules. Print only the HTTP status. The provider supplies
# optional curl request arguments and remains responsible for interpreting the
# status and validating the response body.
function registry_http_request {
    local method="$1"
    local url="$2"
    local response_body="$3"
    local response_headers="$4"
    shift 4
    local -a request_args=(-sS)

    case "$method" in
    GET) ;;
    HEAD) request_args+=(-I) ;;
    *) return 2 ;;
    esac
    request_args+=("$@")
    [[ -z "$response_headers" ]] || request_args+=(-D "$response_headers")
    request_args+=(-o "$response_body" -w '%{http_code}')
    run_network_command "$CURL" "${request_args[@]}" "$url"
}

# Extract and bound the common JSON error shapes returned by registry APIs.
function registry_json_error_message {
    local response_file="$1"
    local maximum_length="${2:-512}"

    # shellcheck disable=SC2016  # jq filter uses a literal jq variable
    "$JQ" -r --argjson maximum_length "$maximum_length" '
        (.errors[0].message // .message // .detail // .error // empty)
        | if type == "string" then gsub("[\\r\\n]+"; " ") else tostring end
        | .[0:$maximum_length]
    ' "$response_file" 2>/dev/null || true
}

function command_error_single_line {
    local error_file="$1"
    local maximum_length="${2:-1000}"
    local error_message

    error_message=$(tr '\r\n' '  ' <"$error_file")
    error_message="${error_message:0:maximum_length}"
    printf '%s' "$error_message"
}

# Allocate in the sourcing shell. Most callers capture a generated path with
# command substitution; initializing there would create and immediately clean
# a subshell-owned directory before the caller could use it.
runtime_init
