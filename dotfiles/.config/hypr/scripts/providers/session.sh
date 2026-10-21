#!/usr/bin/env bash
# shellcheck disable=SC2034 # HSS_PROVIDER/HSS_REASON/HSS_OBSERVED are read by action_exec.sh.

# Source-only session provider (plan D07, policy P06). One set of power semantics for keys,
# bars and Wlogout: lock is immediate, suspend is direct, logout/reboot/shutdown require a
# confirmation through menu_choose.sh unless the caller already confirmed (--confirmed),
# hibernate runs only when logind reports it can, and logout ends only the current session.
# Hyprpolkitagent is the managed authentication agent; a foreign agent is never terminated.
# Contract: Documents/runtime-managed-configuration.md (sections 3, 4 and 6).

# shellcheck source=dotfiles/.config/hypr/scripts/providers/_launch.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/_launch.sh"

# Command lines of known polkit agents other than Hyprpolkitagent (matched with pgrep -f).
HSS_SESSION_FOREIGN_AGENTS='(^|/)(polkit-(kde|gnome|mate|efl)-authentication-agent-1|lxpolkit|lxqt-policykit-agent|xfce-polkit|soteria|mate-polkit|ukui-polkit|polkit-dumb-agent|io\.elementary\.desktop\.agent-polkit)( |$)'

# Parse an optional --confirmed flag. Sets HSS_SESSION_CONFIRMED=true|false.
hss_session_parse_confirmed() {
    HSS_SESSION_CONFIRMED=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --confirmed) HSS_SESSION_CONFIRMED=true ;;
            *) hss_set_outcome usage "unknown argument $1"; return ;;
        esac
        shift
    done
}

hss_session_no_arguments() {
    [[ $# -eq 0 ]] || { hss_set_outcome usage "this action takes no arguments"; return; }
}

# Ask through the shared chooser. Only an explicit Yes (exit 0) continues; anything else
# records an outcome and returns nonzero, so the caller never runs the power command.
hss_session_confirm() {
    local prompt=$1 chooser status=0
    [[ $HSS_SESSION_CONFIRMED == true ]] && return 0
    chooser="$HSS_SCRIPTS_DIR/menu_choose.sh"
    [[ -x $chooser ]] || { hss_set_outcome missing-dependency "the confirmation menu (menu_choose.sh) is not installed; nothing was done"; return; }
    hss_run_bounded 120 "$chooser" --prompt "$prompt" --confirm </dev/null >/dev/null 2>&1 || status=$?
    case "$status" in
        0) return 0 ;;
        3) hss_set_outcome cancelled "not confirmed; nothing was done" ;;
        124|137) hss_set_outcome timeout "the confirmation was not answered in time; nothing was done" ;;
        *) hss_set_outcome failed "the confirmation menu failed; nothing was done" ;;
    esac
}

# Run a systemctl power verb and map its result. The request is accepted, not observed.
hss_session_systemctl() {
    local verb=$1 label=$2 output status=0
    hss_have systemctl || { hss_set_outcome missing-dependency "systemctl is not installed"; return; }
    output=$(hss_run_bounded 60 systemctl "$verb" 2>&1) || status=$?
    if ((status == 0)); then
        hss_set_outcome accepted "$label was requested"
        return
    fi
    case "$status:$output" in
        124:*|137:*) hss_set_outcome timeout "$label was not confirmed in time; the result is unknown" ;;
        *[Aa]ccess\ denied*|*[Nn]ot\ authorized*|*[Ii]nteractive\ authentication\ required*)
            hss_set_outcome denied "$label was not authorized" ;;
        *[Ii]nhibit*) hss_set_outcome denied "$label is blocked by an inhibitor" ;;
        *) hss_set_outcome failed "$label failed" ;;
    esac
}

hss_session_id() {
    [[ ${XDG_SESSION_ID:-} =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    printf '%s\n' "$XDG_SESSION_ID"
}

# Print yes, challenge, no, na or unknown from logind's CanHibernate.
hss_session_can_hibernate() {
    local output value
    hss_have busctl || { printf 'unknown\n'; return 0; }
    output=$(hss_run_bounded 3 busctl --system call org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager CanHibernate 2>/dev/null) || { printf 'unknown\n'; return 0; }
    value=${output#s }
    value=${value//\"/}
    case "$value" in
        yes|challenge|no|na) printf '%s\n' "$value" ;;
        *) printf 'unknown\n' ;;
    esac
}

hss_action_session_lock() {
    hss_session_no_arguments "$@" || return
    HSS_PROVIDER=hyprlock
    local attempt
    if hss_process_running hyprlock; then
        HSS_OBSERVED='{"locked":true}'
        hss_set_outcome completed "the screen is already locked"
        return
    fi
    hss_have hyprlock || { hss_set_outcome missing-dependency "hyprlock is not installed"; return; }
    hss_launch_have_display || { hss_set_outcome unavailable "no graphical session is available to lock"; return; }
    hss_spawn hyprlock || return
    for ((attempt = 0; attempt < 30; attempt++)); do
        if hss_process_running hyprlock; then
            HSS_OBSERVED='{"locked":true}'
            hss_set_outcome completed "the screen is locked"
            return
        fi
        sleep 0.1
    done
    HSS_OBSERVED='{"locked":false}'
    hss_set_outcome failed "hyprlock exited without locking the screen"
}

hss_session_exit_hyprland() {
    local output status=0
    output=$(hss_run_bounded 5 hyprctl dispatch 'hl.dsp.exit()' 2>&1) || status=$?
    if ((status == 0)) && [[ ${output//[[:space:]]/} == ok ]]; then
        return 0
    fi
    if ((status == 124 || status == 137)); then
        return 124
    fi
    # A legacy hyprlang configuration rejects the Lua dispatcher; its own dispatcher is "exit".
    if [[ $output == *[Ii]nvalid\ dispatcher* || $output == *hl.dispatch* ]]; then
        status=0
        output=$(hss_run_bounded 5 hyprctl dispatch exit 2>&1) || status=$?
        ((status == 0)) && [[ ${output//[[:space:]]/} == ok ]] && return 0
        ((status == 124 || status == 137)) && return 124
    fi
    return 1
}

# Logout ends only the current session: Hyprland's own exit inside Hyprland, otherwise logind
# for the known session ID. Without either, nothing is done; all sessions of the user are
# never ended as a fallback.
hss_action_session_logout() {
    hss_session_parse_confirmed "$@" || return
    HSS_PROVIDER=session
    local session_id="" in_hyprland=false status=0 output
    session_id=$(hss_session_id) || session_id=""
    if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && hss_have hyprctl; then
        in_hyprland=true
    fi
    if ! $in_hyprland && { [[ -z $session_id ]] || ! hss_have loginctl; }; then
        hss_set_outcome unavailable "the current session cannot be identified (no Hyprland instance and no session ID); nothing was done"
        return
    fi
    hss_session_confirm "Log out of this session?" || return
    if $in_hyprland; then
        HSS_PROVIDER=hyprland
        hss_session_exit_hyprland || status=$?
        if ((status == 0)); then
            hss_set_outcome accepted "Hyprland is exiting; only this session ends"
            return
        fi
        if ((status == 124)); then
            hss_set_outcome timeout "Hyprland did not answer the exit request in time; the result is unknown"
            return
        fi
        if [[ -z $session_id ]] || ! hss_have loginctl; then
            hss_set_outcome failed "Hyprland did not accept the exit request and the session ID is unknown; nothing else was done"
            return
        fi
    fi
    HSS_PROVIDER=logind
    status=0
    output=$(hss_run_bounded 10 loginctl terminate-session "$session_id" 2>&1) || status=$?
    if ((status == 0)); then
        hss_set_outcome accepted "the current session is ending"
    elif ((status == 124 || status == 137)); then
        hss_set_outcome timeout "logind did not answer in time; the result is unknown"
    elif [[ $output == *[Aa]ccess\ denied* || $output == *[Nn]ot\ authorized* ]]; then
        hss_set_outcome denied "ending the session was not authorized"
    else
        hss_set_outcome failed "logind could not end the current session"
    fi
}

hss_action_session_reboot() {
    hss_session_parse_confirmed "$@" || return
    HSS_PROVIDER=logind
    hss_have systemctl || { hss_set_outcome missing-dependency "systemctl is not installed"; return; }
    hss_session_confirm "Restart the computer?" || return
    hss_session_systemctl reboot "Restart"
}

hss_action_session_shutdown() {
    hss_session_parse_confirmed "$@" || return
    HSS_PROVIDER=logind
    hss_have systemctl || { hss_set_outcome missing-dependency "systemctl is not installed"; return; }
    hss_session_confirm "Shut down the computer?" || return
    hss_session_systemctl poweroff "Shutdown"
}

# Suspend is direct. Hypridle's before_sleep_cmd locks the session before sleeping.
hss_action_session_suspend() {
    hss_session_no_arguments "$@" || return
    HSS_PROVIDER=logind
    hss_session_systemctl suspend "Suspend"
}

hss_action_session_hibernate() {
    hss_session_no_arguments "$@" || return
    HSS_PROVIDER=logind
    local can
    can=$(hss_session_can_hibernate)
    case "$can" in
        yes|challenge) hss_session_systemctl hibernate "Hibernate" ;;
        na) hss_set_outcome unsupported "hibernation is not available on this system (logind reports no usable swap or resume setup)" ;;
        no) hss_set_outcome unsupported "hibernation is not permitted on this system (logind policy)" ;;
        *) hss_set_outcome unsupported "hibernation prerequisites could not be verified (logind did not answer); nothing was done" ;;
    esac
}

# Write a copy of the Wlogout layout without the hibernate button. Prints the path.
hss_session_layout_without_hibernate() {
    local source="$HOME/.config/wlogout/layout" directory target tmp
    [[ -r $source ]] || source=/etc/wlogout/layout
    [[ -r $source ]] || return 1
    [[ -n ${XDG_RUNTIME_DIR:-} && -d $XDG_RUNTIME_DIR && -w $XDG_RUNTIME_DIR ]] || return 1
    directory="$XDG_RUNTIME_DIR/hyprland-simple-setup"
    (umask 077 && mkdir -p -- "$directory") || return 1
    target="$directory/wlogout-layout"
    tmp=$(mktemp "$directory/.wlogout-layout.XXXXXX") || return 1
    # Wlogout layouts are JSON objects separated by commas; the copy keeps the shipped style.
    if sed -E 's/^(.*\})[[:space:]]*,[[:space:]]*$/\1/' "$source" \
        | jq --indent 4 'select(type == "object" and .label != "hibernate")' 2>/dev/null \
        | awk '{ line[NR] = $0 } END { for (i = 1; i <= NR; i++) print (line[i] == "}" && i < NR) ? "}," : line[i] }' > "$tmp" \
        && [[ -s $tmp ]] && mv -f -- "$tmp" "$target"; then
        printf '%s\n' "$target"
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

# hss_session_wlogout_command ARRAY_NAME: Wlogout argv shared by session.power_screen and the
# Waybar launcher. The hibernate button is offered only when logind reports it can hibernate.
hss_session_wlogout_command() {
    local -n hss_session_wlogout_target=$1
    local layout can
    hss_session_wlogout_target=(wlogout --protocol layer-shell --css "$HOME/.config/wlogout/style.css")
    can=$(hss_session_can_hibernate)
    if [[ $can != yes && $can != challenge ]] && layout=$(hss_session_layout_without_hibernate); then
        hss_session_wlogout_target+=(--layout "$layout")
    fi
}

hss_action_session_power_screen() {
    hss_session_no_arguments "$@" || return
    HSS_PROVIDER=wlogout
    local -a command=()
    hss_have wlogout || { hss_set_outcome missing-dependency "wlogout is not installed"; return; }
    hss_launch_have_display || { hss_set_outcome unavailable "no graphical session is available"; return; }
    if hss_process_running wlogout; then
        hss_set_outcome accepted "the power screen is already open"
        return
    fi
    hss_session_wlogout_command command
    hss_spawn "${command[@]}" || return
    HSS_REASON="the power screen was opened"
}

# Prints hyprpolkitagent, foreign or none. Read-only.
hss_session_auth_owner() {
    if hss_have systemctl && hss_run_bounded 3 systemctl --user is-active --quiet hyprpolkitagent.service 2>/dev/null; then
        printf 'hyprpolkitagent\n'
    elif hss_process_running hyprpolkitagent; then
        printf 'hyprpolkitagent\n'
    elif pgrep -u "$(id -u)" -f -- "$HSS_SESSION_FOREIGN_AGENTS" >/dev/null 2>&1; then
        printf 'foreign\n'
    else
        printf 'none\n'
    fi
}

hss_session_foreign_agent_name() {
    local line command
    line=$(pgrep -u "$(id -u)" -a -f -- "$HSS_SESSION_FOREIGN_AGENTS" 2>/dev/null | head -n 1) || return 1
    command=${line#* }
    command=${command%% *}
    hss_sanitize_label "${command##*/}"
}

# Start the managed authentication agent. A running foreign agent is reported as a conflict
# and left untouched: polkit accepts one agent per session.
hss_action_session_auth_start() {
    hss_session_no_arguments "$@" || return
    HSS_PROVIDER=hyprpolkitagent
    local owner load status=0 name
    hss_have systemctl || { hss_set_outcome missing-dependency "systemctl is not installed"; return; }
    owner=$(hss_session_auth_owner)
    case "$owner" in
        hyprpolkitagent)
            HSS_OBSERVED='{"auth_agent":"hyprpolkitagent"}'
            hss_set_outcome completed "hyprpolkitagent is already running"
            return
            ;;
        foreign)
            name=$(hss_session_foreign_agent_name) || name="another polkit agent"
            HSS_OBSERVED='{"auth_agent":"foreign"}'
            hss_set_outcome conflict "another authentication agent ($name) is running and was left untouched; stop it to use hyprpolkitagent"
            return
            ;;
    esac
    load=$(hss_run_bounded 5 systemctl --user show -p LoadState --value hyprpolkitagent.service 2>/dev/null) || status=$?
    if ((status != 0)); then
        hss_set_outcome unavailable "the systemd user manager is not reachable"
        return
    fi
    [[ ${load//[[:space:]]/} == loaded ]] || { hss_set_outcome missing-dependency "hyprpolkitagent is not installed"; return; }
    hss_run_bounded 15 systemctl --user start hyprpolkitagent.service >/dev/null 2>&1 || status=$?
    if ((status == 124 || status == 137)); then
        hss_set_outcome timeout "hyprpolkitagent did not start in time; the result is unknown"
        return
    elif ((status != 0)); then
        hss_set_outcome failed "systemd could not start hyprpolkitagent"
        return
    fi
    if hss_run_bounded 3 systemctl --user is-active --quiet hyprpolkitagent.service 2>/dev/null; then
        HSS_OBSERVED='{"auth_agent":"hyprpolkitagent"}'
        hss_set_outcome completed "hyprpolkitagent is running"
    else
        HSS_OBSERVED='{"auth_agent":null}'
        hss_set_outcome failed "hyprpolkitagent did not stay active (another agent may own the session, or the user manager lacks WAYLAND_DISPLAY)"
    fi
}

hss_status_session() {
    local can owner locked=false hibernate=null session_known=false lock_capability=unsupported
    can=$(hss_session_can_hibernate)
    case "$can" in
        yes|challenge) hibernate=true ;;
        no|na) hibernate=false ;;
    esac
    owner=$(hss_session_auth_owner)
    hss_process_running hyprlock && locked=true
    hss_session_id >/dev/null && session_known=true
    hss_have hyprlock && lock_capability=supported
    hss_status_emit session "" available "$(jq -cn --argjson hibernate "$hibernate" --arg owner "$owner" \
        --argjson locked "$locked" --argjson known "$session_known" --arg hyprland "${HYPRLAND_INSTANCE_SIGNATURE:+true}" '
        {hibernate_available: $hibernate, auth_agent: $owner, locked: $locked,
         session_identified: ($known or $hyprland == "true")}')" \
        "$(jq -cn --arg hibernate "$can" --arg lock "$lock_capability" '
        {lock: $lock, logout: "supported", reboot: "supported", shutdown: "supported", suspend: "supported",
         hibernate: (if $hibernate == "yes" or $hibernate == "challenge" then "supported"
                     elif $hibernate == "unknown" then "unverified" else "unsupported" end)}')"
}
