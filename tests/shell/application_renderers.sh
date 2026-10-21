#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal $ in expected text.
set -euo pipefail

# D06.5 application theme units: deterministic rendering for both variants, preserved user
# settings, None states, files that are never created, and no plugin or network activity.
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

declare -A expect_bg=([dark]='#1e1e2e' [light]='#eff1f5')
declare -A expect_accent=([dark]='#89b4fa' [light]='#1e66f5')
declare -A expect_helix=([dark]=catppuccin_mocha [light]=catppuccin_latte)
d06_units=(neovim helix vim yazi mc vifm calcurse khal kde-color-scheme dolphin kate)
fragment="$repo_root/dotfiles/.config/hypr/theme/units.d/60-d06-applications.json"

# Rendering must not start editors, clone plugins or use the network.
spy="$base/spy"
mkdir -p "$spy"
for tool in nvim vim hx helix git curl wget yazi mc vifm calcurse khal ikhal dolphin kate; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$0 $*" >> "%s/calls"\nexit 0\n' "$base" > "$spy/$tool"
  chmod +x "$spy/$tool"
done
export PATH="$spy:$PATH"

home="$base/home"
new_theme_home "$home"
mkdir -p "$home/.config/vim" "$home/.config/vifm" "$home/.config/khal"
printf 'set number\n' > "$home/.config/vim/vimrc"
printf 'set vicmd=nvim\n' > "$home/.config/vifm/vifmrc"
printf '[calendars]\n[[local]]\npath = ~/.local/share/khal/calendars/local\n[default]\ndefault_calendar = local\n' > "$home/.config/khal/config"
make_member_roles "$base/all-roles.json" tui_editor=neovim,helix,vim,nano \
  tui_file_manager=yazi,ranger,lf,nnn,mc,vifm calendar=calcurse,khal file_manager=dolphin \
  gui_editor=kate,zed browser=firefox

dolphin_before="$base/dolphinrc.before"
cp "$home/.config/dolphinrc" "$dolphin_before"
for variant in dark light; do
  out="$base/plan-$variant"
  theme_plan "$variant" "$base/all-roles.json" "$home" "$out" --adopt
  for unit in "${d06_units[@]}"; do
    status=$(theme_unit_status "$out" "$unit")
    [[ $status == ready || $status == unchanged ]] || fail "$variant $unit status $status: $(jq -c --arg id "$unit" '.units[] | select(.id == $id) | .reason' "$out/plan.json")"
  done
  bg=${expect_bg[$variant]} accent=${expect_accent[$variant]}

  nvim_colors=$(theme_candidate "$out" neovim nvim/colors/hss.lua)
  grep -Fxq "vim.o.background = \"$variant\"" "$nvim_colors" || fail "$variant nvim background"
  grep -Fxq "	bg = \"$bg\"," "$nvim_colors" || fail "$variant nvim palette"
  [[ $(grep -c '^vim.g.terminal_color_[0-9]* = "#' "$nvim_colors") == 16 ]] || fail "$variant nvim terminal colours"
  init_lua=$(theme_candidate "$out" neovim nvim/init.lua)
  grep -Fxq "	local dir = \"$home/.config/hss-theme/generated\" .. \"/nvim\"" "$init_lua" || fail "$variant init.lua region uses the generated path"
  region_line=$(grep -n '>>> hss-theme:neovim >>>' "$init_lua" | cut -d: -f1)
  tree_line=$(grep -n 'pcall(require, "nvim-tree")' "$init_lua" | cut -d: -f1)
  lazy_line=$(grep -n '^require("lazy").setup' "$init_lua" | cut -d: -f1)
  ((lazy_line < region_line && region_line < tree_line)) || fail "nvim region runs after lazy.nvim and before optional plugin setup"
  if command -v luac >/dev/null 2>&1; then
    luac -p "$nvim_colors" || fail "$variant nvim colorscheme syntax"
    luac -p "$init_lua" || fail "$variant init.lua syntax"
  fi

  grep -Fxq "theme = \"${expect_helix[$variant]}\"" "$(theme_candidate "$out" helix helix/config.toml)" || fail "$variant helix theme"

  vim_colors=$(theme_candidate "$out" vim vim/colors/hss.vim)
  grep -Fxq "set background=$variant" "$vim_colors" || fail "$variant vim background"
  grep -Eq "^hi Normal +guifg=#[0-9a-f]{6} guibg=$bg " "$vim_colors" || fail "$variant vim Normal"
  vimrc=$(theme_candidate "$out" vim vim/vimrc)
  [[ $(head -n1 "$vimrc") == 'set number' ]] || fail "vimrc user setting kept first"
  grep -Fq "fnameescape('$home/.config/hss-theme/generated/vim')" "$vimrc" || fail "$variant vim runtimepath region"

  python3 - "$(theme_candidate "$out" yazi yazi/flavors/hss.yazi/flavor.toml)" "$(theme_candidate "$out" yazi yazi/theme.toml)" "$accent" <<'PY' || fail "$variant yazi flavor"
import sys, tomllib
flavor = tomllib.load(open(sys.argv[1], "rb"))
theme = tomllib.load(open(sys.argv[2], "rb"))
assert flavor["mgr"]["cwd"] == {"fg": sys.argv[3]}
assert flavor["tabs"]["active"]["bg"] == sys.argv[3]
assert theme["flavor"] == {"dark": "hss", "light": "hss"}
PY

  mc_skin=$(theme_candidate "$out" mc mc/skins/hss-catppuccin.ini)
  grep -Fxq '    truecolors = true' "$mc_skin" || fail "mc skin is true colour"
  grep -Fxq "    Main = $bg" "$mc_skin" || fail "$variant mc background"
  grep -Fxq 'skin=hss-catppuccin' "$(theme_candidate "$out" mc mc/ini)" || fail "mc skin selected"

  grep -Eq "^highlight Directory .*ctermfg=blue .*guifg=$accent " "$(theme_candidate "$out" vifm vifm/colors/hss.vifm)" || fail "$variant vifm directory colour"
  vifmrc=$(theme_candidate "$out" vifm vifm/vifmrc)
  [[ $(head -n1 "$vifmrc") == 'set vicmd=nvim' ]] || fail "vifmrc user setting kept first"
  grep -Fxq 'colorscheme hss' "$vifmrc" || fail "vifm colorscheme region"

  [[ $(grep -c '^appearance.theme=blue on default$' "$(theme_candidate "$out" calcurse calcurse/conf)") == 1 ]] || fail "calcurse colour pair"

  khal=$(theme_candidate "$out" khal khal/config)
  awk '/^\[view\]$/ {getline; print; exit}' "$khal" | grep -Fxq "theme=$variant" || fail "$variant khal theme"
  grep -Fxq 'default_calendar = local' "$khal" || fail "khal calendars kept"

  python3 - "$(theme_candidate "$out" kde-color-scheme color-schemes/HSSCatppuccin.colors)" "$bg" <<'PY' || fail "$variant KDE colour scheme"
import configparser, sys
parser = configparser.ConfigParser(interpolation=None, strict=True)
parser.optionxform = str
parser.read(sys.argv[1], encoding="utf-8")
bg = sys.argv[2]
assert parser["Colors:View"]["BackgroundNormal"] == ",".join(str(int(bg[i:i + 2], 16)) for i in (1, 3, 5))
assert parser["General"]["Name"] == "HSS Catppuccin"
PY

  dolphinrc=$(theme_candidate "$out" dolphin dolphinrc)
  grep -Fxq 'ColorScheme=HSSCatppuccin' "$dolphinrc" || fail "dolphin colour scheme key"
  diff <(grep -v '^ColorScheme=' "$dolphin_before") <(grep -v '^ColorScheme=' "$dolphinrc") >/dev/null || fail "dolphin keys other than ColorScheme changed"
  grep -Fxq 'ColorScheme=HSSCatppuccin' "$(theme_candidate "$out" kate katerc)" || fail "kate colour scheme key"
done
[[ ! -e $base/calls ]] || fail "rendering ran an application: $(cat "$base/calls")"
printf 'ok - Neovim, Helix, Vim, Yazi, mc, vifm, Calcurse, Khal, Dolphin and Kate units render both variants without running any application\n'

# Activation is declared as data and never restarts an application.
[[ $(jq -c '.units[] | select(.id == "helix") | .activation' "$fragment") == '[{"kind":"signal","process":"helix","signal":"USR1"}]' ]] || fail "helix live reload"
[[ $(jq '[.units[].activation[] | select(.kind == "reload")] | length' "$fragment") == 0 ]] || fail "D06 units declare no reload commands"
printf 'ok - activation is next launch, except the native Helix SIGUSR1 reload\n'

# None states and unselected members.
make_member_roles "$base/none-roles.json" tui_editor=nano tui_file_manager= calendar=merkuro file_manager=thunar gui_editor= browser=chromium
theme_plan dark "$base/none-roles.json" "$home" "$base/plan-none" --adopt
for unit in "${d06_units[@]}"; do
  # kdeglobals names HSSCatppuccin as the KDE colour scheme, so that scheme is always generated.
  [[ $unit == kde-color-scheme ]] && continue
  [[ $(theme_unit_status "$base/plan-none" "$unit") == not-selected ]] || fail "$unit applies without a selected member"
done
[[ $(theme_unit_status "$base/plan-none" kde-color-scheme) == ready ]] || fail "the KDE colour scheme named by kdeglobals is always generated"
themed_elsewhere=$(jq -r '[.units[].applies.members[]?] | any(test("^(browser/.*|gui_editor/(zed|visual-studio-code-bin|cursor-bin|mousepad)|file_manager/(thunar|nautilus|nemo|pcmanfm-qt)|tui_file_manager/(ranger|lf|nnn)|tui_editor/nano|calendar/(merkuro|gnome-calendar|korganizer))$"))' "$fragment")
[[ $themed_elsewhere == false ]] || fail "native-constrained or terminal-inherited apps must not get D06 units"
printf 'ok - TUI file manager None, GUI editor None and toolkit/terminal-inherited members produce no D06 units\n'

# Files that are never created: init.lua (init.vim users), the XDG vimrc, vifmrc, khal config.
bare="$base/bare-home"
mkdir -p "$bare/.config/nvim"
printf 'set number\n' > "$bare/.config/nvim/init.vim"
theme_plan dark "$base/all-roles.json" "$bare" "$base/plan-bare" --adopt
for unit in neovim vim vifm khal; do
  [[ $(theme_unit_status "$base/plan-bare" "$unit") == not-adopted ]] || fail "$unit must not create its user configuration"
done
[[ $(jq -r '.units[] | select(.id == "neovim") | .outputs[] | select(.target | endswith("init.lua")) | .staged' "$base/plan-bare/plan.json") == null ]] \
  || fail "init.lua must not be created next to init.vim"
for unit in helix mc calcurse yazi kate dolphin; do
  [[ $(theme_unit_status "$base/plan-bare" "$unit") == ready ]] || fail "$unit creates only its own managed keys or region"
done
printf 'ok - init.lua, vimrc, vifmrc and khal configuration are never created; other units create only managed keys or regions\n'

# A user change to a managed key is preserved.
theme_commit "$base/plan-dark"
python3 "$theme_py" finalize --plan "$base/plan-dark/plan.json" --theme-root "$home/.config/hss-theme" \
  --applied "$(jq -r '[.units[] | select(.status == "ready") | .id] | join(",")' "$base/plan-dark/plan.json")" \
  --unchanged "$(jq -r '[.units[] | select(.status == "unchanged") | .id] | join(",")' "$base/plan-dark/plan.json")" \
  --out-managed "$base/managed.json" --out-state "$base/state.json"
mkdir -p "$home/.config/hss-theme"
cp "$base/managed.json" "$home/.config/hss-theme/managed.json"
sed -i 's/^ColorScheme=HSSCatppuccin$/ColorScheme=Breeze/' "$home/.config/dolphinrc"
sed -i 's/^theme = .*/theme = "onedark"/' "$home/.config/helix/config.toml"
theme_plan light "$base/all-roles.json" "$home" "$base/plan-after-edit"
for unit in dolphin helix; do
  [[ $(theme_unit_status "$base/plan-after-edit" "$unit") == skipped-conflict ]] || fail "$unit user edit is preserved"
done
[[ $(theme_unit_status "$base/plan-after-edit" neovim) == ready ]] || fail "independent units still switch"
printf 'ok - user changes to Dolphin or Helix theme keys are preserved while independent units switch\n'
