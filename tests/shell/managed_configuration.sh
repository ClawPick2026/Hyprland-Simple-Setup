#!/usr/bin/env bash
set -euo pipefail
# F04.4: managed-configuration batch semantics (F02.5/F02.6) through providers/theme.sh in a
# fixture HOME with Stow-style links: preview and consent, adoption, variant switching, user
# conflicts with dependency skips, idempotent reruns, rollback, the setup lock and dry-run.
# Evidence level: modeled-effect (real files in a fixture HOME; no application is started).
# shellcheck source=tests/shell/harmonization_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/harmonization_testlib.sh"
ht_fixture_init

ht_stow_fixture hypr gtk-3.0 gtk-4.0 qt5ct qt6ct kdeglobals
scripts="$XDG_CONFIG_HOME/hypr/scripts"
action="$scripts/action_exec.sh"
status_cmd="$scripts/status_read.sh"
dotconfig="$HOME/dotfiles/.config"
# Foundation suite: only the core theme registry; domain units.d fragments have their own suites.
rm -rf -- "$dotconfig/hypr/theme/units.d"
theme_root="$XDG_CONFIG_HOME/hss-theme"
runs="$XDG_STATE_HOME/hyprland-simple-setup/runs"
export HSS_ROLES_FILE="$HT_ROOT/roles.json"
ht_write_roles "$HSS_ROLES_FILE"
ht_gsettings_seed org.gnome.desktop.interface gtk-theme "'Adwaita'"

# User content that must survive adoption: a comment, an unrelated key and unrelated sections.
gtk3_ini="$dotconfig/gtk-3.0/settings.ini"
{ printf '# user comment: keep me\n'; cat -- "$gtk3_ini"; printf 'gtk-user-extra=kept\n'; } > "$HT_ROOT/settings.tmp"
mv -- "$HT_ROOT/settings.tmp" "$gtk3_ini"
printf '\n; trailing user comment\n' >> "$dotconfig/kdeglobals"

user_targets=(
    "$XDG_CONFIG_HOME/gtk-3.0/settings.ini" "$XDG_CONFIG_HOME/gtk-3.0/gtk.css"
    "$XDG_CONFIG_HOME/gtk-4.0/settings.ini" "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    "$XDG_CONFIG_HOME/qt5ct/qt5ct.conf" "$XDG_CONFIG_HOME/qt6ct/qt6ct.conf" "$XDG_CONFIG_HOME/kdeglobals"
)
links=(hypr gtk-3.0 gtk-4.0 qt5ct qt6ct kdeglobals)

driver() {
    ht_theme_apply "$scripts" "$@"
}
latest_run() {
    cat -- "$XDG_STATE_HOME/hyprland-simple-setup/latest-run"
}
assert_links_intact() {
    local name
    for name in "${links[@]}"; do
        [[ -L $XDG_CONFIG_HOME/$name && $(readlink -- "$XDG_CONFIG_HOME/$name") == "$dotconfig/$name" ]] \
            || ht_fail "Stow link $name no longer points into dotfiles"
    done
}
save_copies() {
    local dest=$1 target
    mkdir -p -- "$dest"
    for target in "${user_targets[@]}"; do
        cp -- "$(readlink -f -- "$target")" "$dest/$(printf '%s' "$target" | sha256sum | cut -c1-16)"
    done
}
copy_of() {
    printf '%s/%s\n' "$1" "$(printf '%s' "$2" | sha256sum | cut -c1-16)"
}
rollback() {
    HSS_TEST_MODE=1 NON_INTERACTIVE=true HSS_RELIABILITY_ACTION=rollback HSS_ROLLBACK_RUN_ID=$1 \
        "$HT_REPO_ROOT/setup.sh" --test-scenario reliability >"$HT_ROOT/rollback.out" 2>&1 \
        || { cat -- "$HT_ROOT/rollback.out" >&2; ht_fail "rollback of $1 failed"; }
}
manifest_paths() {
    cut -f2 -- "$runs/$1/manifest.tsv"
}
assert_run_tmp_clean() {
    [[ -z $(find "$runs/$1/tmp" -mindepth 1 -print -quit 2>/dev/null) ]] \
        || ht_fail "run $1 left temporary files: $(find "$runs/$1/tmp" -mindepth 1 | head -n3)"
}

# ---------------------------------------------------------------------------
# Preview and missing consent

ht_snapshot_tree "$HOME/dotfiles"
ht_snapshot_tree "$XDG_CONFIG_HOME"
driver dark --preview
assert_status 0 "preview exit status"
assert_json "$(cat "$HT_STDOUT")" '.outcome == "completed"
    and ([.observed.units[] | select(.status == "not-adopted") | .id] | sort) == ["gtk3","gtk4","kdeglobals","qt5ct","qt6ct"]
    and ([.observed.units[] | select(.id == "theme-core") | .status] == ["ready"])' "preview report"
preview_run=$(jq -r .run "$HT_STDOUT")
[[ -f $runs/$preview_run/theme-report.json && $(jq -r .report "$HT_STDOUT") == "$runs/$preview_run/theme-report.json" ]] \
    || ht_fail "preview report is not stored in its run directory"
assert_tree_unchanged "$HOME/dotfiles" "dotfiles after preview"
assert_tree_unchanged "$XDG_CONFIG_HOME" "configuration after preview"
[[ ! -s $runs/$preview_run/manifest.tsv ]] || ht_fail "preview recorded writes"
assert_run_tmp_clean "$preview_run"
assert_calls pkill 0
assert_calls gsettings 0
ht_ok "preview writes only its report into the run directory and reports existing files as not-adopted"

# Contract section 8: runtime switching requires an installation that setup adopted; otherwise
# the outcome is unavailable and nothing changes, including desktop settings.
gsettings_before_consent=$(ht_calls gsettings)
ht_run "$action" --json theme.set dark
assert_status 7 "runtime switch before adoption"
assert_json "$HT_STDOUT" '.outcome == "unavailable" and .exit_status == 7'
assert_tree_unchanged "$HOME/dotfiles" "dotfiles after a runtime switch before adoption"
assert_tree_unchanged "$XDG_CONFIG_HOME" "configuration after a runtime switch before adoption"
assert_calls gsettings "$gsettings_before_consent" "gsettings calls before adoption"
assert_links_intact
ht_ok "a runtime switch before adoption is unavailable and changes nothing"

# ---------------------------------------------------------------------------
# Adoption

before_adopt_dotfiles=$(ht_tree_listing "$HOME/dotfiles")
# Rollback deletes created files but keeps directories, so a missing root counts as empty.
before_adopt_theme=$(ht_tree_listing "$theme_root" | grep -vx missing || true)
save_copies "$HT_ROOT/before-adopt"
driver dark --adopt
assert_status 0 "adoption exit status"
assert_json "$(cat "$HT_STDOUT")" '.outcome == "completed" and .reason == "theme dark applied"
    and .observed.skipped == [] and .observed.failed == []' "adoption result"
adopt_run=$(jq -r .run "$HT_STDOUT")
assert_links_intact
assert_contains "$(cat "$gtk3_ini")" 'gtk-cursor-theme-name=BreezeX-RosePine-Linux' "adopted GTK 3 key"
assert_eq '# user comment: keep me' "$(head -n1 "$gtk3_ini")" "first line of the adopted GTK 3 file"
assert_contains "$(cat "$dotconfig/gtk-3.0/gtk.css")" '/* >>> hss-theme:gtk3 >>> */' "GTK 3 theme region"
assert_eq "@import 'colors.css';" "$(head -n1 "$dotconfig/gtk-3.0/gtk.css")" "user import before the region"
assert_contains "$(cat "$dotconfig/qt6ct/qt6ct.conf")" "color_scheme_path=$theme_root/generated/qt/colors.conf" "qt6ct palette path"
for target in "${user_targets[@]}"; do
    ht_assert_user_lines_preserved "$(copy_of "$HT_ROOT/before-adopt" "$target")" "$target" \
        "$theme_root/managed.json" "$target" "adoption of $target"
    canonical=$(readlink -f -- "$target")
    [[ $canonical == "$dotconfig"/* ]] || ht_fail "$target does not resolve into dotfiles"
    grep -Fq -- $'symlink-target\t'"$canonical"$'\t' "$runs/$adopt_run/manifest.tsv" \
        || ht_fail "manifest does not record $canonical as a symlink target"
done
[[ -L $XDG_CONFIG_HOME/kdeglobals && -f $dotconfig/kdeglobals ]] || ht_fail "kdeglobals file link was replaced"
assert_json "$theme_root/state.json" '.variant == "dark" and .batch == "complete"'
ht_ok "adoption edits only managed keys and regions through Stow links, preserving comments, order and unrelated keys"

# ---------------------------------------------------------------------------
# Variant switching changes only managed content

save_copies "$HT_ROOT/before-toggle"
ht_snapshot_tree "$HOME/dotfiles"
before_toggle_dotfiles=$(ht_tree_listing "$HOME/dotfiles")
before_toggle_theme=$(ht_tree_listing "$theme_root")
ht_run "$action" --json theme.toggle
assert_status 0 "toggle exit status"
assert_json "$HT_STDOUT" '.outcome == "completed" and .reason == "theme light applied" and .observed.variant == "light"'
toggle_run=$(latest_run)
mapfile -t changed < <(ht_tree_changes "$HOME/dotfiles")
expected_changes=(/.config/gtk-3.0/settings.ini /.config/gtk-4.0/settings.ini /.config/kdeglobals /.config/qt5ct/qt5ct.conf /.config/qt6ct/qt6ct.conf)
assert_eq "${expected_changes[*]}" "${changed[*]}" "dotfiles changed by a variant switch"
for target in "${user_targets[@]}"; do
    ht_assert_user_lines_preserved "$(copy_of "$HT_ROOT/before-toggle" "$target")" "$target" \
        "$theme_root/managed.json" "$target" "variant switch of $target"
done
grep -qx 'gtk-theme-name=Breeze' "$gtk3_ini" || ht_fail "light GTK theme name was not written"
grep -qx 'gtk-application-prefer-dark-theme=0' "$gtk3_ini" || ht_fail "light preference was not written"
assert_json "$theme_root/generated/palette.json" '.variant == "light"'
assert_links_intact
ht_ok "switching dark to light changes only managed keys, regions and generated files"

# ---------------------------------------------------------------------------
# Rollback restores each recorded run

rollback "$toggle_run"
assert_eq "$before_toggle_dotfiles" "$(ht_tree_listing "$HOME/dotfiles")" "dotfiles after rolling back the switch"
assert_eq "$before_toggle_theme" "$(ht_tree_listing "$theme_root")" "theme state after rolling back the switch"
rollback "$adopt_run"
assert_eq "$before_adopt_dotfiles" "$(ht_tree_listing "$HOME/dotfiles")" "dotfiles after rolling back the adoption"
assert_eq "$before_adopt_theme" "$(ht_tree_listing "$theme_root")" "theme state after rolling back the adoption"
assert_links_intact
ht_ok "setup.sh rollback restores a theme switch and then the adoption byte for byte"

# ---------------------------------------------------------------------------
# Idempotent rerun

driver dark --adopt
assert_status 0 "re-adoption"
ht_snapshot_tree "$HOME/dotfiles"
declare -A inode_before=()
mapfile -t generated_files < <(find "$theme_root/generated" -type f)
for target in "${user_targets[@]}" "${generated_files[@]}"; do
    inode_before[$target]=$(stat -L -c '%i %Y' -- "$target")
done
ht_run "$action" --json theme.set dark
assert_status 0 "unchanged rerun"
assert_json "$HT_STDOUT" '.outcome == "completed" and .observed.applied == [] and .observed.skipped == []'
rerun=$(latest_run)
while IFS= read -r path; do
    case "$path" in
        "$theme_root/managed.json"|"$theme_root/state.json") ;;
        *) ht_fail "unchanged rerun rewrote $path" ;;
    esac
done < <(manifest_paths "$rerun")
for target in "${!inode_before[@]}"; do
    assert_eq "${inode_before[$target]}" "$(stat -L -c '%i %Y' -- "$target")" "inode and mtime of $target"
done
assert_tree_unchanged "$HOME/dotfiles" "dotfiles after an unchanged rerun"
ht_ok "an unchanged rerun rewrites no target; only the theme bookkeeping may be recorded"

# ---------------------------------------------------------------------------
# A user-edited managed key preserves that unit and skips its dependents

qt6=$dotconfig/qt6ct/qt6ct.conf
sed -i 's/^icon_theme=.*/icon_theme=Papirus-Dark/' "$qt6"
ht_snapshot "$qt6" "$dotconfig/qt5ct/qt5ct.conf" "$theme_root/generated/qt/colors.conf"
notified=$(ht_calls notify-send)
ht_run "$action" theme.set light
assert_status 0 "partial switch exit status"
assert_eq 0 "$(wc -c < "$HT_STDOUT")" "non-JSON stdout bytes"
report="$runs/$(latest_run)/theme-report.json"
assert_json "$report" '.variant == "light"
    and ([.skipped[] | {id, status}] | sort_by(.id)) == [{"id":"qt5ct","status":"skipped-dependency"},{"id":"qt6ct","status":"skipped-conflict"}]
    and (.applied | sort) == ["gtk3","gtk4","kdeglobals","theme-core"]
    and .unchanged == ["desktop-fonts-cursor"]' "partial report"
assert_file_unchanged "$qt6" "conflicting qt6ct.conf"
assert_file_unchanged "$dotconfig/qt5ct/qt5ct.conf" "dependent qt5ct.conf"
assert_file_unchanged "$theme_root/generated/qt/colors.conf" "skipped unit's generated palette"
grep -qx 'gtk-theme-name=Breeze' "$gtk3_ini" || ht_fail "the independent GTK unit was not applied"
assert_eq $((notified + 1)) "$(ht_calls notify-send)" "partial-application notification"
assert_argv notify-send "$(ht_calls notify-send)" -a 'Hyprland Simple Setup' -u normal -- 'Theme partially applied' \
    'Some configuration files had local edits and were preserved. Rerun setup to review them.'
ht_run "$status_cmd" theme
assert_json "$HT_STDOUT" '.state.variant == "light" and .state.batch == "partial" and .state.partial_units == ["qt5ct","qt6ct"]'
ht_ok "a user-edited managed key skips only its unit and dependents while independent units apply"

# ---------------------------------------------------------------------------
# The setup lock and dry-run

ht_snapshot_tree "$HOME/dotfiles"
ht_snapshot_tree "$theme_root"
holder_out="$HT_ROOT/holder.out"
HSS_TEST_MODE=1 NON_INTERACTIVE=true HSS_RELIABILITY_ACTION=lock-hold HSS_HOLD_SECONDS=4 \
    "$HT_REPO_ROOT/setup.sh" --test-scenario reliability >"$holder_out" 2>&1 &
holder=$!
ht_track_pid "$holder"
for _ in {1..100}; do grep -q 'holder pid=' "$holder_out" 2>/dev/null && break; sleep 0.05; done
grep -q 'holder pid=' "$holder_out" || ht_fail "setup lock holder did not start"
ht_run "$action" --json theme.toggle
assert_status 10 "theme switch while setup holds the lock"
assert_json "$HT_STDOUT" '.outcome == "conflict" and .exit_status == 10'
wait "$holder" || ht_fail "setup lock holder failed: $(cat -- "$holder_out")"
assert_tree_unchanged "$HOME/dotfiles" "dotfiles while the setup lock was held"
assert_tree_unchanged "$theme_root" "theme state while the setup lock was held"
ht_ok "a held setup lock makes theme switching return conflict without writes"

gsettings_calls=$(ht_calls gsettings)
pkill_calls=$(ht_calls pkill)
DRY_RUN=true ht_run "$action" --json theme.set dark
assert_status 0 "dry-run exit status"
assert_tree_unchanged "$HOME/dotfiles" "dotfiles after dry-run"
assert_tree_unchanged "$theme_root" "theme state after dry-run"
assert_calls gsettings "$gsettings_calls" "gsettings calls during dry-run"
assert_calls pkill "$pkill_calls" "pkill calls during dry-run"
[[ ! -s $runs/$(latest_run)/manifest.tsv ]] || ht_fail "dry-run recorded writes"
ht_ok "DRY_RUN=true plans the switch without writing files or activating anything"
