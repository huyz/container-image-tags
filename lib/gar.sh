# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # standalone module lint: shared input/output fields

# Google registry access. GAR uses the shared OCI HEAD engine for public and
# short-lived-token access; Skopeo remains the compatibility fallback. GCR also
# reuses the token helper for its digest-keyed metadata endpoint.

function gar_access_token {
    local registry="$1"
    local token

    command -v "${GCLOUD:=gcloud}" &>/dev/null || {
        warn "Install Google Cloud CLI and run 'gcloud auth login' to access private Google registry '$registry'"
        return "$LOOKUP_UNAVAILABLE"
    }
    notice "Requesting a short-lived token from Google Cloud CLI for '$registry'."
    token=$("$GCLOUD" auth print-access-token --quiet) || {
        warn "Google Cloud CLI authentication failed for registry '$registry'"
        return "$LOOKUP_UNAVAILABLE"
    }
    [[ -n "$token" ]] || return "$LOOKUP_UNAVAILABLE"
    printf '%s\n' "$token"
}

function gar_authenticate {
    local registry="$1"

    command -v "${GCLOUD:=gcloud}" &>/dev/null || {
        warn "Install Google Cloud CLI and run 'gcloud auth login' to access private Google registry '$registry'"
        return 1
    }

    notice "Google registry denied anonymous access; retrying with a short-lived token from Google Cloud CLI."
    if ! "$GCLOUD" auth print-access-token --quiet |
            "$SKOPEO" login --authfile "$skopeo_session_authfile" \
                --username oauth2accesstoken --password-stdin "$registry" >/dev/null; then
        warn "Google Cloud CLI authentication failed for registry '$registry'"
        return 1
    fi
}

# Skopeo reports only the HTTP status for some Google registry token failures,
# while Docker's manifest client can preserve the registry's response body.
# Make this extra network request only in debug mode and return just the
# registry-provided denial reason when one is available.
function gar_debug_denial_detail {
    local image_reference="$1"
    local docker_error error_tmp

    [[ -n ${opt_debug-} ]] || return 1
    command -v "$DOCKER" &>/dev/null || return 1

    debug "Requesting a Docker manifest diagnostic for $image_reference after the authenticated Skopeo request was denied"
    error_tmp=$(runtime_temp_file gar-debug-error)
    if "$DOCKER" manifest inspect "$image_reference" >/dev/null 2>"$error_tmp"; then
        rm -f "$error_tmp"
        debug "Docker manifest inspection succeeded for $image_reference but provided no denial detail"
        return 1
    fi

    docker_error=$(tr '\r\n' '  ' <"$error_tmp" | sed -E 's/[[:space:]]+$//')
    rm -f "$error_tmp"
    if [[ "$docker_error" != *'denied: '* ]]; then
        debug "Docker manifest diagnostic for $image_reference did not include a registry denial reason: $docker_error"
        return 1
    fi

    printf '%s\n' "${docker_error#*denied: }"
}

function gar_digest_for_tag {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local image_reference="$4"
    local digest lookup_status token

    if credential_policy_allows_public; then
        if digest=$(oci_digest_for_tag_anonymously "$registry" "$repository" "$tag"); then
            printf '%s\n' "$digest"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
        case "$lookup_status" in
        "$LOOKUP_NOT_FOUND" | "$LOOKUP_STOPPED") return "$lookup_status" ;;
        esac
    else
        lookup_status=$LOOKUP_DENIED
    fi

    if credential_policy_allows_auth_after "$lookup_status"; then
        if token=$(gar_access_token "$registry") &&
                digest=$(oci_digest_for_tag_with_bearer_token \
                    "$registry" "$repository" "$tag" "$token"); then
            printf '%s\n' "$digest"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
        case "$lookup_status" in
        "$LOOKUP_NOT_FOUND" | "$LOOKUP_STOPPED") return "$lookup_status" ;;
        esac
    fi

    skopeo_is_available || return "$lookup_status"
    if digest=$(skopeo_digest_for_tag_with_access_policy \
            "$registry" "$image_reference" gar_authenticate "$lookup_status"); then
        printf '%s\n' "$digest"
        return "$LOOKUP_SUCCEEDED"
    else
        lookup_status=$?
    fi
    if (( lookup_status == LOOKUP_DENIED )); then
        gar_debug_denial_detail "$image_reference" || true
    fi
    return "$lookup_status"
}

function gar_resolve_tag {
    local registry="$1"
    local repository="$2"
    local tag="$3"
    local display_reference="$4"
    local lookup_output

    if lookup_output=$(gar_digest_for_tag \
            "$registry" "$repository" "$tag" "$display_reference"); then
        remote_tag_digest="$lookup_output"
        remote_tag_status=$LOOKUP_SUCCEEDED
    else
        remote_tag_status=$?
        remote_tag_error="$lookup_output"
    fi
}

function gar_tags_by_digest {
    local registry="$1"
    local repository="$2"
    local digest="$3"

    local oci_repository="${repository#*/}"
    local tags lookup_status token

    if credential_policy_allows_public; then
        if tags=$(oci_tags_by_digest_anonymously \
                "$registry" "$oci_repository" "$digest"); then
            printf '%s' "$tags"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
        case "$lookup_status" in
        "$LOOKUP_NOT_FOUND" | "$LOOKUP_STOPPED") return "$lookup_status" ;;
        esac
    else
        lookup_status=$LOOKUP_DENIED
    fi

    if credential_policy_allows_auth_after "$lookup_status"; then
        if token=$(gar_access_token "$registry") &&
                tags=$(oci_tags_by_digest_with_bearer_token \
                    "$registry" "$oci_repository" "$digest" "$token"); then
            printf '%s' "$tags"
            return "$LOOKUP_SUCCEEDED"
        else
            lookup_status=$?
        fi
        case "$lookup_status" in
        "$LOOKUP_NOT_FOUND" | "$LOOKUP_STOPPED") return "$lookup_status" ;;
        esac
    fi

    skopeo_tags_by_digest_with_access_policy \
        "$registry" "$repository" "$digest" gar_authenticate "$lookup_status"
}

function gar_find_tags {
    local registry="$1"
    local display_repository="$2"
    local digest="$3"

    local oci_repository="${display_repository#*/}"
    local lookup_status token

    if credential_policy_allows_public; then
        registry_lookup_backend=oci-registry-api
        if registry_tags=$(oci_tags_by_digest_anonymously \
                "$registry" "$oci_repository" "$digest"); then
            return
        else
            lookup_status=$?
        fi
        case "$lookup_status" in
        "$LOOKUP_NOT_FOUND") registry_lookup_result=not_found; return ;;
        "$LOOKUP_STOPPED") abort "Google registry OCI lookup stopped for $display_repository" ;;
        esac
    else
        lookup_status=$LOOKUP_DENIED
    fi

    if credential_policy_allows_auth_after "$lookup_status"; then
        if token=$(gar_access_token "$registry") &&
                registry_tags=$(oci_tags_by_digest_with_bearer_token \
                    "$registry" "$oci_repository" "$digest" "$token"); then
            registry_lookup_backend=oci-registry-api
            return
        else
            lookup_status=$?
        fi
        case "$lookup_status" in
        "$LOOKUP_NOT_FOUND") registry_lookup_result=not_found; return ;;
        "$LOOKUP_STOPPED") abort "Google registry OCI lookup stopped for $display_repository" ;;
        esac
    fi

    registry_lookup_backend=skopeo
    skopeo_is_available || abort "Install skopeo to query registry '$registry'"
    registry_tags=$(skopeo_tags_by_digest_with_access_policy \
        "$registry" "$display_repository" "$digest" gar_authenticate \
        "$lookup_status") || abort "Google registry lookup failed for $display_repository"
}
