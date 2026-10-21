#!/usr/bin/env bash
set -euo pipefail

# D06.4 calendars: launch/focus routing for all five calendars, first-use behaviour without
# accounts, and theme units that never touch calendar data. Real calcurse and khal checks
# run only where those binaries exist (the research userland); CI uses the routing checks.
unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/shell/theme_units_testlib.sh
source "$repo_root/tests/shell/theme_units_testlib.sh"
base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

real_calcurse=$(command -v calcurse || true)
real_khal=$(command -v khal || true)

export HOME="$base/home"
scripts="$HOME/.config/hypr/scripts"
mkdir -p "$scripts" "$HOME/.config/waybar/scripts" "$base/bin"
for script in role_exec.sh term_exec.sh role_window.sh float_calendar.sh; do
  cp "$repo_root/dotfiles/.config/hypr/scripts/$script" "$scripts/"
done
cat > "$base/bin/argv-double" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "${0##*/}" "$@" > "$ARGV_LOG"
STUB
chmod +x "$base/bin/argv-double"
cp "$base/bin/argv-double" "$HOME/.config/waybar/scripts/launch_qt_gui.sh"
cp "$base/bin/argv-double" "$scripts/window_present.sh"
for name in kitty merkuro-calendar gnome-calendar korganizer calcurse ikhal; do
  ln -s "$base/bin/argv-double" "$base/bin/$name"
done
export PATH="$base/bin:$PATH" ARGV_LOG="$base/argv.log" HSS_ROLES_FILE="$base/roles.json"

assert_argv() {
  local label=$1
  shift
  local -a actual=()
  mapfile -d '' actual < "$ARGV_LOG"
  [[ ${#actual[@]} == "$#" ]] || fail "$label: expected $*, got ${actual[*]}"
  local index=0 expected
  for expected in "$@"; do
    [[ ${actual[$index]} == "$expected" ]] || fail "$label: argument $index is '${actual[$index]}', expected '$expected'"
    index=$((index + 1))
  done
}

# GUI calendars keep the native-class focus/float helper at 70%; terminal calendars use
# the selected terminal with the stable hss-calendar identity.
declare -A gui_class=(
  [merkuro]='^org\.kde\.merkuro\.calendar$'
  [gnome-calendar]='^org\.gnome\.Calendar$'
  [korganizer]='^(org\.kde\.)?korganizer$'
)
declare -A executable=([merkuro]=merkuro-calendar [gnome-calendar]=gnome-calendar [korganizer]=korganizer [calcurse]=calcurse [khal]=ikhal)
for package in merkuro gnome-calendar korganizer calcurse khal; do
  make_member_roles "$HSS_ROLES_FILE" "calendar=$package" terminal=kitty
  for entry in "$scripts/float_calendar.sh" "$scripts/role_window.sh calendar"; do
    rm -f "$ARGV_LOG"
    read -r -a command <<< "$entry"
    "${command[@]}"
    if [[ -n ${gui_class[$package]+x} ]]; then
      assert_argv "$package via $entry" window_present.sh "${gui_class[$package]}" 70% 70% calendar -- "${executable[$package]}"
    else
      assert_argv "$package via $entry" kitty --class hss-calendar --title calendar -e "${executable[$package]}"
    fi
  done
done
printf 'ok - GUI calendars keep class-based focus/float and terminal calendars open in the selected terminal\n'

# Theme units only write calendar configuration, never calendar data.
fragment="$repo_root/dotfiles/.config/hypr/theme/units.d/60-d06-applications.json"
[[ $(jq -r '[.units[] | select(.id == "calcurse" or .id == "khal") | .outputs[].target] | join(" ")' "$fragment") == 'config:calcurse/conf config:khal/config' ]] \
  || fail "calendar units target only configuration files"
home="$base/theme-home"
new_theme_home "$home"
mkdir -p "$home/.local/share/calcurse"
printf '10/21/2026 @ 09:00 -> 10/21/2026 @ 10:00|Synthetic standup\n' > "$home/.local/share/calcurse/apts"
before=$(sha256sum < "$home/.local/share/calcurse/apts")
make_member_roles "$base/calendar-roles.json" calendar=calcurse
theme_plan light "$base/calendar-roles.json" "$home" "$base/plan" --adopt
theme_commit "$base/plan"
[[ $(sha256sum < "$home/.local/share/calcurse/apts") == "$before" ]] || fail "calendar data changed"
make_member_roles "$base/khal-roles.json" calendar=khal
theme_plan light "$base/khal-roles.json" "$home" "$base/plan-khal" --adopt
[[ $(theme_unit_status "$base/plan-khal" khal) == not-adopted && ! -e $home/.config/khal/config ]] \
  || fail "khal configuration is never created by the theme"
printf 'ok - calendar theme units never create khal configuration or touch calendar data\n'

# Real first use, where the applications exist.
if [[ -n $real_calcurse ]]; then
  cal_home="$base/calcurse-home"
  mkdir -p "$cal_home"
  printf 'BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nDTSTART:20261021T090000\nDTEND:20261021T100000\nSUMMARY:Synthetic standup\nEND:VEVENT\nEND:VCALENDAR\n' > "$base/event.ics"
  HOME="$cal_home" XDG_CONFIG_HOME="$cal_home/.config" XDG_DATA_HOME="$cal_home/.local/share" "$real_calcurse" -q -i "$base/event.ics" >/dev/null
  HOME="$cal_home" XDG_CONFIG_HOME="$cal_home/.config" XDG_DATA_HOME="$cal_home/.local/share" "$real_calcurse" -Q --from 10/21/2026 --days 1 | grep -Fq 'Synthetic standup' \
    || fail "calcurse creates and lists a local event without accounts"
  printf 'ok - calcurse imports and lists a local synthetic event in a fresh profile\n'
else
  printf 'ok - calcurse not installed here; real first-use evidence is recorded in the capability ledger (skipped)\n'
fi
if [[ -n $real_khal ]]; then
  khal_home="$base/khal-home"
  mkdir -p "$khal_home"
  status=0
  HOME="$khal_home" XDG_CONFIG_HOME="$khal_home/.config" XDG_DATA_HOME="$khal_home/.local/share" "$real_khal" list >/dev/null 2>&1 || status=$?
  [[ $status != 0 ]] || fail "khal without configuration is expected to need 'khal configure'"
  printf 'ok - khal without configuration needs its native khal configure step (limited first use)\n'
else
  printf 'ok - khal not installed here; first-use limitation evidence is recorded in the capability ledger (skipped)\n'
fi
