#!/usr/bin/env bash
set -euo pipefail

# D01.4/D01.5: all nine bar/dock combinations through role_exec.sh, the shared nwg-panel
# process, dock None, pin seeding from the selected roles, preservation of existing pins
# and the bar-only toggle. Hermetic: stub panel programs record their argv.
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export HOME="$fixture/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$fixture/state"
mkdir -p "$HOME/.config/hypr" "$fixture/bin"
cp -a "$repo_root/dotfiles/.config/hypr/scripts" "$HOME/.config/hypr/scripts"
cp -a "$repo_root/dotfiles/.config/nwg-panel" "$HOME/.config/nwg-panel"
scripts="$HOME/.config/hypr/scripts"
export STARTS="$fixture/starts.jsonl"
cat > "$fixture/bin/panel-stub" <<'STUB'
#!/usr/bin/env bash
jq -cn --args '[$ARGS.positional[]]' -- "${0##*/}" "$@" >> "$STARTS"
STUB
chmod +x "$fixture/bin/panel-stub"
for program in waybar ironbar nwg-panel nwg-dock-hyprland; do
  ln -s "$fixture/bin/panel-stub" "$fixture/bin/$program"
done
export PATH="$fixture/bin:$PATH"

# roles.json with the bar/dock options from packages.json and the pin source roles.
write_roles() {
  local bar=$1 dock=$2 editor=${3:-} terminal=${4:-kitty}
  jq --arg bar "$bar" --arg dock "$dock" --arg editor "$editor" --arg terminal "$terminal" --arg home "$HOME" '
    def pick($role; $package): if $package == "" then null else (.roles[$role].options[] | select(.package == $package)) end;
    {schema_version: 2,
     roles: {bar: pick("bar"; $bar), dock: pick("dock"; $dock),
             terminal: pick("terminal"; $terminal), browser: pick("browser"; "firefox"),
             file_manager: pick("file_manager"; "dolphin"), gui_editor: pick("gui_editor"; $editor),
             launcher: pick("launcher"; "wofi")},
     selected: {bar: [pick("bar"; $bar)], dock: [pick("dock"; $dock) | select(. != null)]}}
    | walk(if type == "string" and startswith("{HOME}/") then $home + ltrimstr("{HOME}") else . end)
  ' "$repo_root/packages.json" > "$HOME/.config/hypr/roles.json"
}

reset_state() {
  : > "$STARTS"
  rm -rf -- "$HOME/.cache" "$HOME/.config/nwg-panel/hss-panels" "$HOME/.config/nwg-panel/hss-style.css"
}

# Autostart runs both roles; record what actually started.
autostart() {
  "$scripts/role_exec.sh" bar || fail "bar start for $1"
  "$scripts/role_exec.sh" dock || fail "dock start for $1 exits 0"
}

dock_argv='["nwg-dock-hyprland","-r","-x","-i","40","-c","'"$scripts"'/menu_exec.sh"]'
for bar in waybar ironbar nwg-panel; do
  for dock in "" nwg-dock-hyprland nwg-panel; do
    name="$bar+${dock:-none}"
    reset_state
    write_roles "$bar" "$dock"
    autostart "$name"
    starts=$(jq -cs . "$STARTS")
    case "$bar" in
      waybar|ironbar) bar_start="[\"$bar\"]" ;;
      nwg-panel) bar_start='["nwg-panel","-c","hss-panels"]' ;;
    esac
    case "$bar:$dock" in
      *:) expected="[$bar_start]" ;;
      *:nwg-dock-hyprland) expected="[$bar_start,$dock_argv]" ;;
      nwg-panel:nwg-panel) expected="[$bar_start]" ;;
      *:nwg-panel) expected="[$bar_start,[\"nwg-panel\",\"-c\",\"hss-panels\"]]" ;;
    esac
    [[ $starts == "$(jq -c . <<<"$expected")" ]] || fail "$name starts: $starts"
    panels="$HOME/.config/nwg-panel/hss-panels"
    case "$bar:$dock" in
      nwg-panel:nwg-panel)
        jq -e --argjson signal "$(kill -l RTMIN)" 'map(.name) == ["bar","dock"] and .[0]["use-sigrt"] == true and .[0].sigrt == $signal and .[1]["use-sigrt"] == false' "$panels" >/dev/null \
          || fail "$name shares one process with a bar-only toggle" ;;
      nwg-panel:*) jq -e 'map(.name) == ["bar"]' "$panels" >/dev/null || fail "$name bar-only nwg-panel config" ;;
      *:nwg-panel) jq -e 'map(.name) == ["dock"] and .[0]["use-sigrt"] == false' "$panels" >/dev/null || fail "$name dock-only nwg-panel config" ;;
      *) [[ ! -e $panels ]] || fail "$name writes no nwg-panel config" ;;
    esac
    if [[ -z $dock ]]; then
      [[ ! -e $HOME/.cache/nwg-dock-pinned && ! -e $HOME/.cache/nwg-pin-cache ]] || fail "$name: dock None creates no pin state"
    fi
    # Panel commands use absolute paths: no {HOME} placeholder survives generation.
    if [[ -e $panels ]] && grep -Fq '{HOME}' "$panels"; then fail "$name: unresolved {HOME}"; fi
  done
done
printf 'ok - all nine bar/dock combinations start each process once; dock None and shared nwg-panel docks are no-ops\n'

# Pin seeding: primary terminal, browser, file manager and enabled GUI editor, in order.
reset_state
write_roles waybar nwg-dock-hyprland
"$scripts/role_exec.sh" dock
[[ $(cat "$HOME/.cache/nwg-dock-pinned") == $'kitty\nfirefox\norg.kde.dolphin' ]] || fail 'GUI editor None is omitted from dock pins'
reset_state
write_roles waybar nwg-dock-hyprland kate konsole
"$scripts/role_exec.sh" dock
[[ $(cat "$HOME/.cache/nwg-dock-pinned") == $'org.kde.konsole\nfirefox\norg.kde.dolphin\norg.kde.kate' ]] || fail 'enabled GUI editor and terminal class pins'
reset_state
write_roles waybar nwg-dock-hyprland visual-studio-code-bin
"$scripts/role_exec.sh" dock
[[ $(cat "$HOME/.cache/nwg-dock-pinned") == $'kitty\nfirefox\norg.kde.dolphin\ncode' ]] || fail 'VS Code pins its window class'
[[ $(HSS_ROLES_FILE=$HOME/.config/hypr/roles.json "$scripts/dock_pins.sh" desktop-file) == $'kitty.desktop\nfirefox.desktop\norg.kde.dolphin.desktop\ncode.desktop' ]] \
  || fail 'nwg-panel pins use desktop file names'
reset_state
write_roles nwg-panel nwg-panel zed
autostart 'nwg-panel pins'
[[ $(cat "$HOME/.cache/nwg-pin-cache") == $'kitty.desktop\nfirefox.desktop\norg.kde.dolphin.desktop\ndev.zed.Zed.desktop' ]] || fail 'nwg-panel dock pin cache is seeded'
[[ $(stat -c %a "$HOME/.cache/nwg-pin-cache") == 644 ]] || fail 'pin cache mode'
printf 'ok - initial pins follow the primary terminal, browser, file manager and enabled GUI editor for both docks\n'

# Existing pins (including an empty file) are never rewritten; XDG_CACHE_HOME is honored.
reset_state
write_roles waybar nwg-dock-hyprland kate
mkdir -p "$HOME/.cache"
printf 'foot\nmy.custom.App\n' > "$HOME/.cache/nwg-dock-pinned"
"$scripts/role_exec.sh" dock
[[ $(cat "$HOME/.cache/nwg-dock-pinned") == $'foot\nmy.custom.App' ]] || fail 'existing dock pins are preserved'
: > "$HOME/.cache/nwg-dock-pinned"
"$scripts/role_exec.sh" dock
[[ ! -s $HOME/.cache/nwg-dock-pinned ]] || fail 'an emptied pin file stays empty'
reset_state
write_roles nwg-panel nwg-panel
mkdir -p "$HOME/.cache"
printf 'org.gnome.Calculator.desktop\n' > "$HOME/.cache/nwg-pin-cache"
"$scripts/role_exec.sh" bar
[[ $(cat "$HOME/.cache/nwg-pin-cache") == org.gnome.Calculator.desktop ]] || fail 'existing nwg-panel pins are preserved'
reset_state
write_roles waybar nwg-dock-hyprland
XDG_CACHE_HOME="$fixture/xdg-cache" "$scripts/role_exec.sh" dock
[[ -s $fixture/xdg-cache/nwg-dock-pinned && ! -e $HOME/.cache/nwg-dock-pinned ]] || fail 'XDG_CACHE_HOME holds the pins'
printf 'ok - existing and emptied pin files are preserved and the cache directory exists before the dock starts\n'

# Dock None through every entry point: successful no-op without state.
reset_state
write_roles waybar ""
"$scripts/role_exec.sh" dock || fail 'role_exec.sh dock with None exits 0'
"$scripts/nwg_dock.sh" || fail 'nwg_dock.sh with None exits 0'
[[ ! -s $STARTS && ! -e $HOME/.cache ]] || fail 'dock None starts nothing and writes nothing'
printf 'ok - dock None is a successful no-op from role_exec.sh and the dock wrapper\n'

# The themed nwg-panel stylesheet is used only when its imports exist.
reset_state
write_roles nwg-panel ""
mkdir -p "$fixture/generated"
printf '#hss-bar {}\n' > "$fixture/generated/style.css"
printf '/* >>> hss-theme:nwg-panel >>> */\n@import url("file://%s/generated/style.css");\n/* <<< hss-theme:nwg-panel <<< */\n' "$fixture" \
  > "$HOME/.config/nwg-panel/hss-style.css"
"$scripts/role_exec.sh" bar
[[ $(jq -c . "$STARTS") == '["nwg-panel","-c","hss-panels","-s","hss-style.css"]' ]] || fail 'themed stylesheet is passed'
: > "$STARTS"
rm -- "$fixture/generated/style.css"
"$scripts/role_exec.sh" bar
[[ $(jq -c . "$STARTS") == '["nwg-panel","-c","hss-panels"]' ]] || fail 'missing theme import falls back to the default stylesheet'
printf 'ok - nwg-panel uses the themed stylesheet only while its generated import exists\n'

# Bar toggle hides only the bar; it never matches a dock process.
cat > "$fixture/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$PGREP_LOG"
exit 0
STUB
cat > "$fixture/bin/pkill" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$PKILL_LOG"
STUB
chmod +x "$fixture/bin/pgrep" "$fixture/bin/pkill"
export PGREP_LOG="$fixture/pgrep" PKILL_LOG="$fixture/pkill"
for bar in waybar ironbar nwg-panel; do
  write_roles "$bar" nwg-dock-hyprland
  "$scripts/toggle_waybar.sh"
  mapfile -d '' args < "$PKILL_LOG"
  case "$bar" in
    nwg-panel)
      [[ ${args[*]:0:4} == "-u $UID --signal RTMIN" && ${args[4]} == -f ]] || fail 'nwg-panel toggle signals the bar'
      pattern=${args[5]}
      grep -Eq -- "$pattern" <<<'/usr/bin/python /usr/bin/nwg-panel -c hss-panels -s hss-style.css' || fail 'toggle matches the shared panel'
      ! grep -Eq -- "$pattern" <<<'nwg-dock-hyprland -r -x -i 40' || fail 'toggle never matches the dock'
      ;;
    *) [[ ${args[*]} == "-u $UID -x $bar" ]] || fail "$bar toggle targets only the exact bar process: ${args[*]}" ;;
  esac
done
printf 'ok - the bar toggle targets only the bar (RT signal for the shared nwg-panel process)\n'

# Shellcheck-clean, argv-safe wrappers: no eval or sh -c with interpolated data.
for script in nwg_panel.sh nwg_dock.sh dock_pins.sh toggle_waybar.sh; do
  ! grep -Eq '(^|[^[:alnum:]_])eval[[:space:]]' "$scripts/$script" || fail "$script uses eval"
done
printf 'ok - panel lifecycle wrappers use literal argv\n'
