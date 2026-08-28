# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # standalone module lint: shared options

# Shared lookup statuses and diagnostics for container-image-tags.

# Lookup functions print successful values to stdout and use these statuses for
# out-of-band outcomes. LOOKUP_STOPPED is terminal: callers must not retry with
# a more request-intensive fallback.
readonly LOOKUP_SUCCEEDED=0
readonly LOOKUP_NOT_FOUND=1
readonly LOOKUP_UNAVAILABLE=2
readonly LOOKUP_DENIED=3
readonly LOOKUP_STOPPED=4

# shellcheck disable=SC2329
function debug { [[ -z ${opt_debug-} ]] || printf "%s: 🔧 DEBUG: %s\n" "$SCRIPT_NAME" "$*" >&2; }
# shellcheck disable=SC2329
# Print repeated progress and implementation detail only when verbose output is
# requested. Hide these messages when they do not change the user's decisions.
function verbose { [[ -z ${opt_verbose-} ]] || printf "%s\n" "$*" >&2; }
# shellcheck disable=SC2329
function warn { printf "%s: ⚠️ WARNING: %s\n" "$SCRIPT_NAME" "$*" >&2; }
# shellcheck disable=SC2329
function abort { printf "%s: ❌ ERROR: %s\n" "$SCRIPT_NAME" "$*" >&2; exit 1; }

# Print one-time events that change input meaning, credentials, backend,
# expected duration, completeness, or result scope. These remain visible
# without verbose output.
function notice { printf "NOTICE: %s\n" "$*" >&2; }

# Require both terminal input and terminal diagnostics so a user can answer a
# visible prompt. stdout may be redirected without making the session
# noninteractive.
function is_interactive_session {
    [[ -t 0 && -t 2 ]]
}
