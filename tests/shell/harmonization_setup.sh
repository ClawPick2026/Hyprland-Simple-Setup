#!/usr/bin/env bash
set -euo pipefail

# I01.3/I01.4: setup-time theme adoption, consent modes, keybinding conflicts and rollback.
# shellcheck source=tests/shell/roles_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/roles_testlib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

new_fixture() {
  fixture=$(mktemp -d)
  setup_role_fixture "$fixture"
  set_role_defaults
  for name in gtk-3.0 gtk-4.0 qt5ct qt6ct; do
    ln -s "$HOME/dotfiles/.config/$name" "$HOME/.config/$name"
  done
  ln -s "$HOME/dotfiles/.config/kdeglobals" "$HOME/.config/kdeglobals"
  unset HSS_THEME_VARIANT HSS_HARMONIZATION_ADOPT
}

run_scenario() {
  "$repo_root/setup.sh" --test-scenario harmonization > "$fixture/out" 2>&1
}

digest() {
  sha256sum -- "$1" | cut -d' ' -f1
}

cleanup() {
  [[ -z ${fixture:-} ]] || rm -rf -- "$fixture"
}
trap cleanup EXIT

# 1. An existing installation that never adopted the theme only previews.
new_fixture
before=$(digest "$HOME/dotfiles/.config/gtk-3.0/settings.ini")
run_scenario || { cat "$fixture/out" >&2; fail 'preview scenario exits 0'; }
[[ $(digest "$HOME/dotfiles/.config/gtk-3.0/settings.ini") == "$before" ]] || fail 'preview leaves GTK settings unchanged'
[[ ! -e $HOME/.config/hss-theme/state.json ]] || fail 'preview writes no theme state'
grep -q 'Preview for dark' "$fixture/out" || { cat "$fixture/out" >&2; fail 'preview prints the planned units'; }
latest=$(cat "$XDG_STATE_HOME/hyprland-simple-setup/latest-run")
[[ -s $XDG_STATE_HOME/hyprland-simple-setup/runs/$latest/theme-report.json ]] || fail 'preview report is stored in the setup run'
printf 'ok - existing installations preview without changing configuration\n'

# 2. Explicit adoption applies the theme through the setup run; rollback restores it.
export HSS_HARMONIZATION_ADOPT=apply
run_scenario || { cat "$fixture/out" >&2; fail 'apply scenario exits 0'; }
[[ -L $HOME/.config/gtk-3.0 ]] || fail 'Stow directory link is preserved'
grep -qx 'gtk-cursor-theme-name=BreezeX-RosePine-Linux' "$HOME/dotfiles/.config/gtk-3.0/settings.ini" || fail 'GTK cursor uses the Xcursor fallback'
grep -qx 'gtk-xft-dpi=113049' "$HOME/dotfiles/.config/gtk-3.0/settings.ini" || fail 'unmanaged GTK keys are preserved'
[[ $(jq -r .variant "$HOME/.config/hss-theme/state.json") == dark ]] || fail 'dark is the default variant'
grep -q 'hss-theme:gtk3' "$HOME/dotfiles/.config/gtk-3.0/gtk.css" || fail 'GTK 3 region is adopted'
grep -q 'XCURSOR_THEME", "BreezeX-RosePine-Linux"' "$HOME/dotfiles/.config/hypr/sources/environment_variables.lua" || fail 'stock Xcursor line is migrated'
[[ $(grep -c 'hss-theme:toggle-binding' "$HOME/dotfiles/.config/hypr/sources/keybindings.lua") == 1 ]] || fail 'theme binding is present exactly once'
run=$(cat "$XDG_STATE_HOME/hyprland-simple-setup/latest-run")
grep -q "$HOME/dotfiles/.config/gtk-3.0/settings.ini" "$XDG_STATE_HOME/hyprland-simple-setup/runs/$run/manifest.tsv" || fail 'theme writes are recorded in the setup manifest'
HSS_RELIABILITY_ACTION=rollback HSS_ROLLBACK_RUN_ID=$run "$repo_root/setup.sh" --test-scenario reliability >/dev/null 2>&1 || fail 'setup rollback restores the theme run'
[[ $(digest "$HOME/dotfiles/.config/gtk-3.0/settings.ini") == "$before" ]] || fail 'rollback restores GTK settings'
printf 'ok - explicit adoption applies through the setup run and rolls back\n'

# 3. A previously adopted installation keeps applying selection changes by default.
run_scenario || fail 'readoption exits 0'
unset HSS_HARMONIZATION_ADOPT
export HSS_THEME_VARIANT=light
run_scenario || { cat "$fixture/out" >&2; fail 'adopted rerun exits 0'; }
[[ $(jq -r .variant "$HOME/.config/hss-theme/state.json") == light ]] || fail 'adopted installs apply the requested variant'
grep -qx 'gtk-theme-name=Breeze' "$HOME/dotfiles/.config/gtk-3.0/settings.ini" || fail 'light variant uses Breeze'
printf 'ok - adopted installations apply later selection and variant changes\n'

# 4. Invalid input fails before writes; skip changes nothing.
export HSS_THEME_VARIANT=purple
before=$(digest "$HOME/dotfiles/.config/gtk-3.0/settings.ini")
if run_scenario; then fail 'invalid variant is rejected'; fi
[[ $(digest "$HOME/dotfiles/.config/gtk-3.0/settings.ini") == "$before" ]] || fail 'invalid variant writes nothing'
export HSS_THEME_VARIANT=dark HSS_HARMONIZATION_ADOPT=skip
run_scenario || fail 'skip exits 0'
[[ $(digest "$HOME/dotfiles/.config/gtk-3.0/settings.ini") == "$before" ]] || fail 'skip writes nothing'
printf 'ok - invalid variants fail and skip leaves configuration alone\n'
cleanup

# 5. A user binding on Super+Shift+T is preserved and reported.
new_fixture
grep -v 'hss-theme:toggle-binding' "$HOME/dotfiles/.config/hypr/sources/keybindings.lua" > "$fixture/keys"
printf '%s\n' 'bind(main_mod .. " + SHIFT + T", "My Terminal", hl.dsp.exec_cmd("foot"))' >> "$fixture/keys"
cp -- "$fixture/keys" "$HOME/dotfiles/.config/hypr/sources/keybindings.lua"
export HSS_HARMONIZATION_ADOPT=apply
run_scenario || { cat "$fixture/out" >&2; fail 'conflict scenario exits 0'; }
grep -q 'My Terminal' "$HOME/dotfiles/.config/hypr/sources/keybindings.lua" || fail 'custom binding is preserved'
! grep -q 'hss-theme:toggle-binding' "$HOME/dotfiles/.config/hypr/sources/keybindings.lua" || fail 'conflicting theme binding is not added'
grep -q 'Super+Shift+T is already bound' "$fixture/out" || fail 'binding conflict is reported'
printf 'ok - custom Super+Shift+T bindings are detected and preserved\n'
