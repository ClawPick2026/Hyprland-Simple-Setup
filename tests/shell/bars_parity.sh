#!/usr/bin/env bash
set -euo pipefail

# D01.1/D01.3: the active Waybar baseline, its gestures and menus, the status adapters for
# notifications, theme and absent hardware, the role updater for existing configurations,
# and the Ironbar/nwg-panel parity tables. Hermetic: every command runs against stubs.
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
waybar_dir="$repo_root/dotfiles/.config/waybar"
unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export HOME="$fixture/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$fixture/state"
mkdir -p "$HOME/.config/hypr/scripts" "$HOME/.config/waybar/scripts" "$fixture/bin"
export INVOCATIONS="$fixture/invocations.jsonl"

# One recorder for every gesture target: a JSON line with the program name and its argv.
cat > "$fixture/bin/recorder" <<'STUB'
#!/usr/bin/env bash
jq -cn --args '[$ARGS.positional[]]' -- "${0##*/}" "$@" >> "$INVOCATIONS"
STUB
chmod +x "$fixture/bin/recorder"
for target in action_exec.sh float_calendar.sh menu_exec.sh term_exec.sh; do
  ln -s "$fixture/bin/recorder" "$HOME/.config/hypr/scripts/$target"
done
for target in launch_power_screen.sh keybinds.py snapshot.sh confirm_system_update.sh \
  launch_system_update.sh backlight.sh sensor.sh; do
  ln -s "$fixture/bin/recorder" "$HOME/.config/waybar/scripts/$target"
done

# 1. The shipped configuration parses with the launcher's JSONC grammar.
python3 -B "$waybar_dir/scripts/hss_jsonc.py" "$waybar_dir/config.jsonc" || fail 'shipped Waybar JSONC parses'
printf 'ok - shipped Waybar configuration parses as JSONC\n'

# 2. Extract every gesture of the active modules (module, gesture, command) as TSV.
PYTHONDONTWRITEBYTECODE=1 python3 - "$waybar_dir" > "$fixture/gestures.tsv" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1] + '/scripts')
from hss_jsonc import json_text
config = json.loads(json_text(Path(sys.argv[1], 'config.jsonc').read_text()))
active = config['modules-left'] + config.get('modules-center', []) + config['modules-right']
assert len(active) == len(set(active)), 'duplicate active modules'
for module in active:
    definition = config.get(module)
    assert isinstance(definition, dict), f'{module} has no definition'
    for key, value in definition.items():
        if key.startswith('on-click') or key.startswith('on-scroll'):
            print(f'{module}\t{key}\t{value}')
    for entry, command in definition.get('menu-actions', {}).items():
        print(f'{module}\tmenu:{entry}\t{command}')
PY

# The approved baseline: active modules in order, then one expected argv per gesture.
expected_left='custom/power custom/menu tray hyprland/workspaces hyprland/submap'
expected_right='pulseaudio backlight custom/backlight-unavailable custom/temperature keyboard-state custom/keyboard-state-unavailable battery custom/battery-unavailable network bluetooth custom/updates custom/notification custom/theme clock'
actual_left=$(python3 -B -c 'import json,sys; sys.path.insert(0,sys.argv[1]+"/scripts"); from hss_jsonc import json_text; c=json.loads(json_text(open(sys.argv[1]+"/config.jsonc").read())); print(" ".join(c["modules-left"]))' "$waybar_dir")
actual_right=$(python3 -B -c 'import json,sys; sys.path.insert(0,sys.argv[1]+"/scripts"); from hss_jsonc import json_text; c=json.loads(json_text(open(sys.argv[1]+"/config.jsonc").read())); print(" ".join(c["modules-right"]))' "$waybar_dir")
[[ $actual_left == "$expected_left" ]] || fail "active left modules: $actual_left"
[[ $actual_right == "$expected_right" ]] || fail "active right modules: $actual_right"
printf 'ok - active Waybar modules keep the baseline order plus the theme control and unavailable-hardware companions\n'

cat > "$fixture/expected.tsv" <<'TABLE'
custom/power	on-click	["launch_power_screen.sh"]
custom/power	menu:suspend	["action_exec.sh","session.suspend"]
custom/power	menu:hibernate	["action_exec.sh","session.hibernate"]
custom/power	menu:shutdown	["action_exec.sh","session.shutdown"]
custom/power	menu:reboot	["action_exec.sh","session.reboot"]
custom/power	menu:logout	["action_exec.sh","session.logout"]
custom/menu	on-click	["menu_exec.sh","--toggle"]
custom/menu	menu:keybinds	["keybinds.py"]
custom/menu	menu:drun	["menu_exec.sh"]
custom/menu	menu:open_keybinds	["term_exec.sh","--app-id","hss-keybinds","--title","Keybinds","--","sh","-c"]
custom/menu	menu:snapshot	["snapshot.sh"]
hyprland/workspaces	on-click	native:activate
pulseaudio	on-click	["action_exec.sh","audio.streams.open"]
pulseaudio	on-click-right	["action_exec.sh","audio.hardware.open"]
backlight	menu:set-to-100	["backlight.sh","100"]
backlight	menu:set-to-75	["backlight.sh","75"]
backlight	menu:set-to-50	["backlight.sh","50"]
backlight	menu:set-to-25	["backlight.sh","25"]
backlight	menu:set-to-10	["backlight.sh","10"]
custom/temperature	on-click	["sensor.sh"]
network	on-click	["action_exec.sh","network.connect.choose"]
network	on-click-right	["action_exec.sh","network.profile.edit"]
bluetooth	on-click	["action_exec.sh","bluetooth.open"]
bluetooth	on-click-right	["action_exec.sh","bluetooth.radio.toggle"]
custom/updates	on-click	["confirm_system_update.sh"]
custom/updates	menu:check	["launch_system_update.sh","--check"]
custom/updates	menu:update	["launch_system_update.sh"]
custom/updates	menu:update-no-aur	["launch_system_update.sh","--without-aur"]
custom/updates	menu:firmware	["launch_system_update.sh","--firmware"]
custom/updates	menu:review-pacnew	["launch_system_update.sh","--review-pacnew"]
custom/updates	menu:clean-cache	["launch_system_update.sh","--clean-cache"]
custom/updates	menu:show-log	["launch_system_update.sh","--show-log"]
custom/notification	on-click	["action_exec.sh","notifications.primary"]
custom/notification	on-click-right	["action_exec.sh","notifications.dnd.toggle"]
custom/theme	on-click	["action_exec.sh","theme.toggle"]
clock	on-click	["float_calendar.sh"]
TABLE
[[ $(cut -f1,2 "$fixture/gestures.tsv") == "$(cut -f1,2 "$fixture/expected.tsv")" ]] \
  || { diff <(cut -f1,2 "$fixture/expected.tsv") <(cut -f1,2 "$fixture/gestures.tsv") >&2; fail 'gesture inventory equals the baseline table'; }
printf 'ok - every active gesture and menu entry is in the baseline table and nothing else is bound\n'

# 3. Run each gesture the way Waybar does (sh -c) and require exactly one intended invocation.
while IFS=$'\t' read -r module gesture expected; do
  command=$(awk -F'\t' -v m="$module" -v g="$gesture" '$1 == m && $2 == g { print $3 }' "$fixture/gestures.tsv")
  if [[ $expected == native:* ]]; then
    [[ $command == "${expected#native:}" ]] || fail "$module $gesture uses the native ${expected#native:} action"
    continue
  fi
  : > "$INVOCATIONS"
  PATH="$fixture/bin:$PATH" sh -c "$command" </dev/null >/dev/null 2>&1 || fail "$module $gesture command runs"
  [[ $(wc -l < "$INVOCATIONS") -eq 1 ]] || fail "$module $gesture invokes exactly one program"
  length=$(jq 'length' <<<"$expected")
  [[ $(jq -c --argjson n "$length" '.[0:$n]' "$INVOCATIONS") == "$(jq -c . <<<"$expected")" ]] \
    || fail "$module $gesture argv: $(cat "$INVOCATIONS")"
done < "$fixture/expected.tsv"
printf 'ok - each gesture and menu entry reaches exactly one intended invocation with literal argv\n'

# 4. Menu XML item IDs equal the configured actions, in order.
PYTHONDONTWRITEBYTECODE=1 python3 - "$waybar_dir" <<'PY'
import json, sys
from pathlib import Path
from xml.etree import ElementTree
sys.path.insert(0, sys.argv[1] + '/scripts')
from hss_jsonc import json_text
root = Path(sys.argv[1])
config = json.loads(json_text((root / 'config.jsonc').read_text()))
expected = {
    'custom/power': ['suspend', 'hibernate', 'shutdown', 'reboot', 'logout'],
    'custom/menu': ['drun', 'keybinds', 'open_keybinds', 'snapshot'],
    'backlight': ['set-to-100', 'set-to-75', 'set-to-50', 'set-to-25', 'set-to-10'],
    'custom/updates': ['check', 'update', 'update-no-aur', 'firmware', 'review-pacnew', 'clean-cache', 'show-log'],
}
for module, ids in expected.items():
    definition = config[module]
    assert definition['menu'] == 'on-click-right', module
    menu_file = Path(definition['menu-file'].replace('$HOME/.config/waybar', str(root)).replace('~/.config/waybar', str(root)))
    items = [item.attrib['id'] for item in ElementTree.parse(menu_file).findall(".//object[@class='GtkMenuItem']")]
    assert items == ids, (module, items)
    assert sorted(definition['menu-actions']) == sorted(ids), (module, definition['menu-actions'])
PY
printf 'ok - power, tools, backlight and update menus list exactly their configured actions in order\n'

# 5. Status adapters read a stateful status double; changing the state changes the output.
export HSS_SCRIPTS_DIR="$fixture/scripts"
mkdir -p "$HSS_SCRIPTS_DIR"
cat > "$HSS_SCRIPTS_DIR/status_read.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$STATUS_CALLS"
file="$STATUS_DIR/$1.json"
[[ -r $file ]] && cat -- "$file" || printf 'not json\n'
STUB
chmod +x "$HSS_SCRIPTS_DIR/status_read.sh"
export STATUS_DIR="$fixture/status" STATUS_CALLS="$fixture/status-calls"
mkdir -p "$STATUS_DIR"
export HSS_ROLES_FILE="$fixture/roles.json"
printf '{"schema_version":2,"roles":{"notifications":{"package":"mako"}},"selected":{}}\n' > "$HSS_ROLES_FILE"

notification_state() {
  # provider availability state-json capabilities-json [error]
  jq -cn --arg provider "$1" --arg availability "$2" --argjson state "$3" --argjson capabilities "$4" --arg error "${5:-}" \
    '{schema: 1, domain: "notifications", provider: (if $provider == "" then null else $provider end),
      availability: $availability, observed_at: "2026-10-20T10:00:00Z", state: $state,
      capabilities: $capabilities, error: (if $error == "" then null else $error end)}' > "$STATUS_DIR/notifications.json"
}
notify_once() {
  "$waybar_dir/scripts/notification_status.sh" --once "$@"
}
check_notification() {
  local description=$1 filter=$2 output
  output=$(notify_once)
  jq -e "$filter" <<<"$output" >/dev/null || fail "$description: $output"
}

notification_state swaync available '{"running":true,"dnd":false,"count":2,"history_count":5,"center_visible":false,"inhibited":false}' '{"dnd":"supported","history":"supported"}'
check_notification 'SwayNC waiting count' '.alt == "notification" and .text == "2" and .class == ["notification","swaync"] and (.tooltip | contains("Waiting: 2") and contains("Do not disturb: off"))'
notification_state mako available '{"running":true,"dnd":true,"count":0,"inhibited":false}' '{"dnd":"supported"}'
check_notification 'Mako DND on' '.alt == "dnd-none" and .text == "" and (.tooltip | contains("Do not disturb: on"))'
notification_state mako available '{"running":true,"dnd":false,"count":1,"inhibited":false}' '{"dnd":"supported"}'
check_notification 'Mako state change is observed' '.alt == "notification" and .text == "1"'
notification_state dunst available '{"running":true,"dnd":true,"count":3,"inhibited":true}' '{"dnd":"supported"}'
check_notification 'Dunst DND and inhibition' '.alt == "dnd-inhibited-notification" and .text == "3" and (.tooltip | contains("inhibited"))'
notification_state fnott available '{"running":true,"dnd":null,"count":null,"inhibited":null}' '{"dnd":"unsupported","history":"unsupported"}'
check_notification 'Fnott unsupported DND and unknown count stay unknown' '.alt == "none" and .text == "" and (.class | index("dnd-unsupported") and index("count-unknown")) and (.tooltip | contains("not supported by Fnott") and contains("Waiting: unknown"))'
notification_state mako available '{"running":false,"dnd":null,"count":null,"inhibited":null}' '{"dnd":"supported"}'
check_notification 'stopped daemon' '.alt == "stopped" and (.tooltip | contains("Mako is not running"))'
notification_state dunst missing-dependency 'null' 'null' 'dunstctl is not installed'
check_notification 'missing dependency is unavailable, not success' '.alt == "unavailable" and (.class | index("missing-dependency")) and (.tooltip | contains("not installed"))'
notification_state mako unavailable 'null' 'null' 'no session bus <b>'
check_notification 'unavailable session with sanitized reason' '.alt == "unavailable" and (.tooltip | contains("<") | not)'
notification_state '' disabled 'null' 'null'
check_notification 'disabled role' '.alt == "disabled"'
rm -f -- "$STATUS_DIR/notifications.json"
check_notification 'unreadable status is an error, not an empty bell' '.alt == "error" and (.class | index("error"))'
plain=$(notify_once --format plain)
[[ $plain == *err ]] || fail "plain error label: $plain"
notification_state mako available '{"running":true,"dnd":true,"count":4,"inhibited":false}' '{"dnd":"supported"}'
[[ $(notify_once --format plain) == $' 4' ]] || fail 'plain DND label with count'
printf 'ok - notification status shows DND, count, inhibition, stopped, unavailable and error states from observed status\n'

# Streaming: SwayNC streams natively while running; when the stream ends the adapter falls
# back to the observed status instead of freezing on the last value.
cat > "$fixture/bin/swaync-client" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$SWAYNC_ARGV"
printf '{"text":"7","alt":"notification","tooltip":"7 Notifications","class":["notification"]}\n'
STUB
chmod +x "$fixture/bin/swaync-client"
export SWAYNC_ARGV="$fixture/swaync-argv"
notification_state swaync available '{"running":true,"dnd":false,"count":7,"inhibited":false}' '{"dnd":"supported"}'
PATH="$fixture/bin:$PATH" HSS_BAR_STATUS_INTERVAL=1 "$waybar_dir/scripts/notification_status.sh" > "$fixture/stream" &
stream_pid=$!
for _ in $(seq 1 50); do
  [[ $(wc -l < "$fixture/stream") -ge 2 ]] && break
  sleep 0.1
done
kill "$stream_pid" 2>/dev/null || true
wait "$stream_pid" 2>/dev/null || true
mapfile -t lines < "$fixture/stream"
[[ ${#lines[@]} -ge 2 ]] || fail 'stream produced native and fallback lines'
[[ ${lines[0]} == '{"text":"7","alt":"notification","tooltip":"7 Notifications","class":["notification"]}' ]] || fail 'first line is the native SwayNC stream'
jq -e '.alt == "notification" and .class == ["notification","swaync"]' <<<"${lines[1]}" >/dev/null || fail 'fallback line comes from observed status'
mapfile -d '' argv < "$SWAYNC_ARGV"
[[ ${argv[*]} == -swb ]] || fail 'SwayNC stream uses swaync-client -swb'
printf 'ok - SwayNC streams natively and falls back to observed status when the stream ends\n'

# 6. Theme control status.
theme_state() {
  jq -cn --arg availability "$1" --argjson state "$2" \
    '{schema: 1, domain: "theme", provider: "hss-theme", availability: $availability, observed_at: "x", state: $state, capabilities: null, error: null}' \
    > "$STATUS_DIR/theme.json"
}
theme_state available '{"variant":"dark","batch":"complete","partial_units":[]}'
"$waybar_dir/scripts/theme_status.sh" | jq -e '.alt == "dark" and .class == ["dark"] and (.tooltip | contains("Mocha") and contains("switch to light"))' >/dev/null || fail 'dark theme status'
theme_state available '{"variant":"light","batch":"partial","partial_units":["waybar","kitty"]}'
"$waybar_dir/scripts/theme_status.sh" | jq -e '.alt == "light" and (.class | index("partial")) and (.tooltip | contains("waybar, kitty") and contains("switch to dark"))' >/dev/null || fail 'partial light theme status'
theme_state unavailable '{"variant":null,"default_variant":"dark","batch":null}'
"$waybar_dir/scripts/theme_status.sh" | jq -e '.alt == "unavailable" and (.tooltip | contains("apply the light theme"))' >/dev/null || fail 'unapplied theme status'
rm -f -- "$STATUS_DIR/theme.json"
"$waybar_dir/scripts/theme_status.sh" | jq -e '.alt == "error"' >/dev/null || fail 'unreadable theme status'
theme_state available '{"variant":"light","batch":"complete","partial_units":[]}'
[[ $("$waybar_dir/scripts/theme_status.sh" --format plain) == $'' ]] || fail 'plain light glyph'
printf 'ok - theme control shows the current variant, partial application and unapplied state\n'

# 7. Absent hardware stays visible as unavailable; unreadable devices are denied.
sys="$fixture/sys" dev="$fixture/dev"
mkdir -p "$sys/class/backlight" "$sys/class/power_supply" "$sys/class/input" "$dev/input"
hw() {
  HSS_SYSFS_ROOT=$sys HSS_DEV_ROOT=$dev "$waybar_dir/scripts/hardware_state.sh" "$@"
}
hw --absent backlight || fail 'no backlight is absent'
hw backlight | jq -e '.alt == "unavailable" and .class == ["unavailable","backlight"] and (.text | endswith("n/a"))' >/dev/null || fail 'backlight unavailable JSON'
mkdir -p "$sys/class/backlight/intel_backlight"
printf '50\n' > "$sys/class/backlight/intel_backlight/brightness"
printf '100\n' > "$sys/class/backlight/intel_backlight/max_brightness"
! hw --absent backlight || fail 'present backlight hides the companion'
mkdir -p "$sys/class/power_supply/hidpp_battery_0"
printf 'Battery\n' > "$sys/class/power_supply/hidpp_battery_0/type"
printf 'Device\n' > "$sys/class/power_supply/hidpp_battery_0/scope"
hw --absent battery || fail 'a mouse battery is not a system battery'
mkdir -p "$sys/class/power_supply/BAT0"
printf 'Battery\n' > "$sys/class/power_supply/BAT0/type"
! hw --absent battery || fail 'system battery is present'
mkdir -p "$sys/class/input/event3/device/capabilities"
printf '0\n' > "$sys/class/input/event3/device/capabilities/led"
[[ $(hw keyboard | jq -r .alt) == unavailable ]] || fail 'no LED keyboard is unavailable'
mkdir -p "$sys/class/input/event4/device/capabilities"
printf '7\n' > "$sys/class/input/event4/device/capabilities/led"
: > "$dev/input/event4"
chmod 000 "$dev/input/event4"
if [[ -r $dev/input/event4 ]]; then
  printf 'ok - (skipped denied keyboard case: the test runs with read access to mode-000 files)\n'
else
  [[ $(hw keyboard | jq -r .alt) == denied ]] || fail 'unreadable keyboard is denied'
  hw keyboard | jq -e '.tooltip | contains("input group")' >/dev/null || fail 'denied explanation'
fi
chmod 600 "$dev/input/event4"
! hw --absent keyboard || fail 'readable LED keyboard is present'
if hw bogus >/dev/null 2>&1; then fail 'unknown hardware kind is rejected'; fi
printf 'ok - absent backlight/battery and unreadable lock-key devices are reported, present hardware hides the companion\n'

# 7b. Labels for bars without native device widgets come from observed status and sysfs.
bar_status() {
  HSS_SYSFS_ROOT=$sys "$waybar_dir/scripts/bar_status.sh" "$@"
}
domain_state() {
  jq -cn --arg domain "$1" --arg availability "$2" --argjson state "$3" --argjson capabilities "${4:-null}" \
    '{schema: 1, domain: $domain, provider: "x", availability: $availability, observed_at: "x", state: $state,
      capabilities: $capabilities, error: null}' > "$STATUS_DIR/$1.json"
}
domain_state audio available '{"server":"pipewire","output_volume":55,"output_muted":false,"input_volume":40,"input_muted":true,"streams_supported":false}'
[[ $(bar_status audio) == $' 55% ' ]] || fail "audio label: $(bar_status audio)"
bar_status --format nwg audio | sed -n 3,9p | grep -Fq 'Application volumes: not supported' || fail 'ALSA-only audio is explained'
domain_state network available '{"backend":"networkmanager","running":true,"connectivity":"portal","primary_type":"wifi","primary_state":"connected","wifi_radio":"enabled","signal":64}'
[[ $(bar_status network) == $' 64% !' ]] || fail "network label: $(bar_status network)"
domain_state network available '{"backend":"networkmanager","running":true,"connectivity":"none","primary_type":"none","primary_state":"disconnected","wifi_radio":"disabled","signal":null}'
[[ $(bar_status network) == $' off' ]] || fail 'Wi-Fi radio off'
domain_state bluetooth available '{"controller":"absent","powered":null,"blocked":null,"connected_devices":null}'
[[ $(bar_status bluetooth) == $' n/a' ]] || fail 'no Bluetooth controller is unavailable'
domain_state bluetooth available '{"controller":"present","powered":false,"blocked":false,"connected_devices":0}'
[[ $(bar_status bluetooth) == $' off' ]] || fail 'Bluetooth off is distinct from absent'
domain_state bluetooth available '{"controller":"present","powered":true,"blocked":false,"connected_devices":2}'
[[ $(bar_status bluetooth) == $' 2' ]] || fail 'connected device count'
domain_state audio missing-dependency 'null'
[[ $(bar_status audio) == $' n/a' ]] || fail 'missing audio provider'
rm -f -- "$STATUS_DIR/network.json"
[[ $(bar_status network) == $' n/a' ]] || fail 'unreadable network status'
[[ $(bar_status backlight) == $' 50%' ]] || fail "backlight label: $(bar_status backlight)"
printf '85\n' > "$sys/class/power_supply/BAT0/capacity"
printf 'Discharging\n' > "$sys/class/power_supply/BAT0/status"
[[ $(bar_status battery) == $'85% ' ]] || fail "battery label: $(bar_status battery)"
printf '12\n' > "$sys/class/power_supply/BAT0/capacity"
[[ $(bar_status battery) == $'12%  critical' ]] || fail 'critical battery is marked'
mkdir -p "$sys/class/leds/input3::numlock"
printf '1\n' > "$sys/class/leds/input3::numlock/brightness"
[[ $(bar_status locks) == $' Num' ]] || fail 'Num Lock on'
printf '0\n' > "$sys/class/leds/input3::numlock/brightness"
[[ $(bar_status locks) == $' Num' ]] || fail 'Num Lock off'
[[ $(HSS_BAR_TIMEZONE=UTC bar_status clock) == "$(TZ=UTC date '+%a %d %b %Y | %H:%M')" ]] || fail 'clock honors the bar time zone'
domain_state bluetooth available '{"controller":"present","powered":true,"blocked":false,"connected_devices":0}'
mapfile -t nwg < <(bar_status --format nwg bluetooth)
[[ ${nwg[0]} == '' && ${nwg[1]} == $'' && ${nwg[2]} == 'Bluetooth: on' ]] || fail 'nwg-panel executor lines: icon, label, tooltip'
printf '{"text":"<b>9","tooltip":"a & b","class":"critical"}\n' > "$fixture/temp.json"
mkdir -p "$fixture/wscripts"
printf '#!/usr/bin/env bash\ncat %q\n' "$fixture/temp.json" > "$fixture/wscripts/temperature_status.sh"
chmod +x "$fixture/wscripts/temperature_status.sh"
mapfile -t nwg < <(HSS_WAYBAR_SCRIPTS="$fixture/wscripts" bar_status --format nwg temperature)
[[ ${nwg[1]} == '&lt;b&gt;9 !' && ${nwg[2]} == 'a &amp; b' ]] || fail "executor output is Pango-escaped: ${nwg[*]}"
bar_status bogus >/dev/null 2>&1 && fail 'unknown label kind is rejected'
printf 'ok - bar labels translate observed audio/network/Bluetooth status and sysfs state, with escaped executor output\n'

# 8. Existing configurations migrate to the semantic gestures; custom values survive.
# The v0.7.0 stock configuration, before the semantic gestures.
cp "$repo_root/tests/fixtures/harmonization/d01-waybar-config-v0.7.0.jsonc" "$fixture/old.jsonc"
PYTHONDONTWRITEBYTECODE=1 python3 - "$repo_root" "$fixture/old.jsonc" <<'PY'
import importlib.util, json, sys
from pathlib import Path
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('updater', root / 'scripts/lib/update-waybar-roles.py')
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)
parse = lambda text: json.loads(updater.json_text(text))
shipped = (root / 'dotfiles/.config/waybar/config.jsonc').read_text()
assert updater.update_document(shipped) == shipped, 'shipped config is already current'
migrated = updater.update_document(Path(sys.argv[2]).read_text())
assert updater.update_document(migrated) == migrated, 'migration is idempotent'
assert parse(migrated) == parse(shipped), 'stock configuration migrates to the shipped semantics'
taskbar = parse(updater.update_document('{"modules-left": ["wlr/taskbar"], "wlr/taskbar": {"icon-theme": "Papirus"}}'))
assert taskbar['wlr/taskbar']['icon-theme'] == 'Papirus', 'a user-chosen taskbar icon theme is kept'

custom = '''{ // my bar
  "modules-left": ["clock"],
  "modules-right": ["bluetooth", /* keep */ "custom/notification", "battery",],
  "bluetooth": {"on-click-right": "my-bt-script"},
  "custom/power": {"menu-actions": {"shutdown": "my-shutdown", "reboot": "~/.config/waybar/scripts/power_action.sh reboot"}},
  "custom/notification": {"interval": 5, "format-icons": {"none": "N", "stopped": "S"}},
  "pulseaudio": {"tooltip-format": "mine"},
}'''
result = updater.update_document(custom)
data = parse(result)
assert '// my bar' in result and '/* keep */' in result
assert data['bluetooth']['on-click-right'] == 'my-bt-script'
assert data['bluetooth']['on-click'].endswith('action_exec.sh bluetooth.open')
assert data['custom/power']['menu-actions']['shutdown'] == 'my-shutdown'
assert data['custom/power']['menu-actions']['reboot'].endswith('action_exec.sh session.reboot')
assert 'interval' not in data['custom/notification']
assert data['custom/notification']['format-icons']['stopped'] == 'S'
assert data['custom/notification']['format-icons']['unavailable'].endswith('n/a')
assert data['pulseaudio']['tooltip-format'] == 'mine'
assert data['modules-right'] == ['bluetooth', 'custom/notification', 'custom/theme', 'battery', 'custom/battery-unavailable']
assert data['custom/theme']['on-click'].endswith('action_exec.sh theme.toggle')
assert updater.update_document(result) == result
# Layouts without the anchors get no new modules.
bare = '{"modules-right": ["clock"], "clock": {}}'
assert parse(updater.update_document(bare))['modules-right'] == ['clock']
assert 'custom/theme' not in parse(updater.update_document(bare))
PY
printf 'ok - stock configurations migrate to semantic gestures and the theme control; custom gestures, labels and comments survive\n'

# 9. Alternative bars: every baseline operation is either wired to the same invocation as
# Waybar or presented as an explicitly unavailable control whose tooltip explains why.
PYTHONDONTWRITEBYTECODE=1 python3 - "$repo_root" "$fixture/gestures.tsv" <<'PY'
import json, sys, tomllib
from pathlib import Path
root = Path(sys.argv[1])
waybar = {}
for line in Path(sys.argv[2]).read_text().splitlines():
    module, gesture, command = line.split('\t')
    waybar[(module, gesture)] = command

def normalize(command):
    # Ironbar marks shell commands with "!" and closes its popup before running an entry.
    command = command.removeprefix('!').removeprefix('ironbar bar main hide-popup; ')
    command = command.replace('{HOME}', '$HOME').replace('~/.config', '$HOME/.config')
    if command.startswith("bash -lc '") and command.endswith("'"):
        command = command[len("bash -lc '"):-1]
    return ' '.join(command.split())

baseline = {
    'power.screen': ('custom/power', 'on-click'),
    **{f'power.{name}': ('custom/power', f'menu:{name}') for name in ('suspend', 'hibernate', 'shutdown', 'reboot', 'logout')},
    'menu.toggle': ('custom/menu', 'on-click'),
    **{f'menu.{name}': ('custom/menu', f'menu:{name}') for name in ('drun', 'keybinds', 'open_keybinds', 'snapshot')},
    'audio.streams': ('pulseaudio', 'on-click'),
    'audio.hardware': ('pulseaudio', 'on-click-right'),
    **{f'backlight.{level}': ('backlight', f'menu:set-to-{level}') for level in (100, 75, 50, 25, 10)},
    'temperature.monitor': ('custom/temperature', 'on-click'),
    'network.connect': ('network', 'on-click'),
    'network.edit': ('network', 'on-click-right'),
    'bluetooth.open': ('bluetooth', 'on-click'),
    'bluetooth.radio': ('bluetooth', 'on-click-right'),
    'updates.confirm': ('custom/updates', 'on-click'),
    **{f'updates.{name}': ('custom/updates', f'menu:{name}') for name in
       ('check', 'update', 'update-no-aur', 'firmware', 'review-pacnew', 'clean-cache', 'show-log')},
    'notifications.center': ('custom/notification', 'on-click'),
    'notifications.dnd': ('custom/notification', 'on-click-right'),
    'theme.toggle': ('custom/theme', 'on-click'),
    'clock.calendar': ('clock', 'on-click'),
}
expected = {op: normalize(waybar[key]) for op, key in baseline.items()}

def check(bar, wired, limited, explanations):
    covered = set(wired) | set(limited)
    assert covered == set(expected), (bar, sorted(set(expected) ^ covered))
    assert not set(wired) & set(limited), (bar, set(wired) & set(limited))
    for op, command in wired.items():
        assert normalize(command) == expected[op], (bar, op, command, expected[op])
    for op, holder in limited.items():
        text = explanations.get(holder, '')
        assert 'not available' in text, (bar, op, holder, text)

# nwg-panel: buttons run a command on left click; executors bind clicks and scrolls.
panel = json.loads((root / 'dotfiles/.config/nwg-panel/bar').read_text())[0]
assert panel['output'] == 'All', 'nwg-panel bar on every output'
active = panel['modules-left'] + panel['modules-center'] + panel['modules-right']
for name in active:
    assert isinstance(panel[name], dict), name
def cmd(module, key):
    assert module in active, module
    return panel[module][key]
wired = {
    'power.screen': cmd('button-power', 'command'),
    'menu.toggle': cmd('button-menu', 'command'),
    'audio.streams': cmd('executor-audio', 'on-left-click'),
    'audio.hardware': cmd('executor-audio', 'on-right-click'),
    'temperature.monitor': cmd('executor-temperature', 'on-left-click'),
    'network.connect': cmd('executor-network', 'on-left-click'),
    'network.edit': cmd('executor-network', 'on-right-click'),
    'bluetooth.open': cmd('executor-bluetooth', 'on-left-click'),
    'bluetooth.radio': cmd('executor-bluetooth', 'on-right-click'),
    'updates.confirm': cmd('button-updates', 'command'),
    'notifications.center': cmd('executor-notifications', 'on-left-click'),
    'notifications.dnd': cmd('executor-notifications', 'on-right-click'),
    'theme.toggle': cmd('executor-theme', 'on-left-click'),
    'clock.calendar': cmd('executor-clock', 'on-left-click'),
}
limited = {op: holder for prefix, holder in (('power.', 'button-power'), ('menu.', 'button-menu'),
                                             ('backlight.', 'executor-backlight'), ('updates.', 'button-updates'))
           for op in expected if op.startswith(prefix) and op not in wired}
explanations = {name: panel[name].get('tooltip', panel[name].get('tooltip-text', '')) for name in active}
check('nwg-panel', wired, limited, explanations)
for name in ('hyprland-workspaces', 'hyprland-submap', 'tray'):
    assert name in panel['modules-left'], name
assert panel['executor-backlight']['on-scroll-up'].endswith('backlight.sh +5')
assert panel['executor-backlight']['on-scroll-down'].endswith('backlight.sh -5')
for name in active:
    if name.startswith('executor-'):
        script = panel[name]['script'].split()
        assert script[0].startswith('{HOME}/.config/waybar/scripts/'), (name, script)
        assert (root / 'dotfiles/.config/waybar/scripts' / Path(script[0]).name).is_file(), script[0]

# Ironbar: widget commands come from on_click_* keys; popup buttons carry on_click.
ironbar = tomllib.loads((root / 'dotfiles/.config/ironbar/config.toml').read_text())
found = []
explanations = {}
def walk(node, owner):
    if isinstance(node, dict):
        name = node.get('name', owner)
        for key in ('on_click_left', 'on_click_right', 'on_click_middle', 'on_scroll_up', 'on_scroll_down', 'on_click'):
            if isinstance(node.get(key), str) and not node[key].startswith('popup:'):
                found.append((name, key, node[key]))
        if 'tooltip' in node and isinstance(node['tooltip'], str):
            explanations[name] = node['tooltip']
        for value in node.values():
            walk(value, name)
    elif isinstance(node, list):
        for value in node:
            walk(value, owner)
walk(ironbar, 'root')
wired, limited = {}, {}
for op in expected:
    located = [command for _, _, command in found if normalize(command) == expected[op]]
    if located:
        wired[op] = located[0]
    else:
        holders = [name for name, text in explanations.items() if 'not available' in text and op.split('.')[0] in name]
        limited[op] = holders[0] if holders else ''
check('ironbar', wired, limited, explanations)
assert not limited, ('ironbar', sorted(limited))
popups = {module['name']: module for section in ('start', 'end') for module in ironbar.get(section, [])
          if module.get('type') == 'custom' and 'popup' in module}
for name in ('power', 'menu', 'backlight', 'updates'):
    button = popups[name]['bar'][0]
    assert button['on_click_right'] == f'ironbar bar main toggle-popup {name}', name
    for entry in popups[name]['popup'][0]['widgets']:
        assert entry['on_click'].startswith('!ironbar bar main hide-popup; '), (name, entry)
types = [module['type'] for section in ('start', 'end') for module in ironbar.get(section, [])]
for native in ('tray', 'workspaces', 'bindmode', 'volume', 'battery', 'network_manager', 'bluetooth', 'clock'):
    assert native in types, native
assert 'notifications' not in types, 'native SwayNC-only notifications module would D-Bus-activate SwayNC'
assert 'monitors' not in ironbar, 'Ironbar bars appear on every output'
PY
printf 'ok - Ironbar and nwg-panel bars wire every baseline operation to the Waybar invocation or explain why it is not available\n'

# 10. Ledger and coverage fragments agree with each other, the catalog and the theme units.
PYTHONDONTWRITEBYTECODE=1 python3 - "$repo_root" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
ledger = json.loads((root / 'capabilities.d/d01-panels.json').read_text())
coverage = json.loads((root / 'tests/fixtures/harmonization/coverage/d01-panels.json').read_text())
catalog = json.loads((root / 'packages.json').read_text())
units = {unit['id'] for unit in json.loads((root / 'dotfiles/.config/hypr/theme/units.d/10-d01-panels.json').read_text())['units']}
assert ledger['owner'] == coverage['owner'] == 'D01'
expected_options = {f'{role}/{option["package"]}' for role in ('bar', 'dock') for option in catalog['roles'][role]['options']}
assert set(ledger['options']) == expected_options, sorted(set(ledger['options']) ^ expected_options)
assert set(ledger['none_states']) == {'dock'} and catalog['roles']['dock']['required'] is False
assert all(re.fullmatch(r'E-D01-\d{3}', key) for key in ledger['evidence'])
kinds = {'documentation', 'static', 'argv', 'modeled-effect', 'real-effect', 'visual'}
assert all(record['kind'] in kinds for record in ledger['evidence'].values())
for cid, capability in ledger['capabilities'].items():
    assert re.fullmatch(r'[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+', cid) and capability['domain'] == cid.split('.')[0], cid
for name, option in ledger['options'].items():
    supports = {entry['support'] for entry in option['capabilities'].values()}
    assert option['support'] == ('full' if supports == {'supported'} else 'limited'), (name, supports)
    assert option['support'] == 'full' or option['limitations'], name
    for cid, entry in option['capabilities'].items():
        assert cid in ledger['capabilities'], (name, cid)
        assert entry['evidence'] and all(e in ledger['evidence'] for e in entry['evidence']), (name, cid)
        assert entry['support'] == 'supported' or entry['note'], (name, cid)
    assert set(option['theme']['units']) <= units, name
ids = [case['id'] for case in coverage['cases']]
assert len(ids) == len(set(ids)) and all(i.startswith('D01-') for i in ids)
covered = {case['option'] for case in coverage['cases']}
assert expected_options | {'dock/none'} <= covered, sorted((expected_options | {'dock/none'}) - covered)
for case in coverage['cases']:
    assert case['capability'] is None or case['capability'] in ledger['capabilities'], case['id']
    assert case['evidence_required'] in kinds - {'documentation'}, case['id']
    assert case['result'] == 'not-run' and case['vm_check'], case['id']
    for test in case['tests']:
        assert test['state'] == 'delivered' and (root / test['path']).is_file(), (case['id'], test)
PY
printf 'ok - D01 ledger and coverage fragments cover every bar/dock option and None with resolvable evidence\n'
