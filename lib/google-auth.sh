# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # standalone module lint: shared runtime fields

# Shared short-lived Google Cloud authentication for GCR and GAR adapters.

function google_access_token {
    local registry="$1"
    local token

    command -v "${GCLOUD:=gcloud}" &>/dev/null || {
        warn "Install Google Cloud CLI and run 'gcloud auth login' to access private Google registry '$registry'"
        return "$LOOKUP_UNAVAILABLE"
    }
    notice "Requesting a short-lived token from Google Cloud CLI for '$registry'."
    token=$(run_network_command "$GCLOUD" auth print-access-token --quiet) || {
        warn "Google Cloud CLI authentication failed for registry '$registry'"
        return "$LOOKUP_UNAVAILABLE"
    }
    [[ -n "$token" ]] || return "$LOOKUP_UNAVAILABLE"
    printf '%s\n' "$token"
}

function google_authenticate {
    local registry="$1"

    command -v "${GCLOUD:=gcloud}" &>/dev/null || {
        warn "Install Google Cloud CLI and run 'gcloud auth login' to access private Google registry '$registry'"
        return 1
    }

    notice "Google registry denied anonymous access; retrying with a short-lived token from Google Cloud CLI."
    if ! run_network_command "$GCLOUD" auth print-access-token --quiet |
            run_network_command "$SKOPEO" login \
                --authfile "$skopeo_session_authfile" \
                --username oauth2accesstoken --password-stdin "$registry" >/dev/null; then
        warn "Google Cloud CLI authentication failed for registry '$registry'"
        return 1
    fi
}
