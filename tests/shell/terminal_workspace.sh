#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal $ in argv fixtures.
set -euo pipefail

# D05.3/D05.4 terminal workspace: term_exec.sh argv and --cwd contract for all five
# terminals, and deterministic terminal/multiplexer theme units for both variants.
unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
term_exec="$repo_root/dotfiles/.config/hypr/scripts/term_exec.sh"
base=$(mktemp -d)
trap 'chmod -R u+rwx "$base" 2>/dev/null || true; rm -rf -- "$base"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

bin="$base/bin"
mkdir -p "$bin"
# Terminal double: records argv (NUL-separated) and the working directory it started in.
cat > "$bin/terminal-double" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$TERMINAL_ARGV_LOG"
pwd > "$TERMINAL_CWD_LOG"
STUB
chmod +x "$bin/terminal-double"
for executable in kitty alacritty ghostty konsole foot; do
  ln -s "$bin/terminal-double" "$bin/$executable"
done
export PATH="$bin:$PATH"
export TERMINAL_ARGV_LOG="$base/argv" TERMINAL_CWD_LOG="$base/cwd"

roles_for() {
  local package=$1
  jq -n --slurpfile registry "$repo_root/packages.json" --arg package "$package" '
    ($registry[0].roles.terminal.options[] | select(.package == $package)) as $terminal
    | {schema_version: 2, roles: {terminal: $terminal}, selected: {terminal: [$terminal]}, agent_executables: {}}
  ' > "$base/roles-$package.json"
  printf '%s\n' "$base/roles-$package.json"
}

assert_argv() {
  local label=$1
  shift
  local -a actual=()
  mapfile -d '' actual < "$TERMINAL_ARGV_LOG"
  if [[ ${#actual[@]} != "$#" ]]; then
    fail "$label: expected $# arguments, got ${#actual[@]}: ${actual[*]}"
  fi
  local index=0 expected
  for expected in "$@"; do
    [[ ${actual[$index]} == "$expected" ]] || fail "$label: argument $index is '${actual[$index]}', expected '$expected'"
    index=$((index + 1))
  done
}

workdir="$base/work dir/-leading dash"
caller="$base/caller"
mkdir -p "$workdir" "$caller"
command_args=(nvim '/tmp/file with spaces' '$(touch pwned)')

# Legacy argv without --cwd stays byte-for-byte compatible and inherits the caller cwd.
declare -A legacy_prefix=(
  [kitty]='--class|hss-test|--title|Test title|-e'
  [alacritty]='--class|hss-test|--title|Test title|-e'
  [ghostty]='--class=hss-test|--title=Test title|-e'
  [foot]='--app-id=hss-test|--title=Test title'
  [konsole]='--separate|-p|tabtitle=hss-test|-e'
)
declare -A cwd_flag=(
  [kitty]="--directory|$workdir"
  [alacritty]="--working-directory|$workdir"
  [ghostty]="--working-directory=$workdir"
  [foot]="--working-directory=$workdir"
  [konsole]="--workdir|$workdir"
)
for package in kitty alacritty ghostty konsole foot; do
  roles=$(roles_for "$package")
  IFS='|' read -r -a prefix <<< "${legacy_prefix[$package]}"
  rm -f "$TERMINAL_ARGV_LOG" "$TERMINAL_CWD_LOG"
  (cd "$caller" && HSS_ROLES_FILE="$roles" "$term_exec" --app-id hss-test --title 'Test title' -- "${command_args[@]}")
  assert_argv "$package legacy" "${prefix[@]}" "${command_args[@]}"
  [[ $(<"$TERMINAL_CWD_LOG") == "$caller" ]] || fail "$package inherits the caller cwd"

  # --cwd adds the terminal's native working-directory flag before the command.
  IFS='|' read -r -a flag <<< "${cwd_flag[$package]}"
  case "$package" in
    foot) expected=("${prefix[@]}" "${flag[@]}" "${command_args[@]}") ;;
    *) expected=("${prefix[@]:0:${#prefix[@]}-1}" "${flag[@]}" -e "${command_args[@]}") ;;
  esac
  rm -f "$TERMINAL_ARGV_LOG" "$TERMINAL_CWD_LOG"
  (cd "$caller" && HSS_ROLES_FILE="$roles" "$term_exec" --app-id hss-test --title 'Test title' --cwd "$workdir" -- "${command_args[@]}")
  assert_argv "$package --cwd" "${expected[@]}"
  [[ $(<"$TERMINAL_CWD_LOG") == "$workdir" ]] || fail "$package child starts in --cwd"

  # A relative --cwd is resolved against the caller and passed as an absolute path.
  rm -f "$TERMINAL_ARGV_LOG"
  (cd "$base/work dir" && HSS_ROLES_FILE="$roles" "$term_exec" --cwd '-leading dash' -- true)
  mapfile -d '' argv < "$TERMINAL_ARGV_LOG"
  printf '%s\n' "${argv[@]}" | grep -Fq "$workdir" || fail "$package relative --cwd becomes absolute"
  [[ ! -e $caller/pwned && ! -e $workdir/pwned ]] || fail "$package evaluated an argument"
done
printf 'ok - all five terminals keep their legacy argv and add the native cwd flag for --cwd\n'

roles=$(roles_for kitty)
expect_refusal() {
  local label=$1 pattern=$2
  shift 2
  rm -f "$TERMINAL_ARGV_LOG"
  local output status=0
  output=$(HSS_ROLES_FILE="$roles" "$term_exec" "$@" 2>&1) || status=$?
  [[ $status == 2 ]] || fail "$label exits 2 (got $status)"
  grep -Fq -- "$pattern" <<<"$output" || fail "$label message: $output"
  [[ ! -e $TERMINAL_ARGV_LOG ]] || fail "$label launched a terminal"
}
expect_refusal 'missing directory' 'does not exist' --cwd "$base/missing" -- true
touch "$base/plain-file"
expect_refusal 'file instead of directory' 'not a directory' --cwd "$base/plain-file" -- true
expect_refusal 'empty --cwd' 'Usage' --cwd '' -- true
expect_refusal 'missing --cwd value' 'Usage' --cwd
expect_refusal 'missing command' 'Usage' --cwd "$workdir" --
if [[ $(id -u) != 0 ]]; then
  mkdir -p "$base/locked"
  chmod 000 "$base/locked"
  expect_refusal 'unreadable directory' 'not accessible' --cwd "$base/locked" -- true
  chmod 700 "$base/locked"
fi
printf 'ok - missing, non-directory and inaccessible --cwd values fail clearly without launching\n'

# ---------------------------------------------------------------------------
# D05.3/D05.4 theme units: deterministic rendering for both variants.
# shellcheck source=tests/shell/theme_units_testlib.sh
source "$repo_root/tests/shell/theme_units_testlib.sh"

declare -A expect_bg=([dark]='#1e1e2e' [light]='#eff1f5')
declare -A expect_fg=([dark]='#cdd6f4' [light]='#4c4f69')
declare -A expect_accent=([dark]='#89b4fa' [light]='#1e66f5')
declare -A expect_flavor=([dark]=mocha [light]=latte)
d05_units=(kitty alacritty foot ghostty konsole tmux zellij herdr fish zsh starship)

all_home="$base/all-members/home"
new_theme_home "$all_home"
make_member_roles "$base/all-roles.json" \
  terminal=kitty,alacritty,ghostty,konsole,foot multiplexer=herdr-bin,tmux,zellij \
  shell=fish,bash,zsh agent=pi,opencode,claude-code,codex-cli,cursor-cli

# Shipped configuration: the include is authoritative on fresh installs.
kitty_conf="$all_home/.config/kitty/kitty.conf"
awk '/>>> hss-theme:kitty >>>/ {skip = 1} !skip && /^[[:space:]]*(color[0-9]+|foreground|background|selection_(fore|back)ground|cursor)[[:space:]]/ {print; bad = 1} /<<< hss-theme:kitty <<</ {skip = 0} END {exit bad}' "$kitty_conf" \
  || fail "shipped kitty.conf still defines colours outside the theme region"
! grep -qi 'firacode' "$kitty_conf" || fail "shipped kitty.conf still uses FiraCode"
grep -Fxq 'include ~/.config/hss-theme/generated/kitty/theme.conf' "$kitty_conf" || fail "shipped kitty include"
python3 - "$all_home/.config/alacritty/alacritty.toml" <<'PY' || fail "shipped alacritty.toml imports the theme and has no colours or font families"
import sys, tomllib
data = tomllib.load(open(sys.argv[1], "rb"))
assert data["general"]["import"] == ["~/.config/hss-theme/generated/alacritty/theme.toml"], data["general"]
assert "colors" not in data
assert all("family" not in value for value in data["font"].values() if isinstance(value, dict))
assert "import" not in {key for key in data if key != "general"}
PY
zellij_conf="$all_home/.config/zellij/config.kdl"
[[ $(grep -E '^[[:space:]]*theme[[:space:]]' "$zellij_conf") == 'theme "hss"' ]] || fail "shipped zellij config has exactly one theme node"
grep -Fxq 'default_mode "locked"' "$zellij_conf" || fail "zellij locked mode kept"
python3 - "$all_home/starship.toml" <<'PY' || fail "starship palette key precedes the multi-line format"
import sys, tomllib
text = open(sys.argv[1], encoding="utf-8").read()
data = tomllib.loads(text)
assert data["palette"] == "catppuccin_mocha"
assert {"catppuccin_mocha", "catppuccin_latte"} <= set(data["palettes"])
assert text.index('\npalette = ') < text.index('\nformat = """')
PY
printf 'ok - shipped kitty, alacritty, zellij and starship configuration leave colours to the theme\n'

for variant in dark light; do
  out="$base/plan-$variant"
  theme_plan "$variant" "$base/all-roles.json" "$all_home" "$out" --adopt
  for unit in "${d05_units[@]}"; do
    status=$(theme_unit_status "$out" "$unit")
    [[ $status == ready || $status == unchanged ]] || fail "$variant $unit status $status: $(jq -c --arg id "$unit" '.units[] | select(.id == $id) | .reason' "$out/plan.json")"
  done
  bg=${expect_bg[$variant]} fg=${expect_fg[$variant]} accent=${expect_accent[$variant]}

  kitty_theme=$(theme_candidate "$out" kitty kitty/theme.conf)
  grep -Eq "^background +$bg$" "$kitty_theme" || fail "$variant kitty background"
  grep -Eq "^foreground +$fg$" "$kitty_theme" || fail "$variant kitty foreground"
  [[ $(grep -Ec '^color([0-9]|1[0-5]) ' "$kitty_theme") == 16 ]] || fail "$variant kitty has 16 ANSI colours"
  grep -Eq '^font_family +JetBrainsMono Nerd Font$' "$kitty_theme" || fail "$variant kitty font family"
  grep -Fxq "include $all_home/.config/hss-theme/generated/kitty/theme.conf" "$(theme_candidate "$out" kitty kitty/kitty.conf)" || fail "$variant kitty include is absolute"
  [[ $(jq -c '.units[] | select(.id == "kitty") | .activation' "$out/plan.json") == '[{"kind":"signal","process":"kitty","signal":"USR1"}]' ]] || fail "kitty SIGUSR1 activation"

  python3 - "$(theme_candidate "$out" alacritty alacritty/theme.toml)" "$bg" "$fg" <<'PY' || fail "$variant alacritty theme"
import sys, tomllib
data = tomllib.load(open(sys.argv[1], "rb"))
assert data["colors"]["primary"] == {"foreground": sys.argv[3], "background": sys.argv[2]}
assert len(data["colors"]["normal"]) == 8 and len(data["colors"]["bright"]) == 8
assert data["font"] == {"normal": {"family": "JetBrainsMono Nerd Font"}}
PY

  foot_theme=$(theme_candidate "$out" foot foot/theme.ini)
  grep -Fxq "[colors-$variant]" "$foot_theme" || fail "$variant foot colour section"
  grep -Fxq "initial-color-theme=$variant" "$foot_theme" || fail "$variant foot initial theme"
  grep -Fxq "background=${bg#\#}" "$foot_theme" || fail "$variant foot background"
  grep -Fxq 'font=JetBrainsMono Nerd Font' "$foot_theme" || fail "$variant foot font family without size"
  [[ $(grep -c '^\[colors\]' "$foot_theme") == 0 ]] || fail "foot uses no removed [colors] section"
  foot_ini=$(theme_candidate "$out" foot foot/foot.ini)
  [[ $(sed -n 2p "$foot_ini") == "include=$all_home/.config/hss-theme/generated/foot/theme.ini" ]] || fail "$variant foot include is first and absolute"

  ghostty_theme=$(theme_candidate "$out" ghostty ghostty/theme)
  [[ $(grep -c '^palette = ' "$ghostty_theme") == 16 ]] || fail "$variant ghostty palette"
  [[ $(grep -m1 '^font-family' "$ghostty_theme") == 'font-family = ""' ]] || fail "ghostty resets the font list first"
  grep -Fxq "background = $bg" "$ghostty_theme" || fail "$variant ghostty background"
  grep -Fxq "config-file = ?$all_home/.config/hss-theme/generated/ghostty/theme" "$(theme_candidate "$out" ghostty config.ghostty)" || fail "$variant ghostty include"

  konsole_scheme=$(theme_candidate "$out" konsole hss-catppuccin.colorscheme)
  rgb=$(printf '%d,%d,%d' "0x${bg:1:2}" "0x${bg:3:2}" "0x${bg:5:2}")
  awk -v rgb="Color=$rgb" '/^\[Background\]$/ {getline; exit ($0 != rgb)}' "$konsole_scheme" || fail "$variant konsole background"
  konsole_profile=$(theme_candidate "$out" konsole hss-catppuccin.profile)
  grep -Fxq 'ColorScheme=hss-catppuccin' "$konsole_profile" || fail "konsole profile scheme"
  ! grep -q '^Font=' "$konsole_profile" || fail "konsole profile must not set a font size"
  grep -Fxq 'DefaultProfile=hss-catppuccin.profile' "$(theme_candidate "$out" konsole konsolerc)" || fail "konsole default profile"

  tmux_theme=$(theme_candidate "$out" tmux tmux/theme.conf)
  grep -Fxq "set -g pane-active-border-style \"fg=$accent\"" "$tmux_theme" || fail "$variant tmux accent"
  grep -Fxq "source-file -q '$all_home/.config/hss-theme/generated/tmux/theme.conf'" "$(theme_candidate "$out" tmux tmux/tmux.conf)" || fail "$variant tmux region"
  [[ $(jq -c '.units[] | select(.id == "tmux") | .activation[0].process' "$out/plan.json") == '"tmux: server"' ]] || fail "tmux reload targets the server process"

  zellij_theme=$(theme_candidate "$out" zellij zellij/themes/hss.kdl)
  accent_rgb=$(printf '%d %d %d' "0x${accent:1:2}" "0x${accent:3:2}" "0x${accent:5:2}")
  grep -Eq "ribbon_selected \{ base [0-9 ]+; background $accent_rgb;" "$zellij_theme" || fail "$variant zellij accent ribbon"
  [[ $(grep -E '^[[:space:]]*theme[[:space:]]' "$(theme_candidate "$out" zellij zellij/config.kdl)") == 'theme "hss"' ]] || fail "$variant zellij single theme node"

  grep -Fxq "name = \"catppuccin-${expect_flavor[$variant]}\"" "$(theme_candidate "$out" herdr herdr/config.toml)" || fail "$variant herdr theme"

  fish_theme=$(theme_candidate "$out" fish fish/theme.fish)
  grep -Fxq "set -g fish_color_command ${accent#\#}" "$fish_theme" || fail "$variant fish command colour"
  fish --no-execute "$fish_theme" || fail "$variant fish theme syntax"
  fish --no-execute "$(theme_candidate "$out" fish fish/config.fish)" || fail "$variant config.fish syntax"

  zshrc=$(theme_candidate "$out" zsh .zshrc)
  [[ $(head -n1 "$zshrc") == '# >>> hss-theme:zsh >>>' ]] || fail "zsh region is prepended"
  grep -Fq "PROMPT='%F{4}%n@%m%f" "$zshrc" || fail "zsh prompt uses ANSI slots"

  python3 - "$(theme_candidate "$out" starship starship.toml)" "${expect_flavor[$variant]}" <<'PY' || fail "$variant starship palette"
import sys, tomllib
data = tomllib.load(open(sys.argv[1], "rb"))
assert data["palette"] == "catppuccin_" + sys.argv[2], data["palette"]
assert data["palette"] in data["palettes"]
PY

  # Terminal themes never set a font size.
  for file in "$kitty_theme" "$foot_theme" "$ghostty_theme" "$konsole_profile" "$(theme_candidate "$out" alacritty alacritty/theme.toml)"; do
    ! grep -Ev '^[[:space:]]*#' "$file" | grep -Eiq 'font_size|font-size|:size=|^size' || fail "$variant theme sets a font size: $file"
  done
done
printf 'ok - terminal, multiplexer, shell and prompt units render Mocha and Latte with absolute includes and no font size\n'

# Only selected members get units; agents never produce units, so agent None is inert.
make_member_roles "$base/kitty-roles.json" terminal=kitty multiplexer=tmux shell=bash agent=
theme_plan dark "$base/kitty-roles.json" "$all_home" "$base/plan-kitty" --adopt
for unit in alacritty foot ghostty konsole zellij herdr fish zsh; do
  [[ $(theme_unit_status "$base/plan-kitty" "$unit") == not-selected ]] || fail "$unit applies without its member"
done
for unit in kitty tmux; do
  status=$(theme_unit_status "$base/plan-kitty" "$unit")
  [[ $status == ready || $status == unchanged ]] || fail "$unit applies for its member"
done
[[ $(jq -r '[.units[].applies.members[]?] | any(startswith("agent/"))' "$repo_root/dotfiles/.config/hypr/theme/units.d/50-d05-terminal.json") == false ]] \
  || fail "an agent produces theme units"
printf 'ok - non-selected terminals, multiplexers and shells are not themed; agents and agent None have no units\n'

# Existing users: no region and no adoption means preview only; edited regions are kept.
existing="$base/existing/home"
mkdir -p "$existing/.config/kitty"
printf 'font_size 12\nbackground #000000\n' > "$existing/.config/kitty/kitty.conf"
theme_plan dark "$base/kitty-roles.json" "$existing" "$base/plan-existing"
[[ $(theme_unit_status "$base/plan-existing" kitty) == not-adopted ]] || fail "existing kitty.conf is not adopted without consent"
theme_plan dark "$base/kitty-roles.json" "$existing" "$base/plan-existing" --adopt
theme_commit "$base/plan-existing"
python3 "$repo_root/dotfiles/.config/hypr/theme/hss_theme.py" finalize --plan "$base/plan-existing/plan.json" \
  --theme-root "$existing/.config/hss-theme" --applied kitty,tmux,theme-core --out-managed "$existing/.config/hss-theme/managed.json" --out-state "$base/state.json"
grep -Fxq 'font_size 12' "$existing/.config/kitty/kitty.conf" || fail "user font size kept"
sed -i 's|^include .*kitty/theme.conf$|include /somewhere/else.conf|' "$existing/.config/kitty/kitty.conf"
theme_plan light "$base/kitty-roles.json" "$existing" "$base/plan-existing-2"
[[ $(theme_unit_status "$base/plan-existing-2" kitty) == skipped-conflict ]] || fail "edited kitty region is preserved"
printf 'ok - existing terminal configuration is only previewed without adoption and edited regions are preserved\n'
