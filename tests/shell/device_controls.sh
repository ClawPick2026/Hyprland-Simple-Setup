#!/usr/bin/env bash
set -euo pipefail

# D04 device providers: native modes per selected app, honest unsupported outcomes, guarded
# radio changes with read-back, and status without SSIDs, addresses or device aliases.

# shellcheck source=tests/shell/devices_session_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/devices_session_testlib.sh"

base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT
dt_setup "$base"
scripts="$XDG_CONFIG_HOME/hypr/scripts"
export WAYLAND_DISPLAY=wayland-test

# Replace the window helper with a recorder so provider argv is observable without Hyprland.
cat > "$scripts/role_window.sh" <<'EOF'
#!/usr/bin/env bash
{ printf 'role_window.sh\0'; for arg in "$@"; do printf '%s\0' "$arg"; done; } > "$DT_STATE/last/role_window.sh"
printf 'x\n' >> "$DT_STATE/count/role_window.sh"
EOF
chmod +x "$scripts/role_window.sh"

# ---------------------------------------------------------------- network: native modes
dt_roles network=networkmanager bluetooth=blueman audio=pavucontrol
dt_action network.connect.choose
dt_expect 0 accepted 'nmtui connect is accepted'
dt_wait_for kitty
dt_assert_argv kitty 'nmtui connect runs in the selected terminal' kitty --class hss-network --title network -e nmtui connect
dt_reset_calls
dt_action network.profile.edit
dt_expect 0 accepted 'nmtui edit is accepted'
dt_wait_for kitty
dt_assert_argv kitty 'nmtui edit runs in the selected terminal' kitty --class hss-network --title network -e nmtui edit
dt_reset_calls
dt_action network.open
dt_wait_for kitty
dt_assert_argv kitty 'nmtui opens its activity menu' kitty --class hss-network --title network -e nmtui
dt_ok 'nmtui: open, connect and edit use the native nmtui activities in the selected terminal'

mkdir -p "$XDG_CONFIG_HOME/hss-theme/generated/newt"
printf 'root=#cdd6f4,#11111b\n' > "$XDG_CONFIG_HOME/hss-theme/generated/newt/colors"
dt_reset_calls
dt_action network.connect.choose
dt_wait_for kitty
dt_assert_argv kitty 'nmtui receives the generated newt palette' kitty --class hss-network --title network -e \
    env COLORTERM=truecolor "NEWT_COLORS_FILE=$XDG_CONFIG_HOME/hss-theme/generated/newt/colors" nmtui connect
rm -rf "$XDG_CONFIG_HOME/hss-theme"
dt_ok 'nmtui receives NEWT_COLORS_FILE only when the theme generated it'

dt_roles network=network-manager-applet
dt_reset_calls
dt_action network.connect.choose
dt_expect 5 unsupported 'nm-applet has no command that opens its chooser'
jq -e '.reason | test("tray menu")' <<<"$DT_OUT" >/dev/null || dt_fail 'nm-applet unsupported reason'
dt_action network.profile.edit
dt_expect 0 accepted 'nm-applet edits profiles with its nm-connection-editor'
dt_wait_for nm-connection-editor
dt_assert_argv nm-connection-editor 'nm-connection-editor without arguments' nm-connection-editor
dt_action network.open
dt_wait_for nm-applet
dt_assert_argv nm-applet 'nm-applet is started when absent' nm-applet
dt_reset_calls
touch "$DT_STATE/proc/nm-applet"
dt_action network.open
dt_expect 0 accepted 'running nm-applet is not duplicated'
sleep 0.3
[[ $(dt_calls nm-applet) == 0 && $(dt_calls kitty) == 0 && $(dt_calls nm-connection-editor) == 0 ]] \
    || dt_fail 'a second nm-applet or another application was started'
rm -f "$DT_STATE/proc/nm-applet"
dt_ok 'nm-applet: chooser unsupported without substitution, editor native, no duplicate applet'

dt_roles network=nm-connection-editor
dt_reset_calls
dt_action network.connect.choose
dt_expect 5 unsupported 'nm-connection-editor cannot activate connections'
dt_action network.profile.edit
dt_wait_for nm-connection-editor
dt_assert_argv nm-connection-editor 'profile editor' nm-connection-editor
sleep 0.2
[[ $(dt_calls kitty) == 0 && $(dt_calls nm-applet) == 0 ]] || dt_fail 'unsupported chooser started another app'
dt_ok 'nm-connection-editor: editing supported, connection chooser unsupported'

dt_roles network=plasma-nm
dt_reset_calls
dt_action network.connect.choose
dt_wait_for plasmawindowed
dt_assert_argv plasmawindowed 'Plasma applet lists connections' plasmawindowed org.kde.plasma.networkmanagement
dt_action network.profile.edit
dt_wait_for kcmshell6
dt_assert_argv kcmshell6 'Plasma connection editor module' kcmshell6 kcm_networkmanagement
dt_ok 'plasma-nm: applet for connections, kcm_networkmanagement for profiles'

unset WAYLAND_DISPLAY
dt_reset_calls
dt_action network.open
dt_expect 7 unavailable 'no graphical session'
sleep 0.2
[[ $(dt_calls plasmawindowed) == 0 ]] || dt_fail 'launched without a display'
export WAYLAND_DISPLAY=wayland-test
dt_ok 'launches report unavailable without a graphical session'

# ---------------------------------------------------------------- network: Wi-Fi radio
: > "$DT_STATE/nmcli.log"
dt_state nm_wifi enabled
dt_action network.radio.set off
dt_expect 0 completed 'Wi-Fi off is read back'
jq -e '.observed.wifi_radio == "disabled"' <<<"$DT_OUT" >/dev/null || dt_fail "observed radio: $DT_OUT"
[[ $(dt_read_state nm_wifi) == disabled ]] || dt_fail 'radio state not changed'
dt_action network.radio.set off
dt_expect 0 completed 'already off'
[[ $(grep -c '^radio wifi off$' "$DT_STATE/nmcli.log") == 1 ]] || dt_fail 'an unchanged radio was set again'
dt_action network.radio.toggle
dt_expect 0 completed 'toggle reads state then enables'
[[ $(dt_read_state nm_wifi) == enabled ]] || dt_fail 'toggle did not enable'
touch "$DT_STATE/nm_lies"
dt_action network.radio.set off
dt_expect 1 failed 'a radio change that is not read back fails'
rm -f "$DT_STATE/nm_lies"
touch "$DT_STATE/nm_denied"
dt_action network.radio.set off
dt_expect 9 denied 'polkit denial maps to denied'
rm -f "$DT_STATE/nm_denied"
dt_state nm_wifi disabled
dt_state nm_wifi_hw disabled
dt_action network.radio.set on
dt_expect 7 unavailable 'hardware switch blocks Wi-Fi'
dt_state nm_wifi_hw enabled
dt_state nm_running stopped
: > "$DT_STATE/nmcli.log"
dt_action network.radio.toggle
dt_expect 7 unavailable 'NetworkManager not running'
grep -q '^radio wifi o' "$DT_STATE/nmcli.log" && dt_fail 'radio changed after a failed query'
dt_state nm_running running
dt_action network.radio.set maybe
dt_expect 2 usage 'invalid radio argument'
dt_ok 'network.radio.set/toggle: nmcli change, read-back, denial, hardware block, no change after failed query'

# ---------------------------------------------------------------- network: status
dt_roles network=network-manager-applet
dt_state nm_wifi enabled
dt_status network
jq -e '.availability == "available" and .provider == "network-manager-applet"
    and .state.backend == "networkmanager" and .state.running == true and .state.connectivity == "full"
    and .state.primary_type == "wifi" and .state.primary_state == "connected"
    and .state.wifi_radio == "enabled" and .state.signal == 72
    and .capabilities.connect == "unsupported" and .capabilities.edit == "supported" and .capabilities.radio == "supported"' \
    <<<"$DT_OUT" >/dev/null || dt_fail "network status: $DT_OUT"
grep -q -- '--rescan no' "$DT_STATE/nmcli.log" || dt_fail 'signal query may trigger a scan'
dt_state nm_devices $'ethernet:connected\nwifi:connected'
dt_status network
jq -e '.state.primary_type == "ethernet" and .state.signal == null' <<<"$DT_OUT" >/dev/null || dt_fail "ethernet preference: $DT_OUT"
dt_state nm_devices $'wifi:disconnected\nethernet:unavailable'
dt_status network
jq -e '.state.primary_type == "none" and .state.primary_state == "disconnected"' <<<"$DT_OUT" >/dev/null || dt_fail "disconnected: $DT_OUT"
dt_state nm_running stopped
dt_status network
jq -e '.availability == "unavailable" and .state.running == false and .state.wifi_radio == null' <<<"$DT_OUT" >/dev/null \
    || dt_fail "NetworkManager stopped: $DT_OUT"
dt_state nm_running running
rm -f "$DT_STATE/nm_devices"
dt_ok 'network status: typed fields, cached signal without scan, ethernet preference, stopped backend'

# ---------------------------------------------------------------- Bluetooth: radio
dt_roles bluetooth=blueman
: > "$DT_STATE/bluetoothctl.log"
dt_state bt_powered yes
dt_action bluetooth.radio.toggle
dt_expect 0 completed 'toggle off'
jq -e '.observed == {"controller":"present","powered":false,"blocked":false}' <<<"$DT_OUT" >/dev/null || dt_fail "observed: $DT_OUT"
dt_action bluetooth.radio.toggle
dt_expect 0 completed 'toggle on'
[[ $(dt_read_state bt_powered) == yes ]] || dt_fail 'not powered on'
dt_action bluetooth.radio.set on
dt_expect 0 completed 'already on'
[[ $(grep -c '^power on$' "$DT_STATE/bluetoothctl.log") == 1 ]] || dt_fail 'unchanged state was set again'
dt_ok 'bluetooth.radio.toggle/set: state read first and read back'

for scenario in no-controller abort stopped-daemon; do
    : > "$DT_STATE/bluetoothctl.log"
    dt_state bt_powered no
    case "$scenario" in
        no-controller) dt_state bt_controller absent ;;
        abort) dt_state bt_mode abort ;;
        stopped-daemon) dt_state bluez_owner false ;;
    esac
    dt_action bluetooth.radio.toggle
    dt_expect 7 unavailable "toggle with $scenario"
    grep -q '^power' "$DT_STATE/bluetoothctl.log" && dt_fail "power changed after $scenario"
    if [[ $scenario == stopped-daemon && -s $DT_STATE/bluetoothctl.log ]]; then
        dt_fail 'bluetoothctl was called although bluetoothd is not running'
    fi
    dt_state bt_controller present
    dt_state bt_mode ok
    dt_state bluez_owner true
done
dt_ok 'failed, empty or impossible Bluetooth queries never power the controller on'

dt_state bt_powered no
dt_state bt_blocked yes
: > "$DT_STATE/bluetoothctl.log"
dt_action bluetooth.radio.set on
dt_expect 7 unavailable 'blocked controller'
grep -q '^power' "$DT_STATE/bluetoothctl.log" && dt_fail 'blocked controller was asked to power on'
dt_state bt_blocked no
touch "$DT_STATE/bt_lies"
dt_action bluetooth.radio.set on
dt_expect 1 failed 'a power request that is not read back fails'
rm -f "$DT_STATE/bt_lies"
dt_ok 'blocked controllers are reported, unconfirmed power changes fail'

# Legacy keybinding entry point: notification reflects the observed result.
: > "$DT_STATE/bluetoothctl.log"
dt_state bt_powered yes
"$scripts/toggle_bluetooth.sh"
dt_assert_argv notify-send 'disabled notification' notify-send -e -u low "Bluetooth Disabled" "Bluetooth is off"
dt_state bt_controller absent
status=0
"$scripts/toggle_bluetooth.sh" || status=$?
[[ $status == 7 ]] || dt_fail "toggle_bluetooth.sh exit $status without controller"
dt_assert_argv notify-send 'failure notification' notify-send -e -u normal "Bluetooth unchanged" "no Bluetooth controller is present"
grep -q '^power on' "$DT_STATE/bluetoothctl.log" && dt_fail 'toggle_bluetooth.sh powered on after an empty observation'
dt_state bt_controller present
dt_ok 'toggle_bluetooth.sh never powers on after a failed query and reports the observed state'

# ---------------------------------------------------------------- Bluetooth: open and status
dt_reset_calls
dt_action bluetooth.open
dt_wait_for blueman-manager
dt_assert_argv blueman-manager 'Blueman manager' blueman-manager
dt_roles bluetooth=bluedevil
dt_action bluetooth.open
dt_wait_for kcmshell6
dt_assert_argv kcmshell6 'Bluedevil module' kcmshell6 kcm_bluetooth
for package in bluetui bluetuith; do
    dt_roles bluetooth=$package
    dt_reset_calls
    dt_action bluetooth.open
    dt_wait_for kitty
    dt_assert_argv kitty "$package in the selected terminal" kitty --class hss-bluetooth --title bluetooth -e "$package"
done
dt_ok 'bluetooth.open launches each of the four managers natively'

dt_state bt_powered yes
dt_state bt_connected 2
dt_status bluetooth
jq -e '.availability == "available" and .state == {"controller":"present","powered":true,"blocked":false,"connected_devices":2}
    and .capabilities.radio == "supported"' <<<"$DT_OUT" >/dev/null || dt_fail "bluetooth status: $DT_OUT"
if grep -Eq 'Secret|Private|AA:BB|00:11' <<<"$DT_OUT"; then dt_fail 'status leaked a device alias or address'; fi
dt_state bt_powered no
dt_state bt_blocked yes
dt_status bluetooth
jq -e '.state.powered == false and .state.blocked == true and .state.connected_devices == 0' <<<"$DT_OUT" >/dev/null || dt_fail "blocked status: $DT_OUT"
dt_state bt_blocked no
dt_state bt_controller absent
dt_status bluetooth
jq -e '.availability == "unavailable" and .state.controller == "absent" and .state.powered == null' <<<"$DT_OUT" >/dev/null \
    || dt_fail "no controller status: $DT_OUT"
dt_state bt_controller present
dt_state bluez_owner fail
dt_state bt_mode hang
started=$SECONDS
dt_status bluetooth
((SECONDS - started <= 8)) || dt_fail 'hung bluetoothd query was not bounded'
jq -e '.availability == "unavailable" and .state.controller == null and (.error | test("in time"))' <<<"$DT_OUT" >/dev/null \
    || dt_fail "hung status: $DT_OUT"
dt_state bt_mode ok
dt_state bluez_owner true
dt_ok 'bluetooth status: on/off/blocked/absent/unresponsive are distinct, no aliases or addresses'

# ---------------------------------------------------------------- audio
check_audio() {
    local package=$1 action=$2 status=$3
    shift 3
    dt_roles audio="$package"
    dt_reset_calls
    dt_action "$action"
    if ((status == 5)); then
        dt_expect 5 unsupported "$package $action"
        sleep 0.2
        [[ $(dt_calls role_window.sh) == 0 && $(dt_calls kitty) == 0 ]] || dt_fail "$package $action launched something"
    else
        dt_expect 0 accepted "$package $action"
        dt_wait_for role_window.sh
        dt_assert_argv role_window.sh "$package $action" role_window.sh audio "$@"
    fi
}
for package in pavucontrol pavucontrol-qt; do
    check_audio "$package" audio.open 0
    check_audio "$package" audio.streams.open 0 --tab=1
    check_audio "$package" audio.hardware.open 0 --tab=3
done
check_audio ncpamixer audio.streams.open 0 --tab=p
check_audio ncpamixer audio.hardware.open 0 --tab=o
for package in qastools alsa-utils; do
    check_audio "$package" audio.open 0
    check_audio "$package" audio.streams.open 5
    check_audio "$package" audio.hardware.open 0
done
dt_ok 'audio: stream and device views per app; ALSA mixers report unsupported streams without substitution'

# End to end through the real window helper for a terminal mixer.
cp "$dt_repo_root/dotfiles/.config/hypr/scripts/role_window.sh" "$scripts/role_window.sh"
dt_roles audio=alsa-utils
dt_reset_calls
dt_action audio.hardware.open
dt_wait_for kitty
dt_assert_argv kitty 'Alsamixer in the selected terminal' kitty --class hss-audio --title audio -e alsamixer
dt_ok 'audio.hardware.open reaches Alsamixer through role_window.sh, role_exec.sh and term_exec.sh'

dt_roles audio=pavucontrol-qt
dt_state pw_sink "0.35 [MUTED]"
dt_state pw_source "1.00"
dt_status audio
jq -e '.availability == "available" and .state == {"server":"pipewire","output_volume":35,"output_muted":true,
    "input_volume":100,"input_muted":false,"streams_supported":true}
    and .capabilities == {"streams":"supported","hardware":"supported"}' <<<"$DT_OUT" >/dev/null || dt_fail "audio status: $DT_OUT"
dt_state pw_sink none
dt_status audio
jq -e '.state.output_volume == null and .state.output_muted == null and .state.input_volume == 100' <<<"$DT_OUT" >/dev/null \
    || dt_fail "no default sink: $DT_OUT"
dt_roles audio=qastools
dt_state pw_server down
dt_status audio
jq -e '.state.server == "pulseaudio" and .state.output_volume == 40 and .state.output_muted == false
    and .state.input_volume == 100 and .state.input_muted == true and .state.streams_supported == false
    and .capabilities.streams == "unsupported"' <<<"$DT_OUT" >/dev/null || dt_fail "pactl fallback: $DT_OUT"
dt_state pa_server down
dt_status audio
jq -e '.availability == "unavailable" and .state.server == null and .state.output_volume == null' <<<"$DT_OUT" >/dev/null \
    || dt_fail "no audio server: $DT_OUT"
dt_state pw_server up
dt_state pa_server up
dt_ok 'audio status: wpctl volumes as percent, nulls without a default node, pactl fallback, unreachable server'

# ---------------------------------------------------------------- missing backends
restricted=$(dt_restricted_path)
for domain in network bluetooth audio; do
    DT_OUT=$(PATH="$restricted" "$scripts/status_read.sh" "$domain")
    jq -e '.availability == "missing-dependency"' <<<"$DT_OUT" >/dev/null || dt_fail "$domain without backend: $DT_OUT"
done
status=0
PATH="$restricted" "$scripts/action_exec.sh" --json bluetooth.radio.toggle >/dev/null || status=$?
[[ $status == 6 ]] || dt_fail "bluetooth toggle without bluetoothctl exit $status"
status=0
PATH="$restricted" "$scripts/action_exec.sh" --json network.radio.set on >/dev/null || status=$?
[[ $status == 6 ]] || dt_fail "network radio without nmcli exit $status"
dt_ok 'missing nmcli, bluetoothctl, wpctl and pactl are missing-dependency, not errors'
