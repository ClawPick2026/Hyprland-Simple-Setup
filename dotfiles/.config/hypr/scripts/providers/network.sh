#!/usr/bin/env bash
# shellcheck disable=SC2034 # HSS_PROVIDER/HSS_REASON/HSS_OBSERVED are read by action_exec.sh.

# Source-only network provider (plan D04). Opens the selected network application only in
# the modes it supports natively and controls the Wi-Fi radio through NetworkManager's own
# nmcli, the backend shared by every catalog option. Status never contains SSIDs, profile
# names or addresses. Contract: Documents/runtime-managed-configuration.md.

# shellcheck source=dotfiles/.config/hypr/scripts/providers/_launch.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/_launch.sh"

# Same window identity as role_exec.sh uses for the terminal-wrapped network role.
HSS_NETWORK_APP_ID=hss-network

hss_network_newt_colors() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/hss-theme/generated/newt/colors"
}

# nmtui [MODE]: libnewt reads NEWT_COLORS_FILE; COLORTERM enables its 24-bit color names.
hss_network_nmtui() {
    hss_have nmtui || { hss_set_outcome missing-dependency "nmtui is not installed"; return; }
    local colors
    local -a command=(nmtui "$@")
    colors=$(hss_network_newt_colors)
    if [[ -r $colors ]]; then
        command=(env COLORTERM=truecolor "NEWT_COLORS_FILE=$colors" "${command[@]}")
    fi
    hss_launch_terminal "$HSS_NETWORK_APP_ID" network "${command[@]}" || return
    HSS_REASON="nmtui${1:+ $1} opened in the selected terminal"
}

hss_action_network_open() {
    hss_launch_select network || return
    local -a command=()
    hss_launch_role_command network command || return
    case "$HSS_PROVIDER" in
        networkmanager) hss_network_nmtui "${command[@]:1}" ;;
        network-manager-applet)
            # The applet is a persistent tray program; never start a duplicate.
            if hss_process_running nm-applet; then
                hss_set_outcome accepted "nm-applet is already running; use its tray icon"
            else
                hss_launch_gui "${command[@]}"
            fi
            ;;
        *)
            if hss_launch_role_is_terminal network; then
                hss_have "${command[0]}" || { hss_set_outcome missing-dependency "${command[0]} is not installed"; return; }
                hss_launch_terminal "$HSS_NETWORK_APP_ID" network "${command[@]}"
            else
                hss_launch_gui "${command[@]}"
            fi
            ;;
    esac
}

hss_action_network_connect_choose() {
    hss_launch_select network || return
    local -a command=()
    case "$HSS_PROVIDER" in
        networkmanager) hss_network_nmtui connect ;;
        plasma-nm)
            # The Plasma network applet lists available connections with connect buttons.
            hss_launch_role_command network command || return
            hss_launch_gui "${command[@]}"
            ;;
        network-manager-applet)
            hss_set_outcome unsupported "nm-applet offers connections only from its tray menu; it has no command that opens the chooser"
            ;;
        nm-connection-editor)
            hss_set_outcome unsupported "nm-connection-editor edits connection profiles; it cannot activate connections"
            ;;
        *) hss_set_outcome unsupported "$HSS_PROVIDER has no known native connection chooser" ;;
    esac
}

hss_action_network_profile_edit() {
    hss_launch_select network || return
    case "$HSS_PROVIDER" in
        networkmanager) hss_network_nmtui edit ;;
        # nm-connection-editor is the applet's own editor (a dependency of network-manager-applet).
        network-manager-applet|nm-connection-editor) hss_launch_gui nm-connection-editor ;;
        # kcm_networkmanagement ships in plasma-nm; the applet opens the same module.
        plasma-nm) hss_launch_gui kcmshell6 kcm_networkmanagement ;;
        *) hss_set_outcome unsupported "$HSS_PROVIDER has no known native profile editor" ;;
    esac
}

# Print "enabled" or "disabled" for the Wi-Fi radio switch. Returns nmcli's status on failure.
hss_network_read_radio() {
    local output status=0
    output=$(hss_run_bounded 5 nmcli radio wifi 2>/dev/null) || status=$?
    ((status == 0)) || return "$status"
    output=${output//[[:space:]]/}
    case "$output" in
        enabled|disabled) printf '%s\n' "$output" ;;
        *) return 1 ;;
    esac
}

hss_network_query_failure() {
    local status=$1
    case "$status" in
        8) hss_set_outcome unavailable "NetworkManager is not running" ;;
        124|137) hss_set_outcome unavailable "NetworkManager did not answer in time" ;;
        *) hss_set_outcome unavailable "NetworkManager could not be queried" ;;
    esac
}

hss_network_set_radio() {
    local wanted=$1 current hardware output status=0 observed switch=off
    [[ $wanted == enabled ]] && switch=on
    current=$(hss_network_read_radio) || { hss_network_query_failure $?; return; }
    if [[ $current == "$wanted" ]]; then
        HSS_OBSERVED=$(jq -cn --arg radio "$current" '{wifi_radio: $radio}')
        hss_set_outcome completed "Wi-Fi is already ${wanted}"
        return
    fi
    if [[ $wanted == enabled ]]; then
        hardware=$(hss_run_bounded 5 nmcli -t -f WIFI-HW general 2>/dev/null) || hardware=""
        case "${hardware//[[:space:]]/}" in
            missing) hss_set_outcome unavailable "no Wi-Fi hardware is present"; return ;;
            disabled) hss_set_outcome unavailable "Wi-Fi is disabled by a hardware switch"; return ;;
        esac
    fi
    output=$(hss_run_bounded 10 nmcli radio wifi "$switch" 2>&1) || status=$?
    if ((status != 0)); then
        case "$status:$output" in
            124:*|137:*) hss_set_outcome timeout "NetworkManager did not confirm the Wi-Fi change in time" ;;
            8:*) hss_set_outcome unavailable "NetworkManager is not running" ;;
            *[Nn]ot\ authorized*|*[Ii]nsufficient\ privileges*|*[Pp]ermission\ denied*)
                hss_set_outcome denied "changing the Wi-Fi radio was not authorized" ;;
            *) hss_set_outcome failed "nmcli could not change the Wi-Fi radio" ;;
        esac
        return
    fi
    observed=$(hss_network_read_radio) || observed=""
    HSS_OBSERVED=$(jq -cn --arg radio "$observed" '{wifi_radio: (if $radio == "" then null else $radio end)}')
    if [[ $observed == "$wanted" ]]; then
        hss_set_outcome completed "Wi-Fi is ${wanted}"
    else
        hss_set_outcome failed "NetworkManager still reports Wi-Fi as ${observed:-unknown}"
    fi
}

# network.radio.set on|off: Wi-Fi radio through nmcli, read back afterwards.
hss_action_network_radio_set() {
    local wanted
    case "${1:-}" in
        on) wanted=enabled ;;
        off) wanted=disabled ;;
        *) hss_set_outcome usage "network.radio.set needs on or off"; return ;;
    esac
    [[ $# -eq 1 ]] || { hss_set_outcome usage "network.radio.set takes one argument"; return; }
    HSS_PROVIDER=$(hss_role_package network 2>/dev/null) || HSS_PROVIDER=""
    hss_have nmcli || { hss_set_outcome missing-dependency "nmcli (NetworkManager) is not installed"; return; }
    hss_network_set_radio "$wanted"
}

# network.radio.toggle: reads the current state first; a failed query changes nothing.
hss_action_network_radio_toggle() {
    [[ $# -eq 0 ]] || { hss_set_outcome usage "network.radio.toggle takes no arguments"; return; }
    HSS_PROVIDER=$(hss_role_package network 2>/dev/null) || HSS_PROVIDER=""
    hss_have nmcli || { hss_set_outcome missing-dependency "nmcli (NetworkManager) is not installed"; return; }
    local current
    current=$(hss_network_read_radio) || { hss_network_query_failure $?; return; }
    if [[ $current == enabled ]]; then
        hss_network_set_radio disabled
    else
        hss_network_set_radio enabled
    fi
}

hss_network_capabilities() {
    case "${1:-}" in
        networkmanager|plasma-nm) printf '{"connect":"supported","edit":"supported","radio":"supported"}\n' ;;
        network-manager-applet|nm-connection-editor) printf '{"connect":"unsupported","edit":"supported","radio":"supported"}\n' ;;
        *) printf 'null\n' ;;
    esac
}

# Pick the primary device from "TYPE:STATE" lines: ethernet before Wi-Fi before others,
# approximating NetworkManager's default-route preference. Prints "type<TAB>state".
hss_network_primary() {
    awk -F: '
        function kind(type) {
            if (type == "ethernet") return "ethernet"
            if (type == "wifi") return "wifi"
            return "other"
        }
        function rank(type) { return type == "ethernet" ? 0 : (type == "wifi" ? 1 : 2) }
        $1 == "" || $1 == "loopback" || $1 == "wifi-p2p" { next }
        {
            state = $2
            if (state ~ /^connected/) level = 3
            else if (state ~ /^connecting/) level = 2
            else if (state ~ /^disconnected/) level = 1
            else if (state ~ /^unavailable/) level = 0
            else next
            if (level > best || (level == best && rank($1) < best_rank)) {
                best = level; best_rank = rank($1); best_type = kind($1)
            }
            seen = 1
        }
        BEGIN { best = -1; best_rank = 9 }
        END {
            if (!seen) { print "none\tunavailable"; exit }
            if (best == 3) print best_type "\tconnected"
            else if (best == 2) print best_type "\tconnecting"
            else if (best == 1) print "none\tdisconnected"
            else print "none\tunavailable"
        }
    '
}

hss_status_network() {
    local package capabilities general status=0 running="" connectivity="" wifi_hw="" wifi="" state_text=""
    local primary_type="" primary_state="" signal="" wifi_radio="" devices primary
    package=$(hss_role_package network 2>/dev/null) || package=""
    capabilities=$(hss_network_capabilities "$package")
    if ! hss_have nmcli; then
        hss_status_emit network "$package" missing-dependency \
            '{"backend":"networkmanager","running":null,"connectivity":null,"primary_type":null,"primary_state":null,"wifi_radio":null,"signal":null}' \
            "$capabilities" "nmcli is not installed"
        return 0
    fi
    general=$(hss_run_bounded 3 nmcli -t -f RUNNING,STATE,CONNECTIVITY,WIFI-HW,WIFI general 2>/dev/null) || status=$?
    if ((status != 0)); then
        if ((status == 8)); then
            hss_status_emit network "$package" unavailable \
                '{"backend":"networkmanager","running":false,"connectivity":null,"primary_type":null,"primary_state":null,"wifi_radio":null,"signal":null}' \
                "$capabilities" "NetworkManager is not running"
        else
            hss_status_emit network "$package" unavailable \
                '{"backend":"networkmanager","running":null,"connectivity":null,"primary_type":null,"primary_state":null,"wifi_radio":null,"signal":null}' \
                "$capabilities" "NetworkManager could not be queried"
        fi
        return 0
    fi
    IFS=: read -r running state_text connectivity wifi_hw wifi <<<"$(head -n 1 <<<"$general")"
    case "$wifi_hw" in
        missing|disabled) wifi_radio=unavailable ;;
        *) case "$wifi" in enabled|disabled) wifi_radio=$wifi ;; esac ;;
    esac
    case "$connectivity" in full|limited|portal|none|unknown) ;; *) connectivity="" ;; esac
    if devices=$(hss_run_bounded 3 nmcli -t -f TYPE,STATE device 2>/dev/null); then
        primary=$(hss_network_primary <<<"$devices")
        IFS=$'\t' read -r primary_type primary_state <<<"$primary"
    fi
    if [[ $primary_type == wifi ]]; then
        # Cached access-point list only: no scan is triggered and no SSID is requested.
        signal=$(hss_run_bounded 3 nmcli -t -f IN-USE,SIGNAL device wifi list --rescan no 2>/dev/null \
            | awk -F: '$1 == "*" && $2 ~ /^[0-9]+$/ { print $2; exit }') || signal=""
    fi
    hss_status_emit network "$package" available "$(jq -cn \
        --arg running "$running" --arg connectivity "$connectivity" --arg primary_type "$primary_type" \
        --arg primary_state "$primary_state" --arg wifi_radio "$wifi_radio" --arg signal "$signal" --arg state "$state_text" '
        def nullable: if . == "" then null else . end;
        {backend: "networkmanager",
         running: (if $running == "running" then true elif $running == "" then null else false end),
         connectivity: ($connectivity | nullable),
         primary_type: ($primary_type | nullable),
         primary_state: ($primary_state | nullable),
         wifi_radio: ($wifi_radio | nullable),
         signal: (if $signal == "" then null else ($signal | tonumber) end),
         networking: (if $state == "" then null elif $state == "asleep" then false else true end)}')" "$capabilities"
}
