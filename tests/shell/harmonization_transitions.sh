#!/usr/bin/env bash
set -euo pipefail
# I01.4: theme transitions after setup adoption, through the installed runtime
# (providers/theme.sh as setup calls it, and action_exec.sh theme.* at runtime):
# fresh adoption with deferred activation, identical reruns, primary/member switches,
# option<->None for an optional role, dark<->light round trips with modeled activation,
# user divergence with partial outcomes, an injected write failure mid-commit recovered with
# `setup.sh --rollback RUN_ID`, and a foreign notification owner that is never touched.
# Evidence level: modeled-effect (real files in a private HOME with Stow-style links;
# pgrep/pkill/busctl/gsettings/notify-send/sync are stateful doubles; nothing is started).
# shellcheck source=tests/shell/harmonization_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/harmonization_testlib.sh"
ht_fixture_init

ht_stow_fixture hypr gtk-3.0 gtk-4.0 qt5ct qt6ct kdeglobals kitty swaync
dotconfig="$HOME/dotfiles/.config"
scripts="$XDG_CONFIG_HOME/hypr/scripts"
action="$scripts/action_exec.sh"
status_cmd="$scripts/status_read.sh"
theme_root="$XDG_CONFIG_HOME/hss-theme"
generated="$theme_root/generated"
runs="$XDG_STATE_HOME/hyprland-simple-setup/runs"
links=(hypr gtk-3.0 gtk-4.0 qt5ct qt6ct kdeglobals kitty swaync)

# Registry: the core units plus one terminal pair and one optional-role unit, so every
# transition is exercised without unrelated units turning the outcome partial.
units_d="$dotconfig/hypr/theme/units.d"
jq -s '{schema_version: 1, units: ([.[].units[]] | map(select(.id | IN("kitty", "alacritty", "swaync"))))}' \
    "$units_d/50-d05-terminal.json" "$units_d/30-d03-notifications.json" > "$HT_ROOT/90-i01.json"
rm -f -- "$units_d"/*.json
cp -- "$HT_ROOT/90-i01.json" "$units_d/90-i01.json"
python3 -B "$dotconfig/hypr/theme/hss_theme.py" check >/dev/null || ht_fail "the transition registry was rejected"

export HSS_ROLES_FILE="$HT_ROOT/roles.json"
roles() {
    ht_write_roles "$HSS_ROLES_FILE" "$@"
}
roles terminal=kitty notifications=swaync

# sync double: fails for a path containing the pattern in $HT_STATE/sync-fail, which models a
# write failure in the middle of a batch commit (write_file_atomic syncs every candidate).
ht__write_double sync <<'BODY'
if [[ -s $state/sync-fail ]]; then
    pattern=$(<"$state/sync-fail")
    for arg; do
        [[ $arg != *"$pattern"* ]] || exit 1
    done
fi
exit 0
BODY
ht_double swaync-client

latest_run() {
    cat -- "$XDG_STATE_HOME/hyprland-simple-setup/latest-run"
}
latest_report() {
    printf '%s/%s/theme-report.json\n' "$runs" "$(latest_run)"
}
assert_links_intact() {
    local name
    for name in "${links[@]}"; do
        [[ -L $XDG_CONFIG_HOME/$name && $(readlink -- "$XDG_CONFIG_HOME/$name") == "$dotconfig/$name" ]] \
            || ht_fail "Stow link $name no longer points into dotfiles"
    done
}
# theme ARG...: action_exec.sh --json ARG...; the envelope is in $HT_STDOUT.
theme() {
    ht_run "$action" --json "$@"
}
show() {
    cat -- "$HT_STDOUT" "$HT_STDERR" >&2
    ht_fail "$1"
}
expect_theme() {
    local status=$1 filter=$2 label=$3
    [[ $HT_STATUS == "$status" ]] || show "$label: exit $HT_STATUS, expected $status"
    jq -e "$filter" "$HT_STDOUT" >/dev/null 2>&1 || show "$label: envelope does not satisfy $filter"
}
snapshot_all() {
    ht_snapshot_tree "$HOME/dotfiles"
    ht_snapshot_tree "$generated"
}
assert_all_unchanged() {
    assert_tree_unchanged "$HOME/dotfiles" "dotfiles $1"
    assert_tree_unchanged "$generated" "generated theme files $1"
}
# The theme bookkeeping is the only thing an unchanged run may record.
assert_only_bookkeeping() {
    local path
    while IFS=$'\t' read -r _ path _; do
        case "$path" in
            "$theme_root/managed.json"|"$theme_root/state.json") ;;
            *) ht_fail "$1 rewrote $path" ;;
        esac
    done < "$runs/$(latest_run)/manifest.tsv"
}
rollback() {
    ht_run env NON_INTERACTIVE=true "$HT_REPO_ROOT/setup.sh" --rollback "$1" </dev/null
}
no_atomic_leftovers() {
    local leftover
    leftover=$(find -L "$HOME/dotfiles" "$theme_root" -name '.hss-atomic.*' -print -quit 2>/dev/null || true)
    [[ -z $leftover ]] || ht_fail "a failed commit left a temporary file: $leftover"
}

kitty_conf="$dotconfig/kitty/kitty.conf"
kitty_theme="$generated/kitty/theme.conf"
alacritty_theme="$generated/alacritty/theme.toml"
swaync_css="$dotconfig/swaync/style.css"

# ---------------------------------------------------------------------------
# 1. Fresh adoption without a graphical session: deferred activation, not a false success.

ht_theme_apply "$scripts" dark --adopt
assert_status 0 "fresh adoption"
assert_json "$HT_STDOUT" '.outcome == "completed" and .reason == "theme dark applied"
    and (.observed.applied | sort) == ["desktop-fonts-cursor","gtk3","gtk4","kdeglobals","kitty","qt5ct","qt6ct","theme-core"]
    and .observed.skipped == [] and .observed.failed == []' "fresh adoption result"
# The shipped SwayNC style already carries the dark region, so it is adopted as unchanged.
assert_json "$(jq -r .report "$HT_STDOUT")" '.unchanged == ["swaync"]' "SwayNC adopted unchanged"
assert_json "$HT_STDOUT" '.pending | contains("applies after the next login")' "deferred activation is reported"
assert_json "$theme_root/state.json" '.variant == "dark" and .batch == "complete"'
assert_contains "$(cat "$kitty_conf")" "include $kitty_theme" "Kitty region includes the generated theme"
[[ -f $kitty_theme && ! -e $alacritty_theme ]] || ht_fail "only the selected terminal is rendered"
assert_eq "" "$(ht_signals)" "signals without running applications"
assert_calls swaync-client 0 "SwayNC reloads without a running SwayNC"
assert_links_intact
ht_ok "fresh adoption themes the selected members and reports activation as deferred without a session"

# ---------------------------------------------------------------------------
# 2. Identical reruns change nothing, through setup's entry and through the runtime action.

snapshot_all
ht_theme_apply "$scripts" dark --adopt
assert_status 0 "identical setup rerun"
assert_json "$HT_STDOUT" '.outcome == "completed" and .observed.applied == [] and .observed.skipped == []' "identical setup rerun"
assert_only_bookkeeping "an identical setup rerun"
assert_all_unchanged "after an identical setup rerun"
theme theme.apply
expect_theme 0 '.outcome == "completed" and .observed.applied == [] and .observed.variant == "dark"' "identical runtime rerun"
assert_only_bookkeeping "an identical runtime rerun"
assert_all_unchanged "after an identical runtime rerun"
assert_eq "" "$(ht_signals)" "signals after identical reruns"
ht_ok "identical reruns are stable: no output changes and only theme bookkeeping is recorded"

# ---------------------------------------------------------------------------
# 3. Primary/member switches and option<->None for the notifications role.

ht_snapshot "$kitty_conf" "$kitty_theme" "$swaync_css"
roles terminal=alacritty,kitty notifications=swaync
theme theme.apply
expect_theme 0 '.outcome == "completed" and .observed.applied == ["alacritty"]' "new primary terminal"
[[ -f $alacritty_theme ]] || ht_fail "the new primary terminal was not rendered"
assert_file_unchanged "$kitty_conf" "Kitty config while Kitty stays a member"
assert_file_unchanged "$kitty_theme" "Kitty theme while Kitty stays a member"

roles terminal=alacritty notifications=
theme theme.apply
expect_theme 0 '.outcome == "completed" and .observed.applied == [] and .observed.skipped == []' "deselecting Kitty and SwayNC"
assert_file_unchanged "$kitty_conf" "deselected Kitty config"
assert_file_unchanged "$kitty_theme" "deselected Kitty theme"
assert_file_unchanged "$swaync_css" "SwayNC style after selecting None"
snapshot_all
theme theme.apply
expect_theme 0 '.outcome == "completed" and .observed.applied == []' "repeated None"
assert_all_unchanged "after repeating None"

# A variant switch while they are deselected leaves their files alone.
ht_snapshot "$alacritty_theme"
theme theme.toggle
expect_theme 0 '.outcome == "completed" and .observed.variant == "light" and (.observed.applied | index("alacritty")) != null
    and (.observed.applied | index("kitty")) == null and (.observed.applied | index("swaync")) == null' "switch while deselected"
assert_file_unchanged "$kitty_conf" "deselected Kitty config after a variant switch"
assert_file_unchanged "$kitty_theme" "deselected Kitty theme after a variant switch"
assert_file_unchanged "$swaync_css" "SwayNC style after a variant switch with None"
ht_expect_failure assert_file_unchanged "$alacritty_theme"

# Selecting them again renders them for the current variant; Alacritty's file is kept.
roles terminal=kitty notifications=swaync
theme theme.apply
expect_theme 0 '.outcome == "completed" and .observed.variant == "light" and .observed.skipped == []
    and (.observed.applied | sort) == ["kitty","swaync"]' "reselecting Kitty and SwayNC"
ht_expect_failure assert_file_unchanged "$kitty_theme"
ht_expect_failure assert_file_unchanged "$swaync_css"
[[ -f $alacritty_theme ]] || ht_fail "the deselected terminal's generated theme was deleted"
assert_links_intact
ht_ok "primary and member switches re-render only selected members; None and deselection keep files untouched"

# ---------------------------------------------------------------------------
# 4. Dark<->light round trip at runtime with modeled activation.

snapshot_all
ht_proc_start kitty
ht_proc_start swaync
theme theme.toggle
expect_theme 0 '.outcome == "completed" and .observed.variant == "dark" and .observed.skipped == []' "toggle to dark"
assert_eq 'kitty USR1' "$(ht_signals)" "Kitty reload signal"
assert_argv swaync-client 1 --reload-css --skip-wait
assert_json "$theme_root/state.json" '.variant == "dark" and .batch == "complete"'
grep -qx 'gtk-application-prefer-dark-theme=1' "$dotconfig/gtk-3.0/settings.ini" || ht_fail "dark GTK preference was not written"
theme theme.set light
expect_theme 0 '.outcome == "completed" and .observed.variant == "light"' "set light"
assert_all_unchanged "after a dark and back to light round trip"
assert_calls swaync-client 2 "SwayNC reloads after two switches"
ht_proc_stop kitty
ht_proc_stop swaync
ht_run "$status_cmd" theme
assert_json "$HT_STDOUT" '.state.variant == "light" and .state.batch == "complete" and .state.partial_units == []' "theme status"
assert_calls notify-send 0 "notifications for complete switches"
ht_ok "theme.toggle and theme.set switch variants byte-for-byte reversibly and reload only running applications"

# ---------------------------------------------------------------------------
# 5. User divergence: an edited theme region is preserved, the rest still applies.

cp -- "$kitty_conf" "$HT_ROOT/kitty.conf.managed"
sed -i 's|^include .*/kitty/theme.conf$|include ~/my-kitty-colors.conf|' "$kitty_conf"
grep -qx 'include ~/my-kitty-colors.conf' "$kitty_conf" || ht_fail "fixture edit of the Kitty region did not apply"
ht_snapshot "$kitty_conf" "$kitty_theme"
ht_run "$action" theme.toggle
assert_status 0 "switch with a user-edited region"
assert_eq 0 "$(wc -c < "$HT_STDOUT")" "non-JSON stdout bytes"
assert_json "$(latest_report)" '.variant == "dark"
    and ([.skipped[] | {id, status}]) == [{"id":"kitty","status":"skipped-conflict"}]
    and (.applied | index("swaync")) != null and (.applied | index("gtk3")) != null and .failed == []' "partial report"
assert_file_unchanged "$kitty_conf" "user-edited Kitty config"
assert_file_unchanged "$kitty_theme" "skipped Kitty theme"
assert_eq 1 "$(ht_calls notify-send)" "partial-application notification"
assert_argv notify-send 1 -a 'Hyprland Simple Setup' -u normal -- 'Theme partially applied' \
    'Some configuration files had local edits and were preserved. Rerun setup to review them.'
ht_run "$status_cmd" theme
assert_json "$HT_STDOUT" '.state.variant == "dark" and .state.batch == "partial" and .state.partial_units == ["kitty"]' "partial status"

# Undoing the edit makes the unit managed again on the next switch.
cp -- "$HT_ROOT/kitty.conf.managed" "$kitty_conf"
theme theme.set dark
expect_theme 0 '.outcome == "completed" and .reason == "theme dark applied" and .observed.applied == ["kitty"]' "after undoing the edit"
assert_json "$theme_root/state.json" '.batch == "complete"'
ht_ok "a user-edited region is skipped as a conflict, other units apply and the partial outcome is reported"

# ---------------------------------------------------------------------------
# 6. Injected write failure in the middle of a commit, then setup.sh --rollback RUN_ID.

before_dotfiles=$(ht_tree_listing "$HOME/dotfiles")
before_theme=$(ht_tree_listing "$theme_root")
ht_snapshot "$dotconfig/gtk-4.0/settings.ini" "$dotconfig/gtk-4.0/gtk.css" "$generated/gtk-4.0/colors.css"
printf '/gtk-4.0/' > "$HT_STATE/sync-fail"
theme theme.toggle
rm -f -- "$HT_STATE/sync-fail"
expect_theme 1 '.outcome == "failed" and (.reason | contains("gtk4"))' "switch with a failing write"
failed_run=$(latest_run)
assert_json "$(latest_report)" '.failed == ["gtk4"] and (.applied | index("gtk3")) != null
    and (.applied | index("qt6ct")) != null and (.applied | index("kitty")) != null' "failed report"
assert_file_unchanged "$dotconfig/gtk-4.0/settings.ini" "GTK 4 settings after a failed write"
assert_file_unchanged "$dotconfig/gtk-4.0/gtk.css" "GTK 4 CSS after a failed write"
assert_file_unchanged "$generated/gtk-4.0/colors.css" "GTK 4 palette after a failed write"
no_atomic_leftovers
ht_run "$status_cmd" theme
assert_json "$HT_STDOUT" '.state.variant == "light" and (.state.partial_units | index("gtk4")) != null' "status after a failed write"
assert_links_intact
ht_ok "a write failure mid-commit leaves the failing unit's files intact, applies the others and reports failed"

# A newer user edit to a file the failed run wrote blocks rollback; nothing is overwritten.
gtk3_ini="$dotconfig/gtk-3.0/settings.ini"
cp -- "$gtk3_ini" "$HT_ROOT/gtk3.after-failure"
printf 'gtk-user-later=1\n' >> "$gtk3_ini"
after_edit_dotfiles=$(ht_tree_listing "$HOME/dotfiles")
after_edit_theme=$(ht_tree_listing "$theme_root")
rollback "$failed_run"
[[ $HT_STATUS != 0 ]] || show "rollback overwrote a newer user edit"
assert_contains "$(cat "$HT_STDERR" "$HT_STDOUT")" "Digest mismatch: $gtk3_ini" "the edited file is reported"
assert_eq "$after_edit_dotfiles" "$(ht_tree_listing "$HOME/dotfiles")" "dotfiles after a refused rollback"
assert_eq "$after_edit_theme" "$(ht_tree_listing "$theme_root")" "theme state after a refused rollback"
grep -qx 'gtk-user-later=1' "$gtk3_ini" || ht_fail "the newer user edit was lost"
ht_ok "rollback refuses to overwrite a newer user edit and changes nothing"

# Without the newer edit the failed run rolls back to the exact pre-run files.
cp -- "$HT_ROOT/gtk3.after-failure" "$gtk3_ini"
rollback "$failed_run"
[[ $HT_STATUS == 0 ]] || ht_fail "rollback of the failed theme run: $(grep -h 'Digest mismatch\|Rollback' "$HT_STDERR" "$HT_STDOUT" | head -n1)"
assert_eq "$before_dotfiles" "$(ht_tree_listing "$HOME/dotfiles")" "dotfiles after rolling back the failed run"
assert_eq "$before_theme" "$(ht_tree_listing "$theme_root")" "theme state after rolling back the failed run"
ht_ok "setup.sh --rollback restores every file of a failed theme run"
assert_links_intact

# ---------------------------------------------------------------------------
# 7. A foreign notification owner is reported as a conflict and never touched.

sleep 300 &
foreign_pid=$!
ht_track_pid "$foreign_pid"
ht_dbus_own org.freedesktop.Notifications :1.77 "$foreign_pid"
ht_dbus_own org.freedesktop.DBus org.freedesktop.DBus 1
pkill_before=$(ht_calls pkill)
signals_before=$(ht_signals)
client_before=$(ht_calls swaync-client)
theme notifications.dismiss.all
expect_theme 10 '.outcome == "conflict" and (.reason | contains("sleep"))' "action with a foreign notification owner"
theme theme.toggle
expect_theme 0 '.outcome == "completed" and .observed.failed == []' "theme switch with a foreign notification owner"
kill -0 "$foreign_pid" 2>/dev/null || ht_fail "the foreign notification owner was terminated"
assert_calls pkill "$pkill_before" "pkill calls with a foreign owner"
assert_eq "$signals_before" "$(ht_signals)" "signals with a foreign owner"
assert_calls swaync-client "$client_before" "SwayNC client calls with a foreign owner"
ht_ok "a foreign notification owner yields exit 10, stays running and receives no signal or reload"
