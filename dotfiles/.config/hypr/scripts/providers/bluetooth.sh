#!/usr/bin/env bash
# shellcheck disable=SC2034 # HSS_PROVIDER/HSS_REASON/HSS_OBSERVED are read by action_exec.sh.

# Source-only Bluetooth provider (plan D04). Opens the selected Bluetooth manager and controls
# the adapter power through BlueZ's bluetoothctl, the backend shared by every catalog option.
# A failed or empty observation never leads to a power change. Status never contains device
# addresses or aliases. Contract: Documents/runtime-managed-configuration.md.

# shellcheck source=dotfiles/.config/hypr/scripts/providers/_launch.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/_launch.sh"

HSS_BLUETOOTH_APP_ID=hss-bluetooth

# Prints running, stopped or unknown for the org.bluez name on the system bus. bluetoothctl
# waits indefinitely for an absent bluetoothd, so a cheap bus query comes first.
hss_bluetooth_daemon_state() {
    local output
    if ! hss_have busctl; then
        printf 'unknown\n'
        return 0
    fi
    output=$(hss_run_bounded 2 busctl --system call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus NameHasOwner s org.bluez 2>/dev/null) || { printf 'unknown\n'; return 0; }
    case "$output" in
        "b true") printf 'running\n' ;;
        "b false") printf 'stopped\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

# Observe the default controller. Sets HSS_BT_CONTROLLER (present|absent), HSS_BT_POWERED and
# HSS_BT_BLOCKED (true|false|empty when unknown). Returns 1 with HSS_BT_ERROR when nothing
# trustworthy was observed.
hss_bluetooth_observe() {
    local list show status=0 powered power_state
    HSS_BT_CONTROLLER="" HSS_BT_POWERED="" HSS_BT_BLOCKED="" HSS_BT_ERROR=""
    if [[ $(hss_bluetooth_daemon_state) == stopped ]]; then
        HSS_BT_ERROR="the Bluetooth service (bluetoothd) is not running"
        return 1
    fi
    list=$(hss_run_bounded 4 bluetoothctl list 2>/dev/null) || status=$?
    if ((status != 0)); then
        case "$status" in
            124|137) HSS_BT_ERROR="the Bluetooth service did not answer in time" ;;
            *) HSS_BT_ERROR="the Bluetooth service could not be queried" ;;
        esac
        return 1
    fi
    if ! grep -q '^Controller ' <<<"$list"; then
        HSS_BT_CONTROLLER=absent
        return 0
    fi
    HSS_BT_CONTROLLER=present
    show=$(hss_run_bounded 4 bluetoothctl show 2>/dev/null) || status=$?
    if ((status != 0)); then
        HSS_BT_ERROR="the Bluetooth controller state could not be read"
        return 1
    fi
    powered=$(awk '$1 == "Powered:" { print $2; exit }' <<<"$show")
    power_state=$(awk '$1 == "PowerState:" { print $2; exit }' <<<"$show")
    case "$powered" in
        yes) HSS_BT_POWERED=true ;;
        no) HSS_BT_POWERED=false ;;
        *)
            HSS_BT_ERROR="the Bluetooth controller did not report its power state"
            return 1
            ;;
    esac
    case "$power_state" in
        off-blocked) HSS_BT_BLOCKED=true ;;
        on|off|on-disabling|off-enabling) HSS_BT_BLOCKED=false ;;
        *) HSS_BT_BLOCKED="" ;;
    esac
    return 0
}

hss_bluetooth_observed_json() {
    jq -cn --arg controller "$HSS_BT_CONTROLLER" --arg powered "$HSS_BT_POWERED" --arg blocked "$HSS_BT_BLOCKED" '
        def boolean: if . == "true" then true elif . == "false" then false else null end;
        {controller: (if $controller == "" then null else $controller end),
         powered: ($powered | boolean), blocked: ($blocked | boolean)}'
}

# hss_bluetooth_set_power true|false. Precondition: a successful observation.
hss_bluetooth_set_power() {
    local wanted=$1 word=off output status=0 attempt
    [[ $wanted == true ]] && word=on
    if [[ $HSS_BT_CONTROLLER == absent ]]; then
        HSS_OBSERVED=$(hss_bluetooth_observed_json)
        hss_set_outcome unavailable "no Bluetooth controller is present"
        return
    fi
    if [[ $HSS_BT_POWERED == "$wanted" ]]; then
        HSS_OBSERVED=$(hss_bluetooth_observed_json)
        hss_set_outcome completed "Bluetooth is already $word"
        return
    fi
    if [[ $wanted == true && $HSS_BT_BLOCKED == true ]]; then
        HSS_OBSERVED=$(hss_bluetooth_observed_json)
        hss_set_outcome unavailable "Bluetooth is blocked by rfkill or a hardware switch; unblock it first"
        return
    fi
    output=$(hss_run_bounded 10 bluetoothctl power "$word" 2>&1) || status=$?
    if ((status != 0)); then
        case "$status:$output" in
            124:*|137:*) hss_set_outcome timeout "the Bluetooth controller did not confirm the change in time" ;;
            *NotAuthorized*|*[Nn]ot\ authorized*|*[Pp]ermission\ denied*)
                hss_set_outcome denied "changing the Bluetooth power was not authorized" ;;
            *Blocked*|*rfkill*) hss_set_outcome unavailable "Bluetooth is blocked by rfkill or a hardware switch" ;;
            *"No default controller"*) hss_set_outcome unavailable "no Bluetooth controller is present" ;;
            *) hss_set_outcome failed "bluetoothctl could not turn Bluetooth $word" ;;
        esac
        return
    fi
    for ((attempt = 0; attempt < 10; attempt++)); do
        if hss_bluetooth_observe && [[ $HSS_BT_POWERED == "$wanted" ]]; then
            HSS_OBSERVED=$(hss_bluetooth_observed_json)
            hss_set_outcome completed "Bluetooth is $word"
            return
        fi
        sleep 0.2
    done
    HSS_OBSERVED=$(hss_bluetooth_observed_json)
    hss_set_outcome failed "the Bluetooth controller did not report power $word after the request"
}

hss_bluetooth_prepare() {
    HSS_PROVIDER=$(hss_role_package bluetooth 2>/dev/null) || HSS_PROVIDER=""
    hss_have bluetoothctl || { hss_set_outcome missing-dependency "bluetoothctl (bluez-utils) is not installed"; return; }
    if ! hss_bluetooth_observe; then
        hss_set_outcome unavailable "$HSS_BT_ERROR"
        return
    fi
}

# bluetooth.radio.set on|off
hss_action_bluetooth_radio_set() {
    local wanted
    case "${1:-}" in
        on) wanted=true ;;
        off) wanted=false ;;
        *) hss_set_outcome usage "bluetooth.radio.set needs on or off"; return ;;
    esac
    [[ $# -eq 1 ]] || { hss_set_outcome usage "bluetooth.radio.set takes one argument"; return; }
    hss_bluetooth_prepare || return
    hss_bluetooth_set_power "$wanted"
}

# bluetooth.radio.toggle: only a successful observation of "powered" decides the direction.
hss_action_bluetooth_radio_toggle() {
    [[ $# -eq 0 ]] || { hss_set_outcome usage "bluetooth.radio.toggle takes no arguments"; return; }
    hss_bluetooth_prepare || return
    if [[ $HSS_BT_POWERED == true ]]; then
        hss_bluetooth_set_power false
    elif [[ $HSS_BT_POWERED == false ]]; then
        hss_bluetooth_set_power true
    else
        hss_bluetooth_set_power true
    fi
}

hss_action_bluetooth_open() {
    hss_launch_select bluetooth || return
    local -a command=()
    hss_launch_role_command bluetooth command || return
    if hss_launch_role_is_terminal bluetooth; then
        hss_have "${command[0]}" || { hss_set_outcome missing-dependency "${command[0]} is not installed"; return; }
        hss_launch_terminal "$HSS_BLUETOOTH_APP_ID" bluetooth "${command[@]}" || return
        HSS_REASON="${command[0]} opened in the selected terminal"
    else
        hss_launch_gui "${command[@]}"
    fi
}

hss_bluetooth_capabilities() {
    case "${1:-}" in
        blueman|bluedevil|bluetui|bluetuith) printf '{"radio":"supported","pairing":"supported"}\n' ;;
        *) printf '{"radio":"supported","pairing":null}\n' ;;
    esac
}

hss_status_bluetooth() {
    local package capabilities connected="" devices status=0
    package=$(hss_role_package bluetooth 2>/dev/null) || package=""
    capabilities=$(hss_bluetooth_capabilities "$package")
    if ! hss_have bluetoothctl; then
        hss_status_emit bluetooth "$package" missing-dependency \
            '{"controller":null,"powered":null,"blocked":null,"connected_devices":null}' "$capabilities" "bluetoothctl is not installed"
        return 0
    fi
    if ! hss_bluetooth_observe; then
        hss_status_emit bluetooth "$package" unavailable \
            '{"controller":null,"powered":null,"blocked":null,"connected_devices":null}' "$capabilities" "$HSS_BT_ERROR"
        return 0
    fi
    if [[ $HSS_BT_CONTROLLER == absent ]]; then
        hss_status_emit bluetooth "$package" unavailable \
            '{"controller":"absent","powered":null,"blocked":null,"connected_devices":null}' "$capabilities" "no Bluetooth controller is present"
        return 0
    fi
    if [[ $HSS_BT_POWERED == true ]]; then
        # Count only; device names and addresses never leave this function.
        devices=$(hss_run_bounded 4 bluetoothctl devices Connected 2>/dev/null) || status=$?
        ((status == 0)) && connected=$(grep -c '^Device ' <<<"$devices" || true)
    elif [[ $HSS_BT_POWERED == false ]]; then
        connected=0
    fi
    hss_status_emit bluetooth "$package" available "$(jq -cn --argjson observed "$(hss_bluetooth_observed_json)" --arg connected "$connected" '
        $observed + {connected_devices: (if $connected == "" then null else ($connected | tonumber) end)}')" "$capabilities"
}
