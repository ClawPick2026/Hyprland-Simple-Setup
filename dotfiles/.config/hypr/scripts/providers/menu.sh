#!/usr/bin/env bash

# Source-only launcher provider (plan D02). Contract: Documents/runtime-managed-configuration.md.
#
#   menu.applications  standard launcher action: the launcher's native desktop-application mode
#   menu.commands      separate executable search: the launcher's native PATH/executable mode
#
# Only native launcher modes are used. A launcher without a native mode for an action returns
# `unsupported` with an explanation; no other mode or application is substituted, and no
# desktop-entry or executable discovery is implemented here. Evidence for every mode is in
# capabilities.d/d02-launchers.json.

# Exit status a launcher uses for Escape/close (observed or documented per launcher).
hss_menu_cancel_status() {
    case "$1" in
        fuzzel) printf '2\n' ;;
        *) printf '1\n' ;;
    esac
}

# Sets HSS_PROVIDER and HSS_MENU_PACKAGE, or records an outcome and returns its status.
hss_menu_selected() {
    hss_require_roles || return
    HSS_MENU_PACKAGE=$(hss_role_package launcher 2>/dev/null) || HSS_MENU_PACKAGE=""
    if [[ -z $HSS_MENU_PACKAGE ]]; then
        hss_set_outcome unavailable "no launcher is selected; rerun setup"
        return
    fi
    # shellcheck disable=SC2034 # read by action_exec.sh for the result envelope
    HSS_PROVIDER=$HSS_MENU_PACKAGE
}

# hss_menu_run PACKAGE ARGV...: run a launcher in the foreground with its stderr in the
# launcher log, then map its exit status. stdout of the launcher is discarded.
hss_menu_run() {
    local package=$1 status=0 cancel
    shift
    if [[ $1 != */* ]] && ! hss_have "$1"; then
        hss_set_outcome missing-dependency "$1 is not installed"
        return
    fi
    (
        # menu_exec.sh opens the launcher log itself.
        if [[ $1 != "$HSS_SCRIPTS_DIR/menu_exec.sh" ]]; then
            # shellcheck source=dotfiles/.config/hypr/scripts/app_log.sh
            source "$HSS_SCRIPTS_DIR/app_log.sh"
            hss_start_app_log launcher
        fi
        exec "$@"
    ) </dev/null >/dev/null || status=$?
    cancel=$(hss_menu_cancel_status "$package")
    if ((status == 0)); then
        hss_set_outcome accepted "the launcher accepted the selection"
    elif ((status == cancel)); then
        hss_set_outcome cancelled "the launcher was closed without a selection"
    else
        hss_set_outcome failed "the launcher exited with status $status"
    fi
}

hss_action_menu_applications() {
    [[ $# -eq 0 ]] || { hss_set_outcome usage "menu.applications takes no arguments"; return; }
    hss_menu_selected || return
    local executable
    case "$HSS_MENU_PACKAGE" in
        wofi|rofi|fuzzel|tofi)
            # The catalog launch argv is already the native desktop-application mode
            # (wofi/rofi drun, fuzzel's default mode, tofi-drun --drun-launch=true), so the
            # action and the Super+Space toggle open exactly the same menu.
            executable=$(hss_role_field launcher executable 2>/dev/null) || executable=""
            [[ -n $executable ]] || { hss_set_outcome failed "launcher role data is incomplete"; return; }
            hss_have "$executable" || { hss_set_outcome missing-dependency "$executable is not installed"; return; }
            hss_menu_run "$HSS_MENU_PACKAGE" "$HSS_SCRIPTS_DIR/menu_exec.sh"
            ;;
        bemenu)
            hss_set_outcome unsupported "Bemenu has no native desktop-application mode; its launcher (bemenu-run) searches executables, use the command launcher instead"
            ;;
        *)
            hss_set_outcome unsupported "$HSS_MENU_PACKAGE has no known native desktop-application mode"
            ;;
    esac
}

hss_action_menu_commands() {
    [[ $# -eq 0 ]] || { hss_set_outcome usage "menu.commands takes no arguments"; return; }
    hss_menu_selected || return
    local -a args=()
    local index replaced=false
    case "$HSS_MENU_PACKAGE" in
        wofi|rofi)
            # Same catalog argv (style and other options) with the native run mode instead of drun.
            hss_role_array launcher args args
            for index in "${!args[@]}"; do
                if [[ ${args[$index]} == drun ]]; then
                    args[index]=run
                    replaced=true
                fi
            done
            if ! $replaced; then
                if [[ $HSS_MENU_PACKAGE == wofi ]]; then args=(--show run); else args=(-show run); fi
            fi
            hss_menu_run "$HSS_MENU_PACKAGE" "$HSS_MENU_PACKAGE" "${args[@]}"
            ;;
        fuzzel)
            # Fuzzel has no executables-only mode: PATH executables are listed together with
            # applications (fuzzel --list-executables-in-path, application mode only).
            hss_role_array launcher args args
            hss_menu_run fuzzel fuzzel "${args[@]}" --list-executables-in-path
            ;;
        bemenu)
            # The catalog launcher is bemenu-run, the native executable search; menu_exec.sh keeps
            # the Wayland backend and the themed BEMENU_OPTS.
            hss_have bemenu-run || { hss_set_outcome missing-dependency "bemenu-run is not installed"; return; }
            hss_menu_run bemenu "$HSS_SCRIPTS_DIR/menu_exec.sh"
            ;;
        tofi)
            hss_menu_tofi_run
            ;;
        *)
            hss_set_outcome unsupported "$HSS_MENU_PACKAGE has no known native executable search mode"
            ;;
    esac
}

# tofi-run only prints the selected executable (upstream usage: tofi-run | xargs swaymsg exec --).
# Start exactly that executable, as one argv element, after checking it resolves on PATH.
hss_menu_tofi_run() {
    local status=0 selection resolved
    hss_have tofi-run || { hss_set_outcome missing-dependency "tofi-run is not installed"; return; }
    selection=$(
        # shellcheck source=dotfiles/.config/hypr/scripts/app_log.sh
        source "$HSS_SCRIPTS_DIR/app_log.sh"
        hss_start_app_log launcher
        exec tofi-run --require-match=true </dev/null
    ) || status=$?
    if ((status == 1)); then
        hss_set_outcome cancelled "the launcher was closed without a selection"
        return
    elif ((status != 0)); then
        hss_set_outcome failed "tofi-run exited with status $status"
        return
    fi
    [[ -n $selection ]] || { hss_set_outcome cancelled "no executable was selected"; return; }
    if [[ $selection == *$'\n'* || $selection == */* || $selection == -* ]]; then
        hss_set_outcome failed "tofi-run returned an unexpected selection"
        return
    fi
    resolved=$(command -v -- "$selection" 2>/dev/null) || resolved=""
    if [[ $resolved != /* || ! -x $resolved ]]; then
        hss_set_outcome failed "the selected executable is not on PATH"
        return
    fi
    hss_spawn "$resolved"
}

hss_status_menu() {
    local roles package capabilities applications commands running=null process
    roles=$(hss_roles_file)
    if [[ ! -r $roles ]]; then
        hss_status_emit menu "" unavailable null null "role data is missing"
        return 0
    fi
    package=$(hss_role_package launcher 2>/dev/null) || package=""
    if [[ -z $package ]]; then
        hss_status_emit menu "" unavailable null null "no launcher is selected"
        return 0
    fi
    case "$package" in
        bemenu) applications=unsupported ;;
        wofi|rofi|fuzzel|tofi) applications=supported ;;
        *) applications=unverified ;;
    esac
    case "$package" in
        wofi|rofi|bemenu|tofi) commands=supported ;;
        fuzzel) commands=partial ;;
        *) commands=unverified ;;
    esac
    capabilities=$(jq -cn --arg applications "$applications" --arg commands "$commands" \
        '{applications: $applications, commands: $commands, chooser: "supported", confirm: "supported"}')
    process=$(hss_role_field launcher process 2>/dev/null) || process=""
    if [[ -n $process ]] && hss_have pgrep; then
        if hss_process_running "$process"; then running=true; else running=false; fi
    fi
    if ! hss_have "$(hss_role_field launcher dmenu_executable 2>/dev/null || printf '%s' "$package")"; then
        hss_status_emit menu "$package" missing-dependency "{\"running\":$running}" "$capabilities" "the launcher is not installed"
        return 0
    fi
    hss_status_emit menu "$package" available "{\"running\":$running}" "$capabilities"
}
