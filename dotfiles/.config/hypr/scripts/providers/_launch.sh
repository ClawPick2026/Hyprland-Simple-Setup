#!/usr/bin/env bash
# shellcheck disable=SC2034 # HSS_PROVIDER/HSS_REASON/HSS_OBSERVED are read by action_exec.sh.

# Source-only launch helpers shared by the device and session providers (plans D04, D07).
# The leading underscore keeps this file outside the action namespace: action_exec.sh only
# sources providers/<domain>.sh for domains that start with a letter.
# Contract: Documents/runtime-managed-configuration.md.

hss_launch_have_display() {
    [[ -n ${WAYLAND_DISPLAY:-} || -n ${DISPLAY:-} ]]
}

# hss_launch_gui COMMAND [ARG...]: start a graphical application detached (outcome accepted).
hss_launch_gui() {
    hss_launch_have_display || { hss_set_outcome unavailable "no graphical session is available"; return; }
    hss_have "$1" || { hss_set_outcome missing-dependency "${1##*/} is not installed"; return; }
    hss_spawn "$@" || return
    HSS_REASON="${1##*/} was started"
}

# hss_launch_terminal APP_ID TITLE COMMAND [ARG...]: run a terminal program in the selected
# terminal through term_exec.sh. Callers check that the terminal program itself is installed.
hss_launch_terminal() {
    local app_id=$1 title=$2
    shift 2
    hss_launch_have_display || { hss_set_outcome unavailable "no graphical session is available"; return; }
    [[ -x $HSS_SCRIPTS_DIR/term_exec.sh ]] || { hss_set_outcome missing-dependency "term_exec.sh is not installed; rerun setup"; return; }
    hss_spawn "$HSS_SCRIPTS_DIR/term_exec.sh" --app-id "$app_id" --title "$title" -- "$@" || return
    HSS_REASON="opened in the selected terminal"
}

# hss_launch_role_command ROLE ARRAY_NAME: read the selected executable and catalog arguments.
hss_launch_role_command() {
    local role=$1 executable
    local -n hss_launch_role_target=$2
    local -a role_args=()
    executable=$(hss_role_field "$role" executable 2>/dev/null) || {
        hss_set_outcome failed "the $role role has no executable; rerun setup"
        return
    }
    hss_role_array "$role" args role_args || true
    hss_launch_role_target=("$executable" "${role_args[@]}")
}

hss_launch_role_is_terminal() {
    [[ $(jq -r --arg role "$1" '.roles[$role].terminal // false' "$(hss_roles_file)" 2>/dev/null) == true ]]
}

# hss_launch_select ROLE: set HSS_PROVIDER to the selected package of ROLE or report why not.
hss_launch_select() {
    local role=$1 package
    hss_require_roles || return
    package=$(hss_role_package "$role" 2>/dev/null) || { hss_set_outcome failed "cannot read the $role role"; return; }
    [[ -n $package ]] || { hss_set_outcome disabled "no $role application is selected"; return; }
    HSS_PROVIDER=$package
}
