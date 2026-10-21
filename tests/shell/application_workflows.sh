#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal $ in argv fixtures.
set -euo pipefail

# D06.3 launch workflows: every browser, GUI/TUI editor and TUI file manager option keeps
# its catalog argv with literal URLs and paths; GUI editor None opens the primary TUI
# editor in the selected terminal; TUI file manager None reports unavailable.
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

export HOME="$base/home"
scripts="$HOME/.config/hypr/scripts"
mkdir -p "$scripts" "$base/bin" "$base/work"
for script in role_exec.sh term_exec.sh role_window.sh float_calendar.sh; do
  cp "$repo_root/dotfiles/.config/hypr/scripts/$script" "$scripts/"
done
cat > "$base/bin/argv-double" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "${0##*/}" "$@" > "$ARGV_LOG"
STUB
chmod +x "$base/bin/argv-double"
export PATH="$base/bin:$PATH" ARGV_LOG="$base/argv.log" HSS_ROLES_FILE="$base/roles.json"

link_double() {
  local name
  for name in "$@"; do
    ln -sf "$base/bin/argv-double" "$base/bin/$name"
  done
}

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

catalog_argv() {
  jq -r --arg role "$1" --arg package "$2" '.roles[$role].options[] | select(.package == $package) | [.executable] + .args | .[]' "$repo_root/packages.json"
}

url='https://example.invalid/a b?q=$(touch pwned)&x=`id`'
folder="$base/work/folder with spaces"
file="$base/work/notes \$(touch pwned).txt"
mkdir -p "$folder"
: > "$file"

# Browsers and GUI editors launch directly with the literal argument.
for role in browser gui_editor; do
  mapfile -t packages < <(jq -r --arg role "$role" '.roles[$role].options[].package' "$repo_root/packages.json")
  for package in "${packages[@]}"; do
    make_member_roles "$HSS_ROLES_FILE" "$role=$package"
    mapfile -t expected < <(catalog_argv "$role" "$package")
    link_double "${expected[0]}"
    argument=$url
    [[ $role == gui_editor ]] && argument=$file
    rm -f "$ARGV_LOG"
    (cd "$base/work" && "$scripts/role_exec.sh" "$role" -- "$argument")
    assert_argv "$role $package" "${expected[@]}" "$argument"
  done
done
[[ ! -e $base/work/pwned ]] || fail "an argument was evaluated"
printf 'ok - all five browsers and five GUI editors receive literal URLs and file names with their catalog flags\n'

# Terminal applications run through the selected terminal with a stable role identity.
link_double kitty foot
for role in tui_editor tui_file_manager; do
  mapfile -t packages < <(jq -r --arg role "$role" '.roles[$role].options[].package' "$repo_root/packages.json")
  for package in "${packages[@]}"; do
    make_member_roles "$HSS_ROLES_FILE" "$role=$package" terminal=kitty
    mapfile -t expected < <(catalog_argv "$role" "$package")
    argument=$file
    [[ $role == tui_file_manager ]] && argument=$folder
    rm -f "$ARGV_LOG"
    "$scripts/role_exec.sh" "$role" -- "$argument"
    assert_argv "$role $package" kitty --class "hss-$role" --title "${role//_/ }" -e "${expected[@]}" "$argument"
  done
done
printf 'ok - all four TUI editors and six TUI file managers open in the selected terminal with literal paths\n'

# GUI editor None: explicit editor actions open the primary TUI editor in the terminal.
make_member_roles "$HSS_ROLES_FILE" gui_editor= tui_editor=vim terminal=foot
rm -f "$ARGV_LOG"
"$scripts/role_exec.sh" gui_editor -- "$file"
assert_argv "GUI editor None" foot --app-id=hss-tui_editor "--title=tui editor" vim "$file"
printf 'ok - GUI editor None opens the primary TUI editor in the selected terminal\n'

# TUI file manager None is reported as unavailable and launches nothing.
make_member_roles "$HSS_ROLES_FILE" tui_file_manager= file_manager=dolphin terminal=kitty
rm -f "$ARGV_LOG"
status=0
output=$("$scripts/role_exec.sh" tui_file_manager -- "$folder" 2>&1) || status=$?
[[ $status == 1 && $output == 'Role tui_file_manager is unavailable' && ! -e $ARGV_LOG ]] || fail "TUI file manager None: $status $output"
printf 'ok - TUI file manager None reports unavailable without launching another application\n'
