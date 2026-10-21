#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # Subshells deliberately isolate exported test state.
set -euo pipefail

# D01.2: bar and dock theme units render and validate for both variants, keep user rules,
# respect None selections, and activate without restarting shared panel processes.
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
theme_dir="$repo_root/dotfiles/.config/hypr/theme"
unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

python3 -B "$theme_dir/hss_theme.py" check > /dev/null || fail 'theme registry check'
printf 'ok - theme registry with the D01 fragment validates for both variants\n'

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export HOME="$fixture/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$fixture/state"
mkdir -p "$HOME/dotfiles/.config" "$HOME/.config/hypr"
# Stow-style directory links, as installed by setup.
for name in waybar nwg-panel ironbar; do
  cp -a "$repo_root/dotfiles/.config/$name" "$HOME/dotfiles/.config/$name"
  ln -s "$HOME/dotfiles/.config/$name" "$HOME/.config/$name"
done
cp -a "$repo_root/dotfiles/.config/hypr/theme" "$HOME/.config/hypr/theme"
cp -a "$repo_root/dotfiles/.config/hypr/scripts" "$HOME/.config/hypr/scripts"
theme_root="$HOME/.config/hss-theme"

write_roles() {
  # selected bar members, selected dock members (space-separated package lists)
  jq -n --arg bars "$1" --arg docks "$2" '
    def members($list): $list | split(" ") | map(select(. != "") | {package: .});
    {schema_version: 2,
     roles: {bar: (members($bars)[0] // null), dock: (members($docks)[0] // null)},
     selected: {bar: members($bars), dock: members($docks)}}' > "$HOME/.config/hypr/roles.json"
}

plan() {
  local variant=$1
  shift
  rm -rf -- "$fixture/staging"
  python3 -B "$HOME/.config/hypr/theme/hss_theme.py" plan --variant "$variant" \
    --roles "$HOME/.config/hypr/roles.json" --home "$HOME" --config-home "$HOME/.config" \
    --data-home "$HOME/.local/share" --theme-root "$theme_root" --staging "$fixture/staging" \
    --out "$fixture/plan.json" "$@"
}

# Commit ready units like providers/theme.sh does, then record the managed state.
commit() {
  local staged target applied unchanged
  while IFS=$'\t' read -r staged target; do
    mkdir -p -- "$(dirname -- "$target")"
    cat -- "$staged" > "$target"
  done < <(jq -r '.units[] | select(.status == "ready") | .outputs[] | select(.staged != null) | [.staged, .target] | @tsv' "$fixture/plan.json")
  applied=$(jq -r '[.units[] | select(.status == "ready") | .id] | join(",")' "$fixture/plan.json")
  unchanged=$(jq -r '[.units[] | select(.status == "unchanged") | .id] | join(",")' "$fixture/plan.json")
  mkdir -p -- "$theme_root"
  python3 -B "$HOME/.config/hypr/theme/hss_theme.py" finalize --plan "$fixture/plan.json" --theme-root "$theme_root" \
    --applied "$applied" --unchanged "$unchanged" --out-managed "$fixture/managed.json" --out-state "$fixture/state.json"
  cp -- "$fixture/managed.json" "$theme_root/managed.json"
  cp -- "$fixture/state.json" "$theme_root/state.json"
}

status_of() {
  jq -r --arg id "$1" '.units[] | select(.id == $id) | .status' "$fixture/plan.json"
}

d01_units=$(jq -r '.units[].id' "$theme_dir/units.d/10-d01-panels.json" | sort | tr '\n' ' ')
[[ $d01_units == 'ironbar nwg-dock-hyprland nwg-panel waybar ' ]] || fail "D01 units: $d01_units"

# 1. Fresh install: every selected bar and dock member renders for both variants.
write_roles 'waybar ironbar nwg-panel' 'nwg-dock-hyprland nwg-panel'
for variant in dark light; do
  plan "$variant" --adopt
  for unit in waybar ironbar nwg-panel nwg-dock-hyprland; do
    [[ $(status_of "$unit") == ready || $(status_of "$unit") == unchanged ]] || fail "$variant $unit status $(status_of "$unit")"
  done
  commit
  colors="$theme_root/generated/waybar/colors.css"
  case "$variant" in
    dark) grep -Fqx '@define-color hss_bg #1e1e2e;' "$colors" || fail 'dark Waybar uses Mocha base' ;;
    light) grep -Fqx '@define-color hss_bg #eff1f5;' "$colors" || fail 'light Waybar uses Latte base' ;;
  esac
  for file in "$colors" "$theme_root/generated/nwg-panel/style.css" "$theme_root/generated/ironbar/style.css" \
    "$HOME/.config/nwg-dock-hyprland/style.css"; do
    [[ -s $file ]] || fail "$variant output $file"
    ! grep -Fq '{{' "$file" || fail "$file has unresolved placeholders"
    [[ $(tr -cd '{' < "$file" | wc -c) == $(tr -cd '}' < "$file" | wc -c) ]] || fail "$file braces"
  done
done
printf 'ok - Waybar, Ironbar, nwg-panel and nwg-dock-hyprland units render Mocha and Latte outputs\n'

# 2. Waybar: every @hss_ name in style.css has a fallback before the region and a themed value.
style="$HOME/.config/waybar/style.css"
region_start=$(grep -n '^/\* >>> hss-theme:waybar >>> \*/$' "$style" | cut -d: -f1)
region_end=$(grep -n '^/\* <<< hss-theme:waybar <<< \*/$' "$style" | cut -d: -f1)
[[ -n $region_start && -n $region_end ]] || fail 'Waybar style has one theme region'
[[ $(sed -n "$((region_start + 1)),$((region_end - 1))p" "$style") == "@import url(\"file://$theme_root/generated/waybar/colors.css\");" ]] \
  || fail 'Waybar region imports the absolute generated path'
last_fallback=$(grep -n '^@define-color hss_' "$style" | tail -1 | cut -d: -f1)
first_rule=$(grep -n '^window#waybar' "$style" | cut -d: -f1)
(( last_fallback < region_start && region_end < first_rule )) || fail 'region sits between fallbacks and rules'
while IFS= read -r name; do
  grep -Eq "^@define-color ${name#@} " "$style" || fail "$name has no fallback"
  grep -Eq "^@define-color ${name#@} " "$theme_root/generated/waybar/colors.css" || fail "$name is not themed"
done < <(grep -o '@hss_[a-z0-9_]*' "$style" | sort -u)
if grep -Eq '#[0-9a-fA-F]{6}' <(sed -n "$((region_end + 1)),\$p" "$style"); then
  fail 'Waybar rules use theme names, not literal colors'
fi
while IFS= read -r name; do
  grep -Eq "^@define-color ${name#@} " "$theme_root/generated/nwg-panel/style.css" || fail "nwg-panel $name undefined"
done < <(grep -o '@hss_[a-z0-9_]*' "$theme_root/generated/nwg-panel/style.css" | sort -u)
grep -Fqx "@import url(\"file://$theme_root/generated/nwg-panel/style.css\");" "$HOME/.config/nwg-panel/hss-style.css" \
  || fail 'nwg-panel hss-style.css imports the generated stylesheet'
printf 'ok - Waybar style keeps fallbacks, an absolute theme import and theme names only; nwg-panel imports its stylesheet\n'

# 3. Reruns are unchanged; switching variants changes generated files, not user regions.
plan light
for unit in waybar ironbar nwg-panel nwg-dock-hyprland; do
  [[ $(status_of "$unit") == unchanged ]] || fail "rerun leaves $unit unchanged"
done
cp -- "$style" "$fixture/style.before"
plan dark
[[ $(status_of waybar) == ready && $(status_of ironbar) == ready && $(status_of nwg-panel) == ready ]] || fail 'variant switch updates the bar units'
[[ $(jq -r '.units[] | select(.id == "waybar") | .outputs[] | select(.target | endswith("style.css")) | .action' "$fixture/plan.json") == unchanged ]] \
  || fail 'variant switch leaves the Waybar region unchanged'
commit
cmp -s "$style" "$fixture/style.before" || fail 'Waybar style.css untouched by a variant switch'
grep -Fqx '@define-color hss_bg #1e1e2e;' "$theme_root/generated/waybar/colors.css" || fail 'variant switch rewrites the generated colors'
printf 'ok - reruns are unchanged and variant switches only rewrite generated colors\n'

# 4. User rules survive; edits inside a region are conflicts, not overwritten.
printf '#clock { color: red; }\n' >> "$style"
plan light
[[ $(status_of waybar) == ready ]] || fail 'user rule after the region does not block the theme'
commit
grep -Fqx '#clock { color: red; }' "$style" || fail 'user rule kept'
sed -i "s|^@import url(\"file://$theme_root/generated/waybar/colors.css\");|@import url(\"file:///elsewhere.css\");|" "$style"
plan dark
[[ $(status_of waybar) == skipped-conflict ]] || fail 'edited Waybar region is a conflict'
printf 'ok - user rules outside the region survive and edited regions are reported as conflicts\n'

# 5. Dock style: created when missing; appended to an existing upstream style.css.
rm -rf -- "$HOME/.config/nwg-dock-hyprland" "$theme_root"
mkdir -p "$HOME/.config/nwg-dock-hyprland"
printf 'window {\n  background: #36364f;\n}\n' > "$HOME/.config/nwg-dock-hyprland/style.css"
plan dark
[[ $(status_of nwg-dock-hyprland) == not-adopted ]] || fail 'existing dock style needs adoption'
plan dark --adopt
commit
dock_style="$HOME/.config/nwg-dock-hyprland/style.css"
[[ $(head -3 "$dock_style") == $'window {\n  background: #36364f;\n}' ]] || fail 'upstream dock rules kept before the region'
grep -Fq 'border-bottom: 2px solid #89b4fa;' "$dock_style" || fail 'dock active indicator uses the accent'
! grep -Fq '@import url(' "$dock_style" || fail 'dock theme is inline (nwg-dock exits on a failed import)'
printf '#box { padding: 0; }\n' >> "$dock_style"
plan light
commit
grep -Fq 'border-bottom: 2px solid #1e66f5;' "$dock_style" || fail 'light dock accent'
[[ $(tail -1 "$dock_style") == '#box { padding: 0; }' ]] || fail 'user dock rule after the region kept'
printf 'ok - dock theme is created or appended inline, switches variants and keeps user rules\n'

# 6. None and unselected members produce no units.
write_roles 'waybar' ''
plan dark --adopt
for unit in ironbar nwg-panel nwg-dock-hyprland; do
  [[ $(status_of "$unit") == not-selected ]] || fail "$unit is not selected with Waybar and dock None"
done
write_roles 'ironbar' 'nwg-panel'
plan dark --adopt
[[ $(status_of nwg-panel) == ready || $(status_of nwg-panel) == unchanged ]] || fail 'nwg-panel dock alone selects the shared unit'
[[ $(status_of waybar) == not-selected ]] || fail 'Waybar unit follows selection'
printf 'ok - dock None and unselected bars produce no theme units; one nwg-panel unit serves bar and dock\n'

# 7. Activation: safe reloads only; shared panel processes are never restarted.
jq -e '
  [.units[] | {id, kinds: [.activation[].kind]}] as $units
  | ($units | map(select(.id == "waybar")) | .[0].kinds) == ["signal"]
  and ($units | map(select(.id == "nwg-panel" or .id == "nwg-dock-hyprland")) | all(.kinds == ["next-launch"]))
  and ([.units[].activation[] | select(.kind == "reload") | .argv[0]] | all(. != "nwg-panel" and . != "nwg-dock-hyprland" and . != "pkill" and . != "killall"))
' "$theme_dir/units.d/10-d01-panels.json" > /dev/null || fail 'D01 activation descriptors'

# End to end through the shared action: Waybar receives USR2, other panels are untouched.
mkdir -p "$fixture/bin"
cat > "$fixture/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
# Model a running Waybar and nwg-panel; record every query.
printf '%s\n' "$*" >> "$PROCESS_LOG"
[[ ${*: -1} == waybar || ${*: -1} == nwg-panel ]]
STUB
cat > "$fixture/bin/pkill" <<'STUB'
#!/usr/bin/env bash
printf 'pkill %s\n' "$*" >> "$PROCESS_LOG"
STUB
chmod +x "$fixture/bin/pgrep" "$fixture/bin/pkill"
export PROCESS_LOG="$fixture/process.log"
rm -rf -- "$theme_root"
write_roles 'waybar' 'nwg-panel'
cp -- "$repo_root/dotfiles/.config/waybar/style.css" "$style"
# Runtime switching changes only configuration that setup adopted with consent first.
(
  export HSS_SCRIPTS_DIR="$HOME/.config/hypr/scripts" HSS_ACTION_NOTIFY=0 HSS_ROLES_FILE="$HOME/.config/hypr/roles.json"
  export PATH="$fixture/bin:$PATH"
  # shellcheck source=/dev/null
  source "$HSS_SCRIPTS_DIR/lib/hss_runtime.sh"
  # shellcheck source=/dev/null
  source "$HSS_SCRIPTS_DIR/providers/theme.sh"
  hss_theme_apply dark --adopt
  [[ $HSS_OUTCOME == completed ]]
) >/dev/null || fail 'adopting the dark theme before the runtime switch'
: > "$PROCESS_LOG"
result=$(PATH="$fixture/bin:$PATH" HSS_ROLES_FILE="$HOME/.config/hypr/roles.json" \
  "$HOME/.config/hypr/scripts/action_exec.sh" --json theme.set light) || fail "theme.set light: $result"
jq -e '.outcome == "completed"' <<<"$result" >/dev/null || fail "theme.set outcome: $result"
grep -Fqx "pkill -u $(id -u) -x -USR2 -- waybar" "$PROCESS_LOG" || fail "Waybar reload signal: $(cat "$PROCESS_LOG")"
! grep -q '^pkill .*nwg' "$PROCESS_LOG" || fail 'nwg-panel is never signalled or restarted'
jq -e '.pending | test("nwg-panel: applies the next time")' <<<"$result" >/dev/null || fail 'nwg-panel theme is reported as pending until next launch'
[[ $(jq -r .variant "$theme_root/state.json") == light ]] || fail 'theme state records light'
HSS_SCRIPTS_DIR="$HOME/.config/hypr/scripts" "$HOME/.config/waybar/scripts/theme_status.sh" \
  | jq -e '.alt == "light"' >/dev/null || fail 'bar theme control reads the applied variant'
printf 'ok - theme.set reloads Waybar by signal, defers nwg-panel to its next launch and the bar control reads the result\n'

# 8. Setup upgrades only unmodified stock Waybar styles to the themed style.
export SETUP_SCRIPT_ROOT=$repo_root
(
  copy_file_atomic() { cp -- "$2" "$1"; }
  print_message() { printf '%s\n' "$*" >> "$fixture/setup-messages"; }
  record_warning() { printf '%s\n' "$*" >> "$fixture/setup-warnings"; }
  # shellcheck source=scripts/lib/setup-panels.sh
  source "$repo_root/scripts/lib/setup-panels.sh"
  rm -f -- "$HOME/.config/waybar"
  mkdir -p "$HOME/.config/waybar"
  printf '/* stock v0 */\n#clock { color: #ffffff; }\n' > "$HOME/dotfiles/.config/waybar/style.css"
  HSS_STOCK_WAYBAR_STYLE_DIGESTS=("$(sha256sum "$HOME/dotfiles/.config/waybar/style.css" | cut -d' ' -f1)")
  printf '/* mine */\n#clock { color: red; }\n' > "$HOME/.config/waybar/style.css"
  panels_upgrade_stock_waybar_style
  cmp -s "$repo_root/dotfiles/.config/waybar/style.css" "$HOME/dotfiles/.config/waybar/style.css" || fail 'stock style is upgraded'
  grep -Fq '/* mine */' "$HOME/.config/waybar/style.css" || fail 'customized style is preserved'
  grep -Fq 'Customized Waybar style kept' "$fixture/setup-warnings" || fail 'customized style is reported'
  [[ ${#HSS_STOCK_WAYBAR_STYLE_DIGESTS[@]} -eq 1 ]]
) || exit 1
# shellcheck source=scripts/lib/setup-panels.sh
source "$repo_root/scripts/lib/setup-panels.sh"
[[ ${#HSS_STOCK_WAYBAR_STYLE_DIGESTS[@]} -ge 14 ]] || fail 'every shipped stock style digest is known'
printf '%s\n' "${HSS_STOCK_WAYBAR_STYLE_DIGESTS[@]}" | grep -Fqx 441272ca38a0376f2f2eaa16b1b03f806fd6c64cd761f7786e7b345cc3190dc2 \
  || fail 'the v0.7.0 stock style digest is known'
printf 'ok - setup upgrades unmodified stock Waybar styles and keeps customized ones\n'
