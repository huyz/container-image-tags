# shellcheck shell=bash

# Registry credential policy. Backend selection and credential selection are
# deliberately separate: an unavailable public backend may fall back to a
# different public backend, but it must not by itself authorize credentials.

function credential_policy_allows_public {
    [[ "${opt_credential_policy:-if-faster}" != require ]]
}

function credential_policy_allows_credentials {
    [[ "${opt_credential_policy:-if-faster}" != never ]]
}

function credential_policy_prefers_fast_credentials {
    case "${opt_credential_policy:-if-faster}" in
    if-faster | require) return 0 ;;
    *) return 1 ;;
    esac
}

# Credentials may follow an explicit denial for both conditional policies.
# An unavailable backend is not evidence that authentication is required.
function credential_policy_allows_auth_after {
    local lookup_status="$1"

    credential_policy_allows_credentials || return 1
    [[ "${opt_credential_policy:-if-faster}" == require ]] && return 0
    (( lookup_status == LOOKUP_DENIED ))
}
