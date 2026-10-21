#!/usr/bin/env bash
set -euo pipefail

# D07 session provider and auxiliary helpers: confirmations, current-session logout,
# verified hibernate, managed authentication ownership, power-screen layout, compatibility
# entry points, autostart migration and Notes path containment.

# shellcheck source=tests/shell/devices_session_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/devices_session_testlib.sh"

base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT
dt_setup "$base"
scripts="$XDG_CONFIG_HOME/hypr/scripts"
export WAYLAND_DISPLAY=wayland-test
dt_roles

power_calls() {
    cat -- "$DT_STATE/power.log" 2>/dev/null || true
}

# ---------------------------------------------------------------- confirmations
for pair in shutdown:poweroff reboot:reboot; do
    action=${pair%%:*} verb=${pair#*:}
    : > "$DT_STATE/power.log"
    for answer in cancel fail; do
        dt_state menu "$answer"
        dt_action "session.$action"
        if [[ $answer == cancel ]]; then dt_expect 3 cancelled "$action cancelled"; else dt_expect 1 failed "$action chooser failure"; fi
        [[ -z $(power_calls) ]] || dt_fail "$action ran after $answer"
    done
    dt_assert_argv menu_choose.sh "$action confirmation request" menu_choose.sh --prompt "$(
        [[ $action == shutdown ]] && printf 'Shut down the computer?' || printf 'Restart the computer?')" --confirm
    dt_state menu yes
    dt_action "session.$action"
    dt_expect 0 accepted "$action confirmed"
    [[ $(power_calls) == "$verb" ]] || dt_fail "$action did not request $verb once: $(power_calls)"
    : > "$DT_STATE/power.log"
    rm -f "$DT_STATE/count/menu_choose.sh"
    dt_state menu cancel
    dt_action "session.$action" --confirmed
    dt_expect 0 accepted "$action --confirmed"
    [[ $(dt_calls menu_choose.sh) == 0 && $(power_calls) == "$verb" ]] || dt_fail "$action --confirmed asked again or did not run"
    dt_action "session.$action" --force
    dt_expect 2 usage "$action unknown flag"
done
mv "$scripts/menu_choose.sh" "$scripts/menu_choose.sh.off"
: > "$DT_STATE/power.log"
dt_action session.shutdown
dt_expect 6 missing-dependency 'no chooser means no shutdown'
[[ -z $(power_calls) ]] || dt_fail 'shutdown ran without a confirmation menu'
mv "$scripts/menu_choose.sh.off" "$scripts/menu_choose.sh"
dt_state power_mode denied
dt_action session.reboot --confirmed
dt_expect 9 denied 'logind denial'
dt_state power_mode ok
dt_ok 'reboot/shutdown: cancel, chooser failure and missing chooser never run the command; Yes or --confirmed run it once'

# ---------------------------------------------------------------- logout
: > "$DT_STATE/hyprctl.log"
rm -f "$DT_STATE/count/loginctl" "$DT_STATE/count/menu_choose.sh"
dt_state menu yes
dt_action session.logout
dt_expect 7 unavailable 'logout without session identity'
[[ $(dt_calls menu_choose.sh) == 0 && $(dt_calls loginctl) == 0 && ! -s $DT_STATE/hyprctl.log ]] \
    || dt_fail 'logout without identity asked, ran loginctl or hyprctl'
export XDG_SESSION_ID='../x y'
dt_action session.logout
dt_expect 7 unavailable 'malformed session ID is not used'
[[ $(dt_calls loginctl) == 0 ]] || dt_fail 'malformed session ID reached loginctl'
export XDG_SESSION_ID=c7
dt_state menu cancel
dt_action session.logout
dt_expect 3 cancelled 'logout cancelled'
[[ $(dt_calls loginctl) == 0 ]] || dt_fail 'cancelled logout ended the session'
dt_state menu yes
dt_action session.logout
dt_expect 0 accepted 'logout through logind'
dt_assert_argv loginctl 'current session only' loginctl terminate-session c7
export HYPRLAND_INSTANCE_SIGNATURE=test-instance
rm -f "$DT_STATE/count/loginctl"
dt_action session.logout
dt_expect 0 accepted 'logout inside Hyprland'
dt_assert_argv hyprctl 'Hyprland exit through the Lua dispatcher' hyprctl dispatch 'hl.dsp.exit()'
[[ $(dt_calls loginctl) == 0 ]] || dt_fail 'loginctl used although Hyprland accepted the exit'
dt_state hyprctl_mode legacy
dt_action session.logout
dt_expect 0 accepted 'legacy hyprlang dispatcher'
dt_assert_argv hyprctl 'legacy exit dispatcher' hyprctl dispatch exit
dt_state hyprctl_mode broken
dt_action session.logout
dt_expect 0 accepted 'Hyprland refused, logind ends the known session'
dt_assert_argv loginctl 'fallback stays on the current session' loginctl terminate-session c7
unset XDG_SESSION_ID
rm -f "$DT_STATE/count/loginctl"
dt_action session.logout
dt_expect 1 failed 'Hyprland refused and no session ID'
[[ $(dt_calls loginctl) == 0 ]] || dt_fail 'loginctl used without a session ID'
dt_state hyprctl_mode lua
unset HYPRLAND_INSTANCE_SIGNATURE
for file in "$scripts/providers/session.sh" "$XDG_CONFIG_HOME/waybar/scripts/power_action.sh" "$dt_repo_root/dotfiles/.config/wlogout/layout"; do
    if grep -q 'terminate-user' "$file"; then dt_fail "user-wide termination remains in $file"; fi
done
dt_ok 'logout ends only the identified current session and fails safely otherwise; no terminate-user anywhere'

# ---------------------------------------------------------------- lock, suspend, hibernate
rm -f "$DT_STATE/count/menu_choose.sh" "$DT_STATE/proc/hyprlock"
dt_action session.lock
dt_expect 0 completed 'lock is observed'
jq -e '.observed.locked == true' <<<"$DT_OUT" >/dev/null || dt_fail "lock observation: $DT_OUT"
dt_action session.lock
dt_expect 0 completed 'already locked'
[[ $(dt_calls hyprlock) == 1 && $(dt_calls menu_choose.sh) == 0 ]] || dt_fail "lock asked for confirmation or started twice: hyprlock=$(dt_calls hyprlock) menu=$(dt_calls menu_choose.sh)"
rm -f "$DT_STATE/proc/hyprlock"
dt_state hyprlock_mode fail
dt_action session.lock
dt_expect 1 failed 'hyprlock that exits is not reported as locked'
dt_state hyprlock_mode ok
unset WAYLAND_DISPLAY
dt_action session.lock
dt_expect 7 unavailable 'no display to lock'
export WAYLAND_DISPLAY=wayland-test
: > "$DT_STATE/power.log"
dt_action session.suspend
dt_expect 0 accepted 'suspend is direct'
[[ $(power_calls) == suspend && $(dt_calls menu_choose.sh) == 0 ]] || dt_fail 'suspend asked or did not run'
: > "$DT_STATE/power.log"
for value in na no fail; do
    dt_state can_hibernate "$value"
    dt_action session.hibernate
    dt_expect 5 unsupported "hibernate with CanHibernate=$value"
done
[[ -z $(power_calls) ]] || dt_fail 'hibernate ran without verified prerequisites'
dt_state can_hibernate yes
dt_action session.hibernate
dt_expect 0 accepted 'hibernate when logind can'
[[ $(power_calls) == hibernate ]] || dt_fail 'hibernate not requested'
dt_ok 'lock immediate and observed, suspend direct, hibernate only when logind reports yes'

# ---------------------------------------------------------------- authentication agent
: > "$DT_STATE/systemctl.log"
printf '/usr/lib/polkit-kde-authentication-agent-1\n' > "$DT_STATE/proc/kde-agent.cmdline"
dt_action session.auth.start
dt_expect 10 conflict 'foreign agent'
jq -e '.reason | test("polkit-kde-authentication-agent-1") and test("untouched")' <<<"$DT_OUT" >/dev/null || dt_fail "conflict reason: $DT_OUT"
grep -q 'start' "$DT_STATE/systemctl.log" && dt_fail 'hyprpolkitagent started next to a foreign agent'
[[ $(dt_calls pkill) == 0 ]] || dt_fail 'a process was signalled'
dt_status session
jq -e '.state.auth_agent == "foreign"' <<<"$DT_OUT" >/dev/null || dt_fail "status auth agent: $DT_OUT"
rm -f "$DT_STATE/proc/kde-agent.cmdline"
dt_action session.auth.start
dt_expect 0 completed 'hyprpolkitagent started'
grep -q -- '--user start hyprpolkitagent.service' "$DT_STATE/systemctl.log" || dt_fail 'unit not started'
: > "$DT_STATE/systemctl.log"
dt_action session.auth.start
dt_expect 0 completed 'already running'
grep -q 'start' "$DT_STATE/systemctl.log" && dt_fail 'running agent started again'
rm -f "$DT_STATE/units/hyprpolkitagent.service"
dt_state start_mode dies
dt_action session.auth.start
dt_expect 1 failed 'agent that does not stay active'
touch "$DT_STATE/units/hyprpolkitagent.service.missing"
dt_action session.auth.start
dt_expect 6 missing-dependency 'unit not installed'
rm -f "$DT_STATE/units/hyprpolkitagent.service.missing"
touch "$DT_STATE/user_manager_down"
dt_action session.auth.start
dt_expect 7 unavailable 'user manager unreachable'
rm -f "$DT_STATE/user_manager_down"
dt_state start_mode ok
dt_ok 'session.auth.start: foreign agent is a conflict and never touched; start is read back'

# ---------------------------------------------------------------- status
dt_state can_hibernate na
dt_state units/hyprpolkitagent.service active
dt_status session
jq -e '.availability == "available" and .state.hibernate_available == false and .state.auth_agent == "hyprpolkitagent"
    and .capabilities.hibernate == "unsupported"' <<<"$DT_OUT" >/dev/null || dt_fail "session status: $DT_OUT"
dt_state can_hibernate fail
dt_status session
jq -e '.state.hibernate_available == null and .capabilities.hibernate == "unverified"' <<<"$DT_OUT" >/dev/null || dt_fail "unknown hibernate: $DT_OUT"
dt_ok 'session status reports hibernate availability and the authentication owner'

# ---------------------------------------------------------------- compatibility entry points
power_action="$XDG_CONFIG_HOME/waybar/scripts/power_action.sh"
rm -f "$DT_STATE/count/hyprlock" "$DT_STATE/proc/hyprlock"
"$power_action" lock
[[ $(dt_calls hyprlock) == 1 ]] || dt_fail 'power_action.sh lock did not lock'
: > "$DT_STATE/power.log"
dt_state menu cancel
status=0
"$power_action" shutdown || status=$?
[[ $status == 3 && -z $(power_calls) ]] || dt_fail "power_action.sh shutdown cancel: exit $status, $(power_calls)"
dt_state menu yes
"$power_action" reboot
[[ $(power_calls) == reboot ]] || dt_fail 'power_action.sh reboot'
status=0
"$power_action" dance 2>/dev/null || status=$?
[[ $status == 2 ]] || dt_fail "unknown power action exit $status"
dt_ok 'power_action.sh keeps its six arguments and delegates to the session provider'

layout="$dt_repo_root/dotfiles/.config/wlogout/layout"
mapfile -t actions < <(sed -E 's/^(.*\})[[:space:]]*,[[:space:]]*$/\1/' "$layout" | jq -r '"\(.label) \(.action)"')
[[ ${#actions[@]} == 6 ]] || dt_fail 'wlogout layout must keep six buttons'
for entry in "${actions[@]}"; do
    label=${entry%% *} command=${entry#* }
    [[ $command == "\"\$HOME/.config/hypr/scripts/action_exec.sh\" session.$label" ]] || dt_fail "wlogout $label: $command"
done
dt_ok 'Wlogout buttons use the same session actions (and confirmations) as keys and bars'

mkdir -p "$HOME/.config/wlogout"
cp "$dt_repo_root/dotfiles/.config/wlogout/layout" "$dt_repo_root/dotfiles/.config/wlogout/style.css" "$HOME/.config/wlogout/"
dt_state can_hibernate na
rm -f "$DT_STATE/last/wlogout"
"$XDG_CONFIG_HOME/waybar/scripts/launch_power_screen.sh"
filtered="$XDG_RUNTIME_DIR/hyprland-simple-setup/wlogout-layout"
dt_assert_argv wlogout 'power screen without hibernate' wlogout --protocol layer-shell --css "$HOME/.config/wlogout/style.css" --layout "$filtered"
labels=$(sed -E 's/^(.*\})[[:space:]]*,[[:space:]]*$/\1/' "$filtered" | jq -r .label | tr '\n' ' ')
[[ $labels == 'lock logout shutdown suspend reboot ' ]] || dt_fail "filtered layout: $labels"
dt_state can_hibernate yes
"$XDG_CONFIG_HOME/waybar/scripts/launch_power_screen.sh"
dt_assert_argv wlogout 'power screen with hibernate' wlogout --protocol layer-shell --css "$HOME/.config/wlogout/style.css"
rm -f "$DT_STATE/last/wlogout"
dt_action session.power_screen
dt_expect 0 accepted 'power screen action'
dt_wait_for wlogout
dt_assert_argv wlogout 'session.power_screen' wlogout --protocol layer-shell --css "$HOME/.config/wlogout/style.css"
dt_ok 'the power screen offers hibernate only when logind reports it can'

# ---------------------------------------------------------------- autostart and idle
for file in autostart.lua autostart.conf; do
    path="$dt_repo_root/dotfiles/.config/hypr/sources_example/$file"
    if grep -q 'polkit-kde-authentication-agent-1\|systemctl --user start hyprpolkitagent' "$path"; then
        dt_fail "$file still starts an agent directly"
    fi
    [[ $(grep -c 'action_exec.sh --quiet session.auth.start' "$path") == 1 ]] || dt_fail "$file must start authentication once"
done
idle="$dt_repo_root/dotfiles/.config/hypr/hypridle.conf"
grep -Eq '^[[:space:]]*before_sleep_cmd = loginctl lock-session' "$idle" || dt_fail 'hypridle no longer locks before sleep'
grep -Eq '^[[:space:]]*lock_cmd = pidof hyprlock \|\| hyprlock' "$idle" || dt_fail 'hypridle lock command changed'
grep -Fq "after_sleep_cmd = hyprctl dispatch 'hl.dsp.dpms({action = \"on\"})'" "$idle" || dt_fail 'hypridle resume uses the legacy dispatcher'
dt_ok 'autostart starts only the managed agent; hypridle keeps lock-before-sleep with Lua dispatchers'

migration="$base/migration"
mkdir -p "$migration/home/dotfiles/.config/hypr/sources"
lua="$migration/home/dotfiles/.config/hypr/sources/autostart.lua"
conf="$migration/home/dotfiles/.config/hypr/sources/autostart.conf"
cat > "$lua" <<'EOF'
local apps = require("sources.app_variables")
hl.on("hyprland.start", function()
    hl.exec_cmd("systemctl --user start hyprpolkitagent")
    hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1")
    hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1 --my-option")
end)
EOF
cat > "$conf" <<'EOF'
exec-once = systemctl --user start hyprpolkitagent &
exec-once = /usr/lib/polkit-kde-authentication-agent-1 &
exec-once = custom-user-command
EOF
mkdir -p "$migration/home/dotfiles/.config/wlogout"
# Layout and Hypridle lines as shipped by earlier setup versions, plus one customized button.
cat > "$migration/home/dotfiles/.config/wlogout/layout" <<'EOF'
{
    "label" : "lock",
    "action" : "loginctl lock-session",
    "text" : "Hyprlock",
    "keybind" : "l"
},
{
    "label" : "logout",
    "action" : "loginctl terminate-user $USER",
    "text" : "Logout",
    "keybind" : "e"
},
{
    "label" : "reboot",
    "action" : "systemctl reboot --firmware-setup",
    "text" : "Reboot",
    "keybind" : "r"
}
EOF
printf '%s\n' 'general {' '    after_sleep_cmd = hyprctl dispatch dpms on  # to avoid having to press a key twice to turn on the display.' '}' \
    > "$migration/home/dotfiles/.config/hypr/hypridle.conf"
HOME="$migration/home" HSS_TEST_MODE=1 NON_INTERACTIVE=true XDG_STATE_HOME="$migration/state" bash -c '
    set -e
    source "$1/setup.sh"
    source "$1/scripts/lib/setup-session.sh"
    hss_begin_run "test session autostart"
    for _ in 1 2; do
        configure_session_authentication_autostart
        configure_session_wlogout_layout
        configure_session_hypridle_dispatch
    done
' bash "$dt_repo_root" > "$migration/log" 2>&1 || { cat "$migration/log" >&2; dt_fail 'autostart migration failed'; }
migrated_layout="$migration/home/dotfiles/.config/wlogout/layout"
grep -q 'terminate-user' "$migrated_layout" && dt_fail 'user-wide logout remains in the migrated layout'
labels=$(sed -E 's/^(.*\})[[:space:]]*,[[:space:]]*$/\1/' "$migrated_layout" | jq -r '"\(.label)=\(.action)"' | tr '\n' ' ')
# shellcheck disable=SC2016 # literal $HOME inside the layout actions
expected_labels='lock="$HOME/.config/hypr/scripts/action_exec.sh" session.lock logout="$HOME/.config/hypr/scripts/action_exec.sh" session.logout reboot=systemctl reboot --firmware-setup '
[[ $labels == "$expected_labels" ]] || dt_fail "migrated layout: $labels"
grep -Fq "after_sleep_cmd = hyprctl dispatch 'hl.dsp.dpms({action = \"on\"})'" "$migration/home/dotfiles/.config/hypr/hypridle.conf" \
    || dt_fail 'hypridle resume line not migrated'
dt_ok 'existing Wlogout layouts and Hypridle resume lines migrate exact shipped lines only'
grep -Fxq '    hl.exec_cmd(apps.hyprscripts .. "/action_exec.sh --quiet session.auth.start")' "$lua" || dt_fail 'Lua agent start not migrated'
grep -Fxq '    hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1")' "$lua" && dt_fail 'setup-owned KDE request remains'
grep -Fxq '    hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1 --my-option")' "$lua" || dt_fail 'user-edited line was changed'
# shellcheck disable=SC2016 # literal Hyprland variable
grep -Fxq 'exec-once = $hyprscripts/action_exec.sh --quiet session.auth.start' "$conf" || dt_fail 'hyprlang agent start not migrated'
grep -q 'polkit-kde' "$conf" && dt_fail 'hyprlang KDE request remains'
grep -Fxq 'exec-once = custom-user-command' "$conf" || dt_fail 'custom hyprlang line lost'
dt_ok 'existing autostart files migrate exact setup-owned agent lines only, idempotently'

# ---------------------------------------------------------------- Notes containment
notes_dir="$base/notes"
mkdir -p "$notes_dir" "$base/outside"
ln -s "$base/outside" "$notes_dir/escape-link"
dt_roles tui_editor=neovim
dt_recorder nvim
run_notes() {
    printf '%s\n' "$@" | INSIDE_HSS_NOTES=1 HSS_NOTES_DIR="$notes_dir" "$scripts/notes.sh" >/dev/null 2>"$base/notes.err"
}
run_notes y 'meeting'
[[ -f $notes_dir/meeting.txt ]] || dt_fail 'plain note not created'
dt_assert_argv nvim 'editor opens the new note' nvim "$notes_dir/meeting.txt"
for name in '../outside/evil' '/tmp/evil' 'escape-link/evil' '..'; do
    status=0
    run_notes y "$name" || status=$?
    [[ $status == 2 ]] || dt_fail "note name $name exit $status"
done
[[ -z $(ls -A "$base/outside") && ! -e /tmp/evil.txt ]] || dt_fail 'a note escaped the notes directory'
mkdir -p "$notes_dir/work"
run_notes y 'work/todo.md'
[[ -f $notes_dir/work/todo.md ]] || dt_fail 'subfolder note not created'
dt_ok 'Notes keep their location and editor; names cannot leave the notes directory'
