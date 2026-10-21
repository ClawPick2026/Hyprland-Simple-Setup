#!/usr/bin/env bash

# Source-only helpers shared by action_exec.sh, status_read.sh and providers/*.sh.
# Contracts: Documents/runtime-managed-configuration.md.
# The HSS_* result globals and nameref targets are read by the sourcing scripts.
# shellcheck disable=SC2034

HSS_SCRIPTS_DIR=${HSS_SCRIPTS_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
HSS_OUTCOME=""
HSS_REASON=""
HSS_PROVIDER=""
HSS_OBSERVED=""
HSS_PENDING=""

declare -gA HSS_OUTCOME_CODES=(
    [completed]=0 [accepted]=0 [failed]=1 [usage]=2 [cancelled]=3 [disabled]=4
    [unsupported]=5 [missing-dependency]=6 [unavailable]=7 [timeout]=8 [denied]=9 [conflict]=10
)

hss_outcome_code() {
    local code=${HSS_OUTCOME_CODES[${1:-}]:-}
    [[ -n $code ]] || return 1
    printf '%s\n' "$code"
}

hss_outcome_from_status() {
    local status=$1 name
    for name in completed failed usage cancelled disabled unsupported missing-dependency unavailable timeout denied conflict; do
        if [[ ${HSS_OUTCOME_CODES[$name]} == "$status" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done
    printf 'failed\n'
}

# Record the outcome of an action and return its exit status.
hss_set_outcome() {
    local outcome=$1 reason=${2:-} code
    code=$(hss_outcome_code "$outcome") || { outcome=failed; code=1; reason="invalid outcome '$1'"; }
    HSS_OUTCOME=$outcome
    HSS_REASON=$reason
    return "$code"
}

hss_roles_file() {
    printf '%s\n' "${HSS_ROLES_FILE:-$HOME/.config/hypr/roles.json}"
}

hss_require_roles() {
    local file
    file=$(hss_roles_file)
    if [[ ! -r $file ]]; then
        hss_set_outcome unavailable "role data is missing; rerun setup"
        return
    fi
}

# Print the primary package of ROLE, or nothing when the role is None.
hss_role_package() {
    local role=$1 file
    [[ $role =~ ^[a-z][a-z0-9_]*$ ]] || return 2
    file=$(hss_roles_file)
    [[ -r $file ]] || return 1
    jq -r --arg role "$role" '.roles[$role].package // ""' "$file"
}

hss_role_field() {
    local role=$1 field=$2 file
    file=$(hss_roles_file)
    [[ -r $file ]] || return 1
    jq -er --arg role "$role" --arg field "$field" '.roles[$role][$field] // empty' "$file"
}

# hss_role_array ROLE FIELD ARRAY_NAME: read a JSON array field into a Bash array.
hss_role_array() {
    local role=$1 field=$2 file
    local -n hss_role_array_target=$3
    file=$(hss_roles_file)
    hss_role_array_target=()
    [[ -r $file ]] || return 1
    mapfile -t hss_role_array_target < <(jq -r --arg role "$role" --arg field "$field" '.roles[$role][$field][]? // empty' "$file")
}

hss_role_members() {
    local role=$1 file
    file=$(hss_roles_file)
    [[ -r $file ]] || return 1
    jq -r --arg role "$role" '.selected[$role][]?.package' "$file"
}

hss_have() {
    command -v -- "$1" >/dev/null 2>&1
}

hss_process_running() {
    pgrep -u "$(id -u)" -x -- "$1" >/dev/null 2>&1
}

hss_now_iso() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# Run a command with a bounded wait. Returns 124 on timeout, like timeout(1).
hss_run_bounded() {
    local seconds=$1
    shift
    if hss_have timeout; then
        timeout --kill-after=1 "$seconds" "$@"
    else
        "$@"
    fi
}

# Start an application detached from the caller. The launch is accepted, not observed.
hss_spawn() {
    hss_have "$1" || [[ -x $1 ]] || {
        hss_set_outcome missing-dependency "$1 is not installed"
        return
    }
    if hss_have setsid; then
        setsid -f "$@" </dev/null >/dev/null 2>&1 || {
            hss_set_outcome failed "could not start $1"
            return
        }
    else
        ("$@" </dev/null >/dev/null 2>&1 &) || {
            hss_set_outcome failed "could not start $1"
            return
        }
    fi
    hss_set_outcome accepted "${1##*/} was started"
}

# Explain an outcome to the user. Never include notification, clipboard or device content.
hss_notify_user() {
    local summary=$1 body=${2:-}
    [[ ${HSS_ACTION_NOTIFY:-1} == 1 ]] || return 0
    hss_have notify-send || return 0
    notify-send -a "Hyprland Simple Setup" -u normal -- "$summary" "$body" >/dev/null 2>&1 || true
}

# Owner of a well-known D-Bus name on the user bus: prints the unique name, or nothing.
hss_dbus_name_owner() {
    local name=$1 output
    if hss_have busctl; then
        output=$(hss_run_bounded 3 busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus GetNameOwner s "$name" 2>/dev/null) || return 1
        output=${output#s }
        output=${output//\"/}
        printf '%s\n' "$output"
    elif hss_have dbus-send; then
        output=$(hss_run_bounded 3 dbus-send --session --print-reply=literal --dest=org.freedesktop.DBus \
            /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner "string:$name" 2>/dev/null) || return 1
        printf '%s\n' "${output//[[:space:]]/}"
    else
        return 2
    fi
}

# PID of the process owning a well-known D-Bus name, or nothing.
hss_dbus_name_pid() {
    local name=$1 output
    if hss_have busctl; then
        output=$(hss_run_bounded 3 busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus GetConnectionUnixProcessID s "$name" 2>/dev/null) || return 1
        printf '%s\n' "${output#u }"
    elif hss_have dbus-send; then
        output=$(hss_run_bounded 3 dbus-send --session --print-reply=literal --dest=org.freedesktop.DBus \
            /org/freedesktop/DBus org.freedesktop.DBus.GetConnectionUnixProcessID "string:$name" 2>/dev/null) || return 1
        output=${output//uint32/}
        printf '%s\n' "${output//[[:space:]]/}"
    else
        return 2
    fi
}

hss_process_name() {
    local pid=$1
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/comm ]] || return 1
    tr -d '\n' < "/proc/$pid/comm"
    printf '\n'
}

# Emit one status object. STATE and CAPABILITIES are JSON values; ERROR is text or empty.
hss_status_emit() {
    local domain=$1 provider=$2 availability=$3 state=${4:-null} capabilities=${5:-null} error=${6:-}
    jq -cn \
        --arg domain "$domain" \
        --arg provider "$provider" \
        --arg availability "$availability" \
        --arg observed_at "$(hss_now_iso)" \
        --argjson state "$state" \
        --argjson capabilities "$capabilities" \
        --arg error "$error" \
        '{schema: 1, domain: $domain, provider: (if $provider == "" then null else $provider end),
          availability: $availability, observed_at: $observed_at, state: $state,
          capabilities: $capabilities, error: (if $error == "" then null else $error end)}'
}

# Replace control characters in display text used by menus and notifications.
hss_sanitize_label() {
    local text=$1
    text=${text//$'\t'/ }
    text=${text//$'\n'/ }
    text=${text//$'\r'/ }
    printf '%s' "$text" | tr -d '\000-\010\013\014\016-\037\177'
}
