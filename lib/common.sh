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

function notice { printf "ℹ️ %s\n" "$*" >&2; }

# Ask whether to perform the exhaustive reverse lookup after the known local
# tag has been checked. Return 0 for scan, 1 for no scan, and 2 when prompting
# is unavailable.
function choose_remote_tag_scan {
    local choice

    if [[ ! -t 0 && ! -t 1 && ! -t 2 ]]; then
        return 2
    fi
    while true; do
        printf 'Scan for every remote tag that matches this digest? [y/N]: ' >&2
        IFS= read -r choice </dev/tty || return 2
        case "$choice" in
        y | Y | yes | YES | Yes) return 0 ;;
        '' | n | N | no | NO | No) return 1 ;;
        esac
    done
}
