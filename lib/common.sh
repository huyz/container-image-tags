# shellcheck shell=bash

# Shared output and prompting helpers for container-image-tags.

# shellcheck disable=SC2329
function run_cmd {
    [[ -z ${opt_verbose-} ]] || { printf '#❯'; printf ' %q' "$@"; printf '\n'; } >&2 || true
    [[ -n ${opt_dry_run-} ]] || "$@"
}

# shellcheck disable=SC2329
function debug { [[ -z ${opt_debug-} ]] || printf "%s: 🔧 DEBUG: %s\n" "$SCRIPT_NAME" "$*" >&2; }
# shellcheck disable=SC2329
function info { [[ -z ${opt_verbose-} ]] || printf "%s\n" "$*" >&2; }
# shellcheck disable=SC2329
function warn { printf "%s: ⚠️ WARNING: %s\n" "$SCRIPT_NAME" "$*" >&2; }
# shellcheck disable=SC2329
function err { printf "%s: ❗ ERROR: %s\n" "$SCRIPT_NAME" "$*" >&2; }
# shellcheck disable=SC2329
function abort { printf "%s: ❌ ERROR: %s\n" "$SCRIPT_NAME" "$*" >&2; exit 1; }

function notice { printf "INFO: %s\n" "$*" >&2; }

# Ask which reverse lookup to perform after the known local tag has been
# checked. Return 0 for any match, 1 for all matches, 2 for no scan, and 3
# when prompting is unavailable.
function choose_remote_tag_scan {
    local choice choice_lower

    if [[ ! -t 0 && ! -t 1 && ! -t 2 ]]; then
        return 3
    fi
    echo "Scan remote tags?" >&2
    echo "  [1] Stop after any matching tag" >&2
    echo "  [a] Find all matching tags" >&2
    echo "  [n] Do not scan" >&2
    while true; do
        printf 'Choose [1/a/n]: ' >&2
        IFS= read -r choice </dev/tty || return 3
        choice_lower=$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')
        case "$choice_lower" in
        1 | any) return 0 ;;
        a | all) return 1 ;;
        '' | n | no) return 2 ;;
        esac
    done
}
