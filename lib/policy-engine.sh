# shellcheck shell=bash
# shellcheck disable=SC2004,SC2034,SC2154,SC2178  # plan tables and associative namerefs

# One registry-independent lookup state machine. Provider modules register
# atomic mechanisms; this engine alone decides which mechanisms are permitted,
# their order, which outcomes allow fallback, and when interactive recovery may
# run.

readonly POLICY_ACCESS_PUBLIC=public
readonly POLICY_ACCESS_LOCAL=local
readonly POLICY_ACCESS_SESSION=session
readonly POLICY_ACCESS_FAST_CREDENTIAL=fast-credential
readonly POLICY_ACCESS_CREDENTIAL=credential
readonly POLICY_ACCESS_INTERACTIVE=interactive
readonly POLICY_DEFERRED=5

# Register one atomic mechanism. Cost is a relative integer used only among
# attempts that satisfy the user's credential and completeness constraints.
function policy_add_attempt {
    local id="$1"
    local callback="$2"
    local backend="$3"
    local access="$4"
    local cost="$5"
    local authoritative="${6:-1}"
    local available="${7-}"

    [[ -n "$id" && -n "$callback" && -n "$backend" ]] ||
        abort "Invalid registry policy attempt declaration"
    [[ -z ${policy_attempt_callback[$id]+x} ]] ||
        abort "Duplicate registry policy attempt '$id'"
    case "$access" in
    "$POLICY_ACCESS_LOCAL" | "$POLICY_ACCESS_PUBLIC" | "$POLICY_ACCESS_SESSION" | \
        "$POLICY_ACCESS_FAST_CREDENTIAL" | "$POLICY_ACCESS_CREDENTIAL" | \
        "$POLICY_ACCESS_INTERACTIVE") ;;
    *) abort "Invalid access class '$access' for registry policy attempt '$id'" ;;
    esac
    [[ "$cost" =~ ^[0-9]+$ ]] ||
        abort "Invalid cost '$cost' for registry policy attempt '$id'"

    policy_attempt_sequence[$id]="${#policy_attempt_ids[@]}"
    policy_attempt_ids+=("$id")
    policy_attempt_callback[$id]="$callback"
    policy_attempt_backend[$id]="$backend"
    policy_attempt_access[$id]="$access"
    policy_attempt_cost[$id]="$cost"
    policy_attempt_authoritative[$id]="$authoritative"
    policy_attempt_available[$id]="$available"
}

function policy_attempt_is_permitted {
    local id="$1"
    local request_name="$2"
    local denial_observed="$3"
    local public_denied="$4"
    local access="${policy_attempt_access[$id]}"
    local policy="${opt_credential_policy:-if-faster}"

    [[ -z ${policy_attempt_finished[$id]-} ]] || return 1
    case "$access:$policy" in
    public:require | session:never | fast-credential:never | \
        credential:never | interactive:never)
        return 1
        ;;
    local:*)
        ;;
    public:*)
        [[ -z "$public_denied" ]] || return 1
        ;;
    session:*)
        ;;
    fast-credential:if-faster | fast-credential:require)
        ;;
    fast-credential:* | credential:* | interactive:*)
        [[ -n "$denial_observed" || "$policy" == require ]] || return 1
        ;;
    esac
    if [[ "$access" == "$POLICY_ACCESS_INTERACTIVE" ]]; then
        [[ -n "$denial_observed" ]] && is_interactive_session || return 1
    fi
    return 0
}

function policy_attempt_confirmed_direct_tag {
    local request_name="$1"
    local result_name="$2"
    local -n request_ref="$request_name"
    local -n result_ref="$result_name"

    [[ -n "${request_ref[direct_tag_confirmed]-}" &&
        -n "${request_ref[direct_tag]-}" ]] || return "$LOOKUP_UNAVAILABLE"
    if [[ "${request_ref[scan_mode]}" == any ]]; then
        result_ref[tags]="${request_ref[direct_tag]}"
        return "$LOOKUP_SUCCEEDED"
    fi
    if [[ "${request_ref[scan_mode]}" == any-durable ]] &&
            tag_is_assumed_durable "${request_ref[direct_tag]}"; then
        result_ref[tags]="${request_ref[direct_tag]}"
        return "$LOOKUP_SUCCEEDED"
    fi
    return "$LOOKUP_UNAVAILABLE"
}

function policy_register_builtin_attempts {
    local request_name="$1"
    local -n request_ref="$request_name"

    [[ "${request_ref[operation]}" == reverse ]] || return 0
    policy_add_attempt confirmed-direct-tag policy_attempt_confirmed_direct_tag \
        direct-tag-check "$POLICY_ACCESS_LOCAL" 0
}

function policy_select_attempt {
    local request_name="$1"
    local denial_observed="$2"
    local public_denied="$3"
    local selected_name="$4"
    local -n selected_ref="$selected_name"
    local id selected_cost selected_sequence

    selected_ref=
    selected_cost=
    selected_sequence=
    for id in "${policy_attempt_ids[@]}"; do
        policy_attempt_is_permitted \
            "$id" "$request_name" "$denial_observed" "$public_denied" || continue
        if [[ -z "$selected_ref" ]] ||
                (( policy_attempt_cost[$id] < selected_cost )) ||
                (( policy_attempt_cost[$id] == selected_cost &&
                    policy_attempt_sequence[$id] < selected_sequence )); then
            selected_ref="$id"
            selected_cost="${policy_attempt_cost[$id]}"
            selected_sequence="${policy_attempt_sequence[$id]}"
        fi
    done
    [[ -n "$selected_ref" ]]
}

function policy_copy_attempt_result {
    local source_name="$1"
    local destination_name="$2"
    local backend="$3"
    local -n source_ref="$source_name"
    local -n destination_ref="$destination_name"
    local key

    destination_ref=()
    for key in "${!source_ref[@]}"; do
        destination_ref[$key]="${source_ref[$key]}"
    done
    destination_ref[backend]="${source_ref[backend]:-$backend}"
}

# Execute the cheapest currently permitted mechanism until one succeeds or a
# terminal outcome is reached. LOOKUP_UNAVAILABLE changes mechanisms but never
# unlocks credentials; LOOKUP_DENIED does. A non-authoritative not-found is a
# mechanism miss and remains eligible for broader fallback. POLICY_DEFERRED
# lets a probe advertise newly measured continuation attempts without making a
# provider choose between them.
function policy_execute_lookup {
    local request_name="$1"
    local result_name="$2"
    local -n result_ref="$result_name"
    local attempt_id callback status
    local denial_observed='' public_denied='' last_status=$LOOKUP_UNAVAILABLE
    local availability
    local -A mechanism_result=()

    result_ref=()
    policy_register_builtin_attempts "$request_name"
    while policy_select_attempt \
            "$request_name" "$denial_observed" "$public_denied" attempt_id; do
        callback="${policy_attempt_callback[$attempt_id]}"
        availability="${policy_attempt_available[$attempt_id]}"
        if [[ -n "$availability" ]] && ! "$availability" "$request_name"; then
            policy_attempt_finished[$attempt_id]=1
            continue
        fi
        mechanism_result=()
        debug "Registry policy attempt: id=$attempt_id backend=${policy_attempt_backend[$attempt_id]} access=${policy_attempt_access[$attempt_id]} cost=${policy_attempt_cost[$attempt_id]}"
        if "$callback" "$request_name" mechanism_result; then
            status=$LOOKUP_SUCCEEDED
        else
            status=$?
        fi
        mechanism_result[status]="$status"
        policy_attempt_finished[$attempt_id]=1
        last_status=$status

        case "$status" in
        "$LOOKUP_SUCCEEDED")
            policy_copy_attempt_result mechanism_result "$result_name" \
                "${policy_attempt_backend[$attempt_id]}"
            return "$LOOKUP_SUCCEEDED"
            ;;
        "$LOOKUP_NOT_FOUND")
            if [[ "${policy_attempt_authoritative[$attempt_id]}" == 1 ]]; then
                policy_copy_attempt_result mechanism_result "$result_name" \
                    "${policy_attempt_backend[$attempt_id]}"
                return "$LOOKUP_NOT_FOUND"
            fi
            ;;
        "$LOOKUP_DENIED")
            denial_observed=1
            if [[ "${policy_attempt_access[$attempt_id]}" == "$POLICY_ACCESS_PUBLIC" ]]; then
                public_denied=1
            fi
            ;;
        "$LOOKUP_STOPPED")
            policy_copy_attempt_result mechanism_result "$result_name" \
                "${policy_attempt_backend[$attempt_id]}"
            return "$LOOKUP_STOPPED"
            ;;
        "$LOOKUP_UNAVAILABLE")
            ;;
        "$POLICY_DEFERRED")
            ;;
        *)
            abort "Registry policy attempt '$attempt_id' returned invalid status '$status'"
            ;;
        esac
    done

    result_ref=()
    result_ref[status]="$last_status"
    return "$last_status"
}

# Own one complete plan in the lookup call's dynamic scope. Registration and
# adaptive callbacks retain the compact policy_add_attempt API without sharing
# plan state between lookups.
function policy_build_and_execute_lookup {
    local request_name="$1"
    local result_name="$2"
    local register_callback="$3"
    local -a policy_attempt_ids=()
    local -A policy_attempt_callback=() policy_attempt_backend=()
    local -A policy_attempt_access=() policy_attempt_cost=()
    local -A policy_attempt_authoritative=() policy_attempt_available=()
    local -A policy_attempt_sequence=() policy_attempt_finished=()

    "$register_callback" "$request_name"
    policy_execute_lookup "$request_name" "$result_name"
}
