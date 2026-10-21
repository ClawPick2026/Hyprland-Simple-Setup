#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # Subshells deliberately isolate exported test state.
set -euo pipefail

# Regressions for the reviewed theme-transaction defects (F02.5/F03.3): shared files and
# symlink aliases, dependency order, duplicate keys, line endings, unreadable targets,
# runtime consent, preview privacy, removed keys, custom XDG roots, partial writes, the
# --json usage envelope, TOML multi-line strings, unadopted-region validation and scoped
# automatic adoption.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

cleanup() {
  [[ -z ${root:-} ]] || { chmod -R u+w -- "$root" 2>/dev/null || true; rm -rf -- "$root"; }
}
trap cleanup EXIT

# Fresh fixture: dotfiles copy with Stow-like directory links and a gsettings double.
new_home() {
  cleanup
  root=$(mktemp -d)
  export HOME=$root/home XDG_CONFIG_HOME=$root/home/.config XDG_STATE_HOME=$root/state XDG_DATA_HOME=$root/home/.local/share
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$root/bin"
  cp -a -- "$repo_root/dotfiles" "$HOME/dotfiles"
  local name
  for name in hypr gtk-3.0 gtk-4.0 qt5ct qt6ct; do
    ln -s "$HOME/dotfiles/.config/$name" "$XDG_CONFIG_HOME/$name"
  done
  ln -s "$HOME/dotfiles/.config/kdeglobals" "$XDG_CONFIG_HOME/kdeglobals"
  cat > "$root/bin/gsettings" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GSETTINGS_LOG"
case "$1" in writable) printf 'true\n' ;; get) printf "'old'\n" ;; esac
STUB
  chmod +x "$root/bin/gsettings"
  export GSETTINGS_LOG=$root/gsettings.log PATH="$root/bin:$PATH"
  : > "$GSETTINGS_LOG"
  scripts=$XDG_CONFIG_HOME/hypr/scripts
}

# Run the theme provider in a subshell; prints "OUTCOME|REASON".
apply_theme() {
  (
    set +e
    export HSS_SCRIPTS_DIR=$scripts HSS_ACTION_NOTIFY=0
    # shellcheck source=/dev/null
    source "$scripts/lib/hss_runtime.sh"
    # shellcheck source=/dev/null
    source "$scripts/providers/theme.sh"
    hss_theme_apply "$@"
    printf '%s|%s\n' "$HSS_OUTCOME" "$HSS_REASON"
  )
}

unit_state() {
  jq -r --arg unit "$1" '.units[$unit]' "$XDG_CONFIG_HOME/hss-theme/state.json"
}

# 1. Two units claiming one file are rejected by the registry.
new_home
theme_copy=$root/theme
cp -a -- "$HOME/dotfiles/.config/hypr/theme" "$theme_copy"
mkdir -p "$theme_copy/units.d"
cat > "$theme_copy/units.d/90-test.json" <<'JSON'
{"schema_version": 1, "units": [
 {"id": "app-a", "owner": "T", "applies": {"always": true}, "outputs": [{"target": "config:app/app.conf", "class": "managed-region", "comment": "#", "content": "a", "create_if_missing": true}]},
 {"id": "app-b", "owner": "T", "applies": {"always": true}, "outputs": [{"target": "home:.config/app/app.conf", "class": "managed-region", "comment": "#", "content": "b", "create_if_missing": true}]}
]}
JSON
if python3 "$theme_copy/hss_theme.py" check --tokens "$theme_copy/tokens.json" --registry "$theme_copy/units.json" > "$root/check.out" 2>&1; then
  fail 'two units sharing one file are rejected'
fi
grep -q 'also owned by app-a' "$root/check.out" || fail 'collision names the owning unit'
printf 'ok - one unit owns each target file\n'

# 2. A unit may edit one file twice; its outputs compose instead of overwriting each other.
cat > "$theme_copy/units.d/90-test.json" <<'JSON'
{"schema_version": 1, "units": [
 {"id": "app-z", "owner": "T", "applies": {"always": true}, "depends": ["app-y"], "outputs": [{"target": "config:app/z.conf", "class": "managed-region", "comment": "#", "content": "z", "create_if_missing": true}]},
 {"id": "app-y", "owner": "T", "applies": {"always": true}, "outputs": [
   {"target": "config:app/y.conf", "class": "managed-keys", "format": "kv", "create_if_missing": true, "keys": [{"key": "color", "value": "{{color.bg}}"}]},
   {"target": "config:app/y.conf", "class": "managed-region", "comment": "#", "content": "font={{font.mono_family}}", "create_if_missing": true}]}
]}
JSON
export HSS_THEME_DIR=$theme_copy
result=$(apply_theme dark --adopt)
[[ ${result%%|*} == completed ]] || fail "composed apply completes ($result)"
grep -qx 'color=#1e1e2e' "$XDG_CONFIG_HOME/app/y.conf" || fail 'first output of a unit survives the second'
grep -qx 'font=JetBrainsMono Nerd Font' "$XDG_CONFIG_HOME/app/y.conf" || fail 'second output of a unit is written'
printf 'ok - outputs of one unit compose on a shared file\n'
order=$(python3 "$theme_copy/hss_theme.py" plan --variant dark --home "$HOME" --config-home "$XDG_CONFIG_HOME" \
  --data-home "$XDG_DATA_HOME" --theme-root "$XDG_CONFIG_HOME/hss-theme" --staging "$root/stage" \
  --tokens "$theme_copy/tokens.json" --registry "$theme_copy/units.json" | jq -r '[.units[].id] | join(" ")')
[[ $order == *"app-y app-z"* ]] || fail "prerequisites are planned before dependents ($order)"
printf 'ok - dependency order does not depend on declaration order\n'
unset HSS_THEME_DIR

# 3. Symlink aliases between two units' files: the second unit is skipped, not silently merged.
new_home
rm -f -- "$HOME/dotfiles/.config/gtk-4.0/gtk.css"
ln -s ../gtk-3.0/gtk.css "$HOME/dotfiles/.config/gtk-4.0/gtk.css"
result=$(apply_theme dark --adopt)
grep -q 'hss-theme:gtk3' "$HOME/dotfiles/.config/gtk-3.0/gtk.css" || fail 'first unit keeps its region in an aliased file'
[[ $(unit_state gtk4) == skipped-conflict ]] || fail "aliased second unit is skipped ($(unit_state gtk4))"
[[ $(unit_state gtk3) == applied ]] || fail 'first unit still applies'
printf 'ok - symlink aliasing between units is reported, not overwritten\n'

# 4. Duplicate keys, CRLF line endings and form feeds survive managed-key edits.
new_home
printf '[Settings]\r\ngtk-theme-name=Adwaita\r\ngtk-xft-dpi=113049\r\nx=a\fb\r\ngtk-theme-name=Adwaita\r\n' \
  > "$HOME/dotfiles/.config/gtk-3.0/settings.ini"
apply_theme dark --adopt > /dev/null
settings=$HOME/dotfiles/.config/gtk-3.0/settings.ini
[[ $(grep -c 'gtk-theme-name=Breeze-Dark' "$settings") == 2 ]] || fail 'every duplicate managed key is updated'
grep -q $'gtk-xft-dpi=113049\r$' "$settings" || fail 'CRLF line endings are preserved'
grep -q $'x=a\fb' "$settings" || fail 'form feeds stay inside their line'
result=$(apply_theme light)
[[ $(unit_state gtk3) == applied ]] || fail "duplicate keys do not cause a false conflict ($result)"
printf 'ok - duplicate keys, CRLF and form feeds are handled\n'

# 5. A removed managed key is treated as a user edit at runtime.
sed -i '/gtk-icon-theme-name/d' "$settings"
apply_theme dark > /dev/null
[[ $(unit_state gtk3) == skipped-conflict ]] || fail 'removed managed key is a conflict'
printf 'ok - removing a managed key preserves the user edit\n'

# 6. A non-UTF-8 target fails only its own unit.
new_home
printf '[General]\nName=\xff\xfe\n' > "$HOME/dotfiles/.config/kdeglobals"
result=$(apply_theme dark --adopt)
[[ $(unit_state kdeglobals) == failed ]] || fail "non-UTF-8 target fails its unit ($result)"
[[ $(unit_state gtk3) == applied ]] || fail 'other units still apply'
printf 'ok - unreadable targets fail one unit, not the batch\n'

# 7. A write failing partway records the theme's own earlier writes.
new_home
chmod 555 "$HOME/dotfiles/.config/gtk-3.0"
result=$(apply_theme dark --adopt)
chmod 755 "$HOME/dotfiles/.config/gtk-3.0"
[[ ${result%%|*} == failed ]] || fail "partial unit write is reported as failed ($result)"
colors=$(readlink -f "$XDG_CONFIG_HOME/hss-theme/generated/gtk-3.0/colors.css")
jq -e --arg key "$colors" '.files[$key]' "$XDG_CONFIG_HOME/hss-theme/managed.json" >/dev/null \
  || fail 'outputs written before the failure are recorded'
result=$(apply_theme dark --adopt)
[[ $(unit_state gtk3) == applied ]] || fail "rerun after the failure applies without a false conflict ($result)"
printf 'ok - partial writes are recorded and recover on rerun\n'

# 8. Runtime switching needs prior adoption and never touches gsettings without it.
new_home
before=$(sha256sum "$HOME/dotfiles/.config/gtk-3.0/settings.ini")
out=$("$scripts/action_exec.sh" --json theme.toggle || true)
[[ $(jq -r .outcome <<<"$out") == unavailable ]] || fail "unadopted runtime toggle is unavailable ($out)"
[[ ! -s $GSETTINGS_LOG ]] || fail 'unadopted runtime toggle leaves gsettings alone'
[[ $(sha256sum "$HOME/dotfiles/.config/gtk-3.0/settings.ini") == "$before" ]] || fail 'unadopted toggle writes nothing'
printf 'ok - runtime switching requires adoption\n'

# 9. Preview keeps no staged copies of user configuration.
apply_theme dark --preview > /dev/null
if find "$XDG_STATE_HOME" -path '*theme.*' -name '*settings.ini' | grep -q .; then
  fail 'preview leaves staged user files behind'
fi
report=$(find "$XDG_STATE_HOME" -name theme-report.json | head -n1)
if [[ -z $report ]] || ! jq -e '.units | length > 0' "$report" >/dev/null; then
  fail 'preview report is written'
fi
printf 'ok - preview stores only the report\n'

# 10. Committed state: gsettings prior values are reported; variant follows the shared prerequisite.
apply_theme dark --adopt > /dev/null
latest=$(cat "$XDG_STATE_HOME/hyprland-simple-setup/latest-run")
report=$XDG_STATE_HOME/hyprland-simple-setup/runs/$latest/theme-report.json
jq -e '.gsettings_previous | length > 0' "$report" >/dev/null || fail 'previous gsettings values are recorded'
printf 'ok - previous gsettings values are reported\n'

# 11. A custom XDG_CONFIG_HOME inside HOME is an approved root.
new_home
mkdir -p "$HOME/xdg"
cp -a -- "$XDG_CONFIG_HOME/." "$HOME/xdg/"
export XDG_CONFIG_HOME=$HOME/xdg
scripts=$XDG_CONFIG_HOME/hypr/scripts
result=$(apply_theme dark --adopt)
[[ ${result%%|*} == completed ]] || fail "custom XDG_CONFIG_HOME inside HOME works ($result)"
[[ -s $HOME/xdg/hss-theme/state.json ]] || fail 'state is written under the custom root'
printf 'ok - custom XDG_CONFIG_HOME inside HOME is supported\n'

# 12. --json reports usage errors as an envelope.
out=$("$scripts/action_exec.sh" --json no.such.action || true)
[[ $(jq -r '.outcome + ":" + (.exit_status | tostring)' <<<"$out") == usage:2 ]] || fail "unknown action yields a usage envelope ($out)"
out=$("$scripts/action_exec.sh" --json 'Bad Name' || true)
[[ $(jq -r .outcome <<<"$out") == usage ]] || fail 'invalid action names yield a usage envelope'
printf 'ok - usage errors produce a JSON envelope\n'

# 13. TOML managed keys ignore look-alike lines inside multi-line strings.
toml_result=$(python3 -B - "$repo_root/dotfiles/.config/hypr/theme" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import hss_theme
text = 'format = """\n[x](bold)\npalette = "inside"\n"""\npalette = "old"\n[table]\npalette = "t"\n'
edited = hss_theme.edit_kv(text, [("", "palette", '"new"')], True)
assert 'palette = "inside"' in edited and 'palette = "new"' in edited and 'palette = "t"' in edited, edited
assert hss_theme.read_kv_value(text, "palette", True) == '"old"'
print("ok")
PY
) || fail 'TOML multi-line strings are skipped'
[[ $toml_result == ok ]] || fail 'TOML multi-line strings are skipped'
printf 'ok - TOML multi-line strings are not edited as keys\n'

# 14. A region that has not been adopted is reported as not adopted, not validated.
new_home
rm -f "$HOME/dotfiles/.config/gtk-3.0/gtk.css"
printf '/* user rule with a stray brace */\n}\n' > "$HOME/dotfiles/.config/gtk-3.0/gtk.css"
(
  set +e
  export HSS_SCRIPTS_DIR=$scripts HSS_ACTION_NOTIFY=0
  # shellcheck source=/dev/null
  source "$scripts/lib/hss_runtime.sh"
  # shellcheck source=/dev/null
  source "$scripts/providers/theme.sh"
  hss_theme_apply dark --preview >/dev/null
  [[ -n ${HSS_THEME_REPORT:-} && -r $HSS_THEME_REPORT ]] || exit 1
  jq -r '.units[] | select(.id == "gtk3") | .status' "$HSS_THEME_REPORT"
) > "$root/gtk3-status" || fail 'preview report is readable'
[[ $(cat "$root/gtk3-status") == not-adopted ]] || fail "unadopted region skips validation ($(cat "$root/gtk3-status"))"
printf 'ok - unadopted regions are not validated\n'

# 15. Automatic adoption is scoped: a user file outside ~/dotfiles is not taken over.
new_home
rm -f "$XDG_CONFIG_HOME/kdeglobals"
printf '[General]\nfont=My Font,10\n' > "$XDG_CONFIG_HOME/kdeglobals"
user_kdeglobals=$(sha256sum < "$XDG_CONFIG_HOME/kdeglobals")
result=$(HSS_THEME_ADOPT_SCOPE=$HOME/dotfiles apply_theme dark --adopt)
[[ $(sha256sum < "$XDG_CONFIG_HOME/kdeglobals") == "$user_kdeglobals" ]] || fail "scoped adoption changed a user file outside ~/dotfiles ($result)"
[[ $(unit_state kdeglobals) == not-adopted ]] || fail "user kdeglobals is reported as not adopted ($(unit_state kdeglobals))"
[[ $(unit_state gtk3) == applied ]] || fail "files under ~/dotfiles are still adopted ($(unit_state gtk3))"
result=$(apply_theme dark --adopt)
[[ $(unit_state kdeglobals) == applied ]] || fail "explicit adoption still takes over the user file ($result)"
printf 'ok - automatic adoption only takes over files under the adoption scope\n'
