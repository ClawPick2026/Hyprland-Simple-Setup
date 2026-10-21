#!/usr/bin/env bash
# shellcheck disable=SC2016  # Literal $HOME, $USER and $hyprscripts belong to the fixture text.
set -euo pipefail
# I01.3: harmonization inside setup.sh through its guarded entry points only
# (--test-scenario harmonization, --test-scenario reliability with HSS_RELIABILITY_ACTION
# sync-managed / autostart-extras / filepicker, and the public --rollback RUN_ID).
# Covers the installer-managed file list and its sync, dry runs, consent modes, the Waybar
# stock-style upgrade, the session line migrations, default handlers with rollback, a failed
# theme validation that is reported without aborting setup, and the absence of package
# installation while rendering. harmonization_setup.sh keeps the explicit preview/apply/skip,
# invalid-variant and Super+Shift+T conflict cases; this suite does not repeat them.
# Evidence level: modeled-effect (real files in a private HOME, doubles for host commands).
# shellcheck source=tests/shell/harmonization_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/harmonization_testlib.sh"
# shellcheck source=tests/shell/roles_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/roles_testlib.sh"
ht_fixture_init

managed_list="$HT_REPO_ROOT/scripts/lib/installer-managed-files.txt"
state_dir() { printf '%s\n' "$XDG_STATE_HOME/hyprland-simple-setup"; }
latest_run() { cat -- "$(state_dir)/latest-run"; }
manifest_of() { printf '%s/runs/%s/manifest.tsv\n' "$(state_dir)" "$1"; }

# new_install NAME: a private installed layout. ~/dotfiles is a copy of the repository
# dotfiles with sources/ created from sources_example/, and every ~/.config entry is a
# Stow-style link into it. Setup runs in HSS_TEST_MODE with the role defaults.
new_install() {
    local root="$HT_ROOT/$1" entry
    export HOME="$root/home"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
    export XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache" XDG_DATA_DIRS="$root/system"
    export STUB_LOG="$root/stub.log" STUB_LOGIN_SHELL_FILE="$root/login-shell" HSS_ETC_SHELLS="$root/shells"
    export HSS_TEST_MODE=1 NON_INTERACTIVE=true DISTRO=arch SELECTED_PACMAN_PACKAGES="" SELECTED_AUR_PACKAGES=""
    unset HSS_ROLES_FILE HSS_THEME_VARIANT HSS_HARMONIZATION_ADOPT HSS_DOTFILES_FRESH DRY_RUN HSS_HANDLERS_MODE
    mkdir -p -- "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_DIRS/applications"
    cp -a -- "$HT_REPO_ROOT/dotfiles" "$HOME/dotfiles"
    find "$HOME/dotfiles" -name __pycache__ -type d -prune -exec rm -rf -- {} +
    rm -rf -- "$HOME/dotfiles/.config/hypr/sources"
    cp -a -- "$HOME/dotfiles/.config/hypr/sources_example" "$HOME/dotfiles/.config/hypr/sources"
    for entry in "$HOME/dotfiles/.config/"*; do
        ln -s -- "$entry" "$XDG_CONFIG_HOME/${entry##*/}"
    done
    printf '%s\n' /usr/bin/fish /bin/bash /usr/bin/zsh > "$HSS_ETC_SHELLS"
    printf '%s\n' /bin/bash > "$STUB_LOGIN_SHELL_FILE"
    : > "$STUB_LOG"
    set_role_defaults
    # tests/stubs is ahead of the doubles after roles_testlib; keep the stateful doubles first.
    export PATH="$HT_BIN:$PATH"
}

# setup_scenario NAME [VAR=VALUE...]: run a guarded setup.sh test scenario.
setup_scenario() {
    local name=$1
    shift
    ht_run env "$@" "$HT_REPO_ROOT/setup.sh" --test-scenario "$name" </dev/null
}
harmonize() {
    setup_scenario harmonization "$@"
    cat -- "$HT_STDOUT" "$HT_STDERR" > "$HT_ROOT/last.out"
}
reliability() {
    local action=$1
    shift
    setup_scenario reliability HSS_RELIABILITY_ACTION="$action" "$@"
    cat -- "$HT_STDOUT" "$HT_STDERR" > "$HT_ROOT/last.out"
}
show_failure() {
    cat -- "$HT_ROOT/last.out" >&2
    ht_fail "$1"
}
out_has() {
    grep -Fq -- "$1" "$HT_ROOT/last.out" || show_failure "${2:-output lacks [$1]}"
}
# Setup must never install packages while it renders or migrates configuration.
assert_no_package_installation() {
    local installs
    installs=$(grep -E '^(pacman|yay|makepkg)( |$)' "$STUB_LOG" | grep -E -- ' (-S|-Sy+u*|-Su|-U|--sync|--upgrade|-i|-si)( |$)' || true)
    if [[ -n $installs ]]; then
        ht_fail "rendering or migration installed packages: $(grep -E '^(pacman|yay|makepkg)' "$STUB_LOG" | head -n3)"
    fi
    if grep -Eq '^sudo .*(pacman|yay)' "$STUB_LOG"; then
        ht_fail "setup ran a privileged package command: $(grep -E '^sudo' "$STUB_LOG" | head -n3)"
    fi
}

# The installer-managed list with comments and blanks removed, exactly like setup.sh reads it.
mapfile -t managed_entries < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' -- "$managed_list" | grep -v '^$')
# Every regular file the list manages, expanded from the repository like setup.sh does.
mapfile -t managed_files < <(
    for entry in "${managed_entries[@]}"; do
        if [[ $entry == */ ]]; then
            find "$HT_REPO_ROOT/dotfiles/$entry" -type f ! -name '*.pyc' -printf "${entry}%P\n"
        else
            printf '%s\n' "$entry"
        fi
    done | LC_ALL=C sort -u
)

# ---------------------------------------------------------------------------
# 1. The managed list matches the shipped tree.

declare -A seen_entry=() managed_set=()
for entry in "${managed_files[@]}"; do managed_set[$entry]=1; done
for entry in "${managed_entries[@]}"; do
    [[ $entry != /* && $entry != *..* ]] || ht_fail "unsafe installer-managed path: $entry"
    [[ -z ${seen_entry[$entry]+x} ]] || ht_fail "duplicate installer-managed path: $entry"
    seen_entry[$entry]=1
    if [[ $entry == */ ]]; then
        [[ -d $HT_REPO_ROOT/dotfiles/$entry ]] || ht_fail "managed directory is missing from dotfiles/: $entry"
        [[ -n $(find "$HT_REPO_ROOT/dotfiles/$entry" -type f ! -name '*.pyc' -print -quit) ]] \
            || ht_fail "managed directory has no files: $entry"
    else
        [[ -f $HT_REPO_ROOT/dotfiles/$entry ]] || ht_fail "managed file is missing from dotfiles/: $entry"
    fi
done
for entry in .config/hypr/scripts/providers/theme.sh .config/hypr/scripts/lib/hss_runtime.sh \
    .config/hypr/scripts/lib/hss_reliability.sh .config/hypr/theme/hss_theme.py .config/hypr/theme/tokens.json \
    .config/hypr/scripts/action_exec.sh .config/waybar/scripts/theme_status.sh; do
    [[ -n ${managed_set[$entry]+x} ]] || ht_fail "theme runtime file is not installer-managed: $entry"
done
ht_ok "every installer-managed path exists in dotfiles/ (${#managed_entries[@]} entries, ${#managed_files[@]} files) and the theme runtime is managed"

# ---------------------------------------------------------------------------
# 2. sync-managed: dry run, refresh, modes, unrelated files and idempotence.

new_install sync
for relative in "${managed_files[@]}"; do
    printf 'stale copy of %s\n' "$relative" > "$HOME/dotfiles/$relative"
    chmod 600 -- "$HOME/dotfiles/$relative"
done
rm -rf -- "$HOME/dotfiles/.config/hypr/scripts/providers"
# User files next to and inside managed directories, and unrelated user edits.
printf '# my helper\n' > "$HOME/dotfiles/.config/hypr/scripts/lib/user_helper.sh"
printf 'user notes\n' > "$HOME/dotfiles/.config/hypr/theme/user-notes.txt"
printf '\n# user edit\n' >> "$HOME/dotfiles/.config/waybar/config.jsonc"
printf '\n-- user binding\n' >> "$HOME/dotfiles/.config/hypr/sources/keybindings.lua"
printf '\n# user kitty edit\n' >> "$HOME/dotfiles/.config/kitty/kitty.conf"

ht_snapshot_tree "$HOME"
reliability sync-managed DRY_RUN=true
assert_status 0 "dry-run sync exit status"
assert_tree_unchanged "$HOME" "home after a dry-run managed sync"

reliability sync-managed
assert_status 0 "managed sync exit status"
sync_run=$(latest_run)
declare -A is_managed=()
for relative in "${managed_files[@]}"; do
    is_managed["/dotfiles/$relative"]=1
    source_file="$HT_REPO_ROOT/dotfiles/$relative"
    destination="$HOME/dotfiles/$relative"
    cmp -s -- "$source_file" "$destination" || ht_fail "managed file was not refreshed: $relative"
    if [[ -x $source_file ]]; then
        assert_eq "$(stat -c %a -- "$source_file")" "$(stat -c %a -- "$destination")" "mode of executable $relative"
    elif [[ $relative == .config/hypr/scripts/providers/* ]]; then
        assert_eq 644 "$(stat -c %a -- "$destination")" "mode of recreated $relative"
    else
        assert_eq 600 "$(stat -c %a -- "$destination")" "existing mode of non-executable $relative"
    fi
done
while IFS= read -r changed; do
    [[ -n ${is_managed[$changed]+x} ]] || ht_fail "managed sync changed an unrelated path: $changed"
done < <(ht_tree_changes "$HOME")
grep -Fqx '# my helper' "$HOME/dotfiles/.config/hypr/scripts/lib/user_helper.sh" || ht_fail "user file in a managed directory was removed"
grep -Fqx 'user notes' "$HOME/dotfiles/.config/hypr/theme/user-notes.txt" || ht_fail "user file in the theme directory was removed"
[[ -s $(manifest_of "$sync_run") ]] || ht_fail "managed sync recorded no writes"

ht_snapshot_tree "$HOME"
reliability sync-managed
assert_status 0 "second managed sync exit status"
assert_tree_unchanged "$HOME" "home after an identical managed sync"
[[ ! -s $(manifest_of "$(latest_run)") ]] || ht_fail "an identical managed sync rewrote files: $(cut -f2 "$(manifest_of "$(latest_run)")" | head -n3)"
assert_no_package_installation
ht_ok "managed sync refreshes only listed files, keeps executable modes and user files, dry-runs without writes and is idempotent"

# ---------------------------------------------------------------------------
# 3. Session migrations change only exact legacy lines, idempotently, and roll back.

# The same action also enables optional extras when a command or file exists. Those must not
# depend on the host, so the session runs use a PATH without the optional extra commands.
path_without_extras() {
    local dir="$HT_ROOT/host-path" entry
    if [[ ! -d $dir ]]; then
        mkdir -p -- "$dir"
        IFS=: read -r -a entries <<<"$PATH"
        for entry in "${entries[@]}"; do
            [[ -d $entry && $entry != "$HT_BIN" && $entry != */tests/stubs ]] || continue
            find "$entry" -maxdepth 1 ! -type d ! -name pypr ! -name hyprsunset ! -name input-remapper-control \
                -exec ln -s -t "$dir" -- {} + 2>/dev/null || true
        done
    fi
    printf '%s:%s:%s\n' "$HT_BIN" "$HT_REPO_ROOT/tests/stubs" "$dir"
}
extras_path=$(path_without_extras)
for tool in pypr hyprsunset input-remapper-control; do
    ! PATH=$extras_path command -v "$tool" >/dev/null || ht_fail "optional extra $tool is still on the fixture PATH"
done

new_install session
# Optional extras that would be enabled by an existing file stay out of this fixture.
rm -f -- "$HOME/dotfiles/.config/hypr/scripts/fix-dolphin.sh" "$HOME/dotfiles/.config/kitty/my_layout.conf"
for root in "$HOME/dotfiles/.config/hypr/sources" "$HOME/dotfiles/.config/hypr/sources_example"; do
    cat > "$root/autostart.lua" <<'EOF'
-- user autostart
hl.on("hyprland.start", function()
    hl.exec_cmd("systemctl --user start hyprpolkitagent")
	hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1")
    hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1 --my-option")
    -- hl.exec_cmd("systemctl --user start hyprpolkitagent")
    hl.exec_cmd("systemctl --user start hyprpolkitagent && my-hook")
    hl.exec_cmd("my-own-daemon")
end)
EOF
    cat > "$root/autostart.conf" <<'EOF'
# user autostart
exec-once = systemctl --user start hyprpolkitagent &
exec-once = /usr/lib/polkit-kde-authentication-agent-1 &
exec-once = /usr/lib/polkit-kde-authentication-agent-1 --custom &
exec-once = my-own-daemon
EOF
done
cat > "$HOME/dotfiles/.config/wlogout/layout" <<'EOF'
{
    "label" : "lock",
    "action" : "loginctl lock-session",
    "text" : "Lock",
    "keybind" : "l"
}
{
    "label" : "hibernate",
    "action" : "systemctl hibernate",
    "text" : "Hibernate",
    "keybind" : "h"
}
{
    "label" : "logout",
    "action" : "loginctl terminate-user $USER",
    "text" : "Logout",
    "keybind" : "e"
}
{
    "label" : "shutdown",
    "action" : "systemctl poweroff --my-flag",
    "text" : "Shutdown",
    "keybind" : "s"
}
{
    "label" : "suspend",
    "action" : "systemctl suspend",
    "text" : "Suspend",
    "keybind" : "u"
}
{
    "label" : "reboot",
    "action" : "systemctl reboot",
    "text" : "Reboot",
    "keybind" : "r"
}
EOF
cat > "$HOME/dotfiles/.config/hypr/hypridle.conf" <<'EOF'
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on  # to avoid having to press a key twice to turn on the display.
}
# after_sleep_cmd = hyprctl dispatch dpms on  # to avoid having to press a key twice to turn on the display.
EOF

expected="$HT_ROOT/expected-session"
mkdir -p -- "$expected"
cat > "$expected/autostart.lua" <<'EOF'
-- user autostart
hl.on("hyprland.start", function()
    hl.exec_cmd(apps.hyprscripts .. "/action_exec.sh --quiet session.auth.start")
    hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1 --my-option")
    -- hl.exec_cmd("systemctl --user start hyprpolkitagent")
    hl.exec_cmd("systemctl --user start hyprpolkitagent && my-hook")
    hl.exec_cmd("my-own-daemon")
end)
EOF
cat > "$expected/autostart.conf" <<'EOF'
# user autostart
exec-once = $hyprscripts/action_exec.sh --quiet session.auth.start
exec-once = /usr/lib/polkit-kde-authentication-agent-1 --custom &
exec-once = my-own-daemon
EOF
sed -e 's|"action" : "loginctl lock-session",|"action" : "\\"$HOME/.config/hypr/scripts/action_exec.sh\\" session.lock",|' \
    -e 's|"action" : "systemctl hibernate",|"action" : "\\"$HOME/.config/hypr/scripts/action_exec.sh\\" session.hibernate",|' \
    -e 's|"action" : "loginctl terminate-user $USER",|"action" : "\\"$HOME/.config/hypr/scripts/action_exec.sh\\" session.logout",|' \
    -e 's|"action" : "systemctl suspend",|"action" : "\\"$HOME/.config/hypr/scripts/action_exec.sh\\" session.suspend",|' \
    -e 's|"action" : "systemctl reboot",|"action" : "\\"$HOME/.config/hypr/scripts/action_exec.sh\\" session.reboot",|' \
    -- "$HOME/dotfiles/.config/wlogout/layout" > "$expected/layout"
cat > "$expected/hypridle.conf" <<'EOF'
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch 'hl.dsp.dpms({action = "on"})' # turn the display on without a second key press.
}
# after_sleep_cmd = hyprctl dispatch dpms on  # to avoid having to press a key twice to turn on the display.
EOF
session_files=(
    "$HOME/dotfiles/.config/hypr/sources/autostart.lua" "$HOME/dotfiles/.config/hypr/sources_example/autostart.lua"
    "$HOME/dotfiles/.config/hypr/sources/autostart.conf" "$HOME/dotfiles/.config/hypr/sources_example/autostart.conf"
    "$HOME/dotfiles/.config/wlogout/layout" "$HOME/dotfiles/.config/hypr/hypridle.conf"
)
expected_files=("$expected/autostart.lua" "$expected/autostart.lua" "$expected/autostart.conf" "$expected/autostart.conf"
    "$expected/layout" "$expected/hypridle.conf")

before_session=$(ht_tree_listing "$HOME")
ht_snapshot_tree "$HOME"
reliability autostart-extras DRY_RUN=true PATH="$extras_path"
assert_status 0 "dry-run session migration"
assert_tree_unchanged "$HOME" "home after a dry-run session migration"

reliability autostart-extras PATH="$extras_path"
assert_status 0 "session migration exit status"
migration_run=$(latest_run)
for index in "${!session_files[@]}"; do
    if ! cmp -s -- "${expected_files[index]}" "${session_files[index]}"; then
        diff -u -- "${expected_files[index]}" "${session_files[index]}" >&2 || true
        ht_fail "session migration of ${session_files[index]#"$HOME/"} changed more or less than the exact legacy lines"
    fi
done
mapfile -t migrated < <(ht_tree_changes "$HOME")
assert_eq 6 "${#migrated[@]}" "files changed by the session migration (${migrated[*]})"

ht_snapshot_tree "$HOME"
reliability autostart-extras PATH="$extras_path"
assert_status 0 "repeated session migration"
assert_tree_unchanged "$HOME" "home after a repeated session migration"
[[ ! -s $(manifest_of "$(latest_run)") ]] || ht_fail "a repeated session migration rewrote files"

ht_run env NON_INTERACTIVE=true "$HT_REPO_ROOT/setup.sh" --rollback "$migration_run" </dev/null
assert_status 0 "rollback of the session migration"
assert_eq "$before_session" "$(ht_tree_listing "$HOME")" "home after rolling back the session migration"
assert_no_package_installation
ht_ok "session autostart, Wlogout and Hypridle migrations change only exact legacy lines, are idempotent and roll back"

# Identical rerun of the shipped autostart.lua through the same entry point. Optional extras
# are enabled in place on the first run; a rerun must not change the file again.
new_install extras
autostart="$HOME/dotfiles/.config/hypr/sources/autostart.lua"
reliability autostart-extras PATH="$extras_path"
assert_status 0 "first optional-extras run"
cp -- "$autostart" "$HT_ROOT/autostart.after-first"
reliability autostart-extras PATH="$extras_path"
assert_status 0 "second optional-extras run"
cmp -s -- "$HT_ROOT/autostart.after-first" "$autostart" \
    || ht_fail "a rerun changed autostart.lua: $(diff -- "$HT_ROOT/autostart.after-first" "$autostart" | sed -n 's/^> *//p' | head -n1)"
ht_ok "a rerun of the autostart migrations leaves the shipped autostart.lua unchanged"

# ---------------------------------------------------------------------------
# 4. Default handlers through configure_filepicker, then setup.sh --rollback.

new_install handlers
# Stateful xdg-mime: `default` edits [Default Applications] in $XDG_CONFIG_HOME/mimeapps.list,
# `query default` reads it back. No system association files are consulted.
ht__write_double xdg-mime <<'BODY'
file="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
lookup() {
    [[ -f $file ]] || return 0
    awk -v key="$1" '
        /^\[/ { section = $0; next }
        section == "[Default Applications]" { eq = index($0, "="); if (eq > 0 && substr($0, 1, eq - 1) == key) value = substr($0, eq + 1) }
        END { split(value, parts, ";"); if (parts[1] != "") print parts[1] }
    ' "$file"
}
case "${1-}" in
    query) [[ ${2-} == default ]] || exit 1; lookup "${3-}"; exit 0 ;;
    default) ;;
    *) exit 1 ;;
esac
desktop=$2
shift 2
[[ -f $file ]] || : > "$file"
for mime in "$@"; do
    awk -v key="$mime" -v value="$desktop" '
        /^\[/ {
            if (section == "[Default Applications]" && !done) { print key "=" value; done = 1 }
            section = $0; if (section == "[Default Applications]") seen = 1; print; next
        }
        section == "[Default Applications]" && index($0, key "=") == 1 { if (!done) { print key "=" value; done = 1 }; next }
        { print }
        END {
            if (section == "[Default Applications]" && !done) { print key "=" value; done = 1 }
            if (!seen) { print "[Default Applications]"; print key "=" value }
        }
    ' "$file" > "$file.new" && mv -f -- "$file.new" "$file"
done
BODY
export ROLE_BROWSER=firefox ROLE_FILE_MANAGER=dolphin ROLE_GUI_EDITOR="" ROLE_TUI_EDITOR=neovim
export HSS_ROLES_FILE="$HT_ROOT/handlers-roles.json"
ht_write_roles "$HSS_ROLES_FILE" browser=firefox file_manager=dolphin gui_editor= tui_editor=neovim
for id in firefox.desktop org.kde.dolphin.desktop thunar.desktop; do
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=touch %s/exec-was-run\n' "$id" "$HT_ROOT" > "$XDG_DATA_DIRS/applications/$id"
done
mkdir -p -- "$XDG_DATA_HOME/applications"
cp -- "$HT_REPO_ROOT/dotfiles/.local/share/applications/hss-tui-editor.desktop" "$XDG_DATA_HOME/applications/"
mimeapps="$XDG_CONFIG_HOME/mimeapps.list"
printf '[Default Applications]\ntext/html=chromium.desktop\nimage/png=org.kde.gwenview.desktop\n\n[Added Associations]\nimage/png=org.kde.gwenview.desktop;\n' > "$mimeapps"
cp -- "$mimeapps" "$HT_ROOT/mimeapps.before"
portal="$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf"
rm -f -- "$portal"

ht_snapshot_tree "$HOME"
reliability filepicker DRY_RUN=true
assert_status 0 "dry-run filepicker"
assert_tree_unchanged "$HOME" "home after a dry-run handler configuration"
for ((index = 1; index <= $(ht_calls xdg-mime); index++)); do
    [[ $(tr '\0' '\n' < "$HT_STATE/calls/xdg-mime.$index" | head -n1) != default ]] || ht_fail "a dry run called xdg-mime default"
done
dry_handler_run=$(latest_run)
[[ -s $(state_dir)/runs/$dry_handler_run/handlers-preview.tsv ]] || ht_fail "the dry run did not record its handler preview"

reliability filepicker
assert_status 0 "filepicker exit status"
handler_run=$(latest_run)
out_has 'Default handlers: applied=6' "handler summary"
for pair in x-scheme-handler/http=firefox.desktop x-scheme-handler/https=firefox.desktop text/html=firefox.desktop \
    inode/directory=org.kde.dolphin.desktop text/plain=hss-tui-editor.desktop application/x-shellscript=hss-tui-editor.desktop; do
    assert_eq "${pair#*=}" "$(xdg-mime query default "${pair%%=*}")" "handler for ${pair%%=*}"
done
grep -Fqx 'image/png=org.kde.gwenview.desktop' "$mimeapps" || ht_fail "an unrelated association was dropped"
[[ -f $portal ]] || ht_fail "the FileChooser portal configuration was not written"
[[ ! -e $HT_ROOT/exec-was-run ]] || ht_fail "a desktop entry Exec line was run"
[[ -s $(state_dir)/runs/$handler_run/handlers.tsv ]] || ht_fail "handler changes were not recorded in the run"

# A newer user choice for one MIME type survives rollback; the rest is restored.
xdg-mime default thunar.desktop inode/directory
ht_run env NON_INTERACTIVE=true "$HT_REPO_ROOT/setup.sh" --rollback "$handler_run" </dev/null
cat -- "$HT_STDOUT" "$HT_STDERR" > "$HT_ROOT/last.out"
assert_status 10 "rollback with a newer user handler"
out_has 'changed after run' "the kept user handler is reported"
assert_eq thunar.desktop "$(xdg-mime query default inode/directory)" "newer user folder handler"
assert_eq chromium.desktop "$(xdg-mime query default text/html)" "restored text/html handler"
for mime in x-scheme-handler/http x-scheme-handler/https text/plain application/x-shellscript; do
    assert_eq "" "$(xdg-mime query default "$mime")" "restored absence of $mime"
done
grep -Fqx 'image/png=org.kde.gwenview.desktop' "$mimeapps" || ht_fail "rollback dropped an unrelated association"
[[ ! -e $portal ]] || ht_fail "rollback did not remove the portal file the run created"
unset HSS_ROLES_FILE
assert_no_package_installation
ht_ok "handler configuration dry-runs without writes, applies primary associations and rolls back without overwriting newer user choices"

# ---------------------------------------------------------------------------
# 5. Fresh installation: adoption without consent prompt, stock Waybar upgrade, rerun.

new_install fresh
waybar_style="$HOME/dotfiles/.config/waybar/style.css"
# The first shipped Waybar style (stock digest 114f17cf...).
base64 -d > "$HT_ROOT/stock-style.gz" <<'EOF'
H4sIAAAAAAAAA51U226jMBB971dYystuVSqgaULIF/Sh37AafAErjo1ssyRb7b/XAcwtEK0WYQnb4zNnzhzzjL6ekHsypQnVgQbC
K5Oi8NisMiVtwODMxTVFH9JSjT6piziPtg3/Q1MUJeWlXTxzGRSU54XtYP664d6aS6LqTQ3XDLTPCviUa1VJkiKrQZoSNJW2BcJK
KJ2iDQ4xsPcRklVKWF4uYGwiEocxOy6VFL17ht1GzYktUhTPlo29CleQUYKTyYbnw/b7XUJHfDa10idHHVODsspaJTtqJRDCZe50
KC8oCn0iDwSHLCK7h0CvTOHKUNJ36RKYApyODe9+TOq+120s0kIZq1Kt06p07vrUsfrHhDQEtkv+L2FaqN/03jU9dpYdgO0f1P84
HxYKn15uXxlY5/Jr811WwlCoCFcvU1LNVIDMK8hpM3Hmbc9wIugvLguecat0B4lP4nYf1unH2zh5y473phluFeicy/S2gMJVsb5G
sYGgzF3BwXYLGjQ5GnMuCTJr7wPDeIgedEw60O3PYGDSlTjf8Mm7HszSHyimO5jGTYW9N5qPnHZlFr4nmDG2QOAVF00B+fwAQNya
bX6gBi1vvZPK/uhP/1zv+zbaJv5KrP7ueqfNaAye94GDYdcZfwPLgBU48QUAAA==
EOF
gzip -dc -- "$HT_ROOT/stock-style.gz" > "$waybar_style"
assert_eq 114f17cf134a3bcf461e3c3641574feef099481e6a0f165c2c5deec588eef3ed "$(sha256sum -- "$waybar_style" | cut -d' ' -f1)" \
    "digest of the embedded stock Waybar style"

harmonize HSS_DOTFILES_FRESH=true
[[ $HT_STATUS == 0 ]] || show_failure "fresh harmonization failed"
fresh_run=$(latest_run)
assert_json "$XDG_CONFIG_HOME/hss-theme/state.json" '.variant == "dark"' "fresh adoption state"
assert_json "$(state_dir)/runs/$fresh_run/theme-report.json" '.adopt == true
    and (.applied | index("theme-core")) != null and (.applied | index("gtk3")) != null
    and (.applied | index("waybar")) != null and .failed == []' "fresh theme report"
grep -Fq 'hss-theme:waybar' "$waybar_style" || ht_fail "the upgraded Waybar style has no theme region"
ht_assert_user_lines_preserved "$HT_REPO_ROOT/dotfiles/.config/waybar/style.css" "$waybar_style" \
    "$XDG_CONFIG_HOME/hss-theme/managed.json" "$waybar_style" "upgraded stock Waybar style"
grep -Fq "$waybar_style" "$(manifest_of "$fresh_run")" || ht_fail "the Waybar upgrade is not recorded in the setup run"
for file in "$HOME/dotfiles/.config/hypr/sources/keybindings.lua" "$HOME/dotfiles/.config/hypr/sources_example/keybindings.lua"; do
    assert_eq 1 "$(grep -c 'hss-theme:toggle-binding' "$file")" "theme bindings in ${file#"$HOME/"}"
done
grep -Fq 'XCURSOR_THEME", "BreezeX-RosePine-Linux"' "$HOME/dotfiles/.config/hypr/sources/environment_variables.lua" \
    || ht_fail "the stock Xcursor line was not migrated"
[[ -L $XDG_CONFIG_HOME/gtk-3.0 && -L $XDG_CONFIG_HOME/waybar && -L $XDG_CONFIG_HOME/kdeglobals ]] || ht_fail "Stow links were replaced"
if grep -Fq 'Existing configuration was not changed' "$HT_ROOT/last.out"; then
    show_failure "a fresh installation was only previewed"
fi
assert_no_package_installation
ht_ok "a fresh installation adopts the theme without a consent prompt and upgrades the stock Waybar style"

# Identical rerun of an adopted installation: nothing in ~/dotfiles changes.
ht_snapshot_tree "$HOME/dotfiles"
ht_snapshot_tree "$XDG_CONFIG_HOME/hss-theme/generated"
harmonize
[[ $HT_STATUS == 0 ]] || show_failure "adopted rerun failed"
rerun=$(latest_run)
assert_tree_unchanged "$HOME/dotfiles" "dotfiles after an identical adopted rerun"
assert_json "$(state_dir)/runs/$rerun/theme-report.json" '.adopt == true and .applied == [] and .failed == []' "rerun theme report"
# configure_roles rewrites its own files with identical bytes on every run, so the run manifest
# is not an oracle here; the generated theme files and every dotfile must keep their bytes.
assert_tree_unchanged "$XDG_CONFIG_HOME/hss-theme/generated" "generated theme files after an identical adopted rerun"
assert_json "$XDG_CONFIG_HOME/hss-theme/state.json" '.variant == "dark"' "variant kept on rerun"
ht_ok "an identical rerun of an adopted installation applies nothing and adds no duplicate binding"

# A theme that fails validation is reported, but setup continues and changes no theme file.
tokens="$HOME/dotfiles/.config/hypr/theme/tokens.json"
cp -- "$tokens" "$HT_ROOT/tokens.good"
printf '{"schema_version": 1, "broken": \n' > "$tokens"
ht_snapshot_tree "$HOME/dotfiles"
ht_snapshot_tree "$XDG_CONFIG_HOME/hss-theme"
harmonize HSS_THEME_VARIANT=light
assert_status 0 "setup exit status with an invalid theme"
out_has 'Desktop harmonization did not complete' "the failed theme validation is reported"
assert_tree_unchanged "$HOME/dotfiles" "dotfiles after a failed theme validation"
assert_tree_unchanged "$XDG_CONFIG_HOME/hss-theme" "theme state after a failed theme validation"
cp -- "$HT_ROOT/tokens.good" "$tokens"
assert_no_package_installation
ht_ok "a failed theme validation is reported as a soft error without aborting setup or writing theme files"

# ---------------------------------------------------------------------------
# 6. Existing, never-adopted installation with a customized Waybar style.

new_install existing
waybar_style="$HOME/dotfiles/.config/waybar/style.css"
{ printf '/* my waybar */\n#clock { color: #123456; }\n'; cat -- "$HT_REPO_ROOT/dotfiles/.config/waybar/style.css"; } \
    | sed '/hss-theme:waybar/,/hss-theme:waybar/d' > "$waybar_style"
cp -- "$waybar_style" "$HT_ROOT/custom-style.css"
gtk_settings="$HOME/dotfiles/.config/gtk-3.0/settings.ini"
keys="$HOME/dotfiles/.config/hypr/sources/keybindings.lua"
ht_snapshot "$waybar_style" "$gtk_settings"
bindings_before=$(grep -c 'hss-theme:toggle-binding' "$keys" || true)

# An invalid consent value stops harmonization before any harmonization write.
harmonize HSS_HARMONIZATION_ADOPT=maybe
[[ $HT_STATUS != 0 ]] || show_failure "an invalid HSS_HARMONIZATION_ADOPT was accepted"
grep -Fq "HSS_HARMONIZATION_ADOPT must be preview, apply or skip (got 'maybe')" "$(state_dir)/runs/$(latest_run)/log" \
    || ht_fail "the invalid consent value is not recorded in the setup run log"
grep -Fq 'HSS_HARMONIZATION_ADOPT must be preview, apply or skip' "$HT_ROOT/last.out" \
    || ht_fail "an invalid HSS_HARMONIZATION_ADOPT is not explained on the console"
[[ ! -e $XDG_CONFIG_HOME/hss-theme ]] || ht_fail "an invalid consent value created theme state"
assert_file_unchanged "$waybar_style" "Waybar style after an invalid consent value"
assert_file_unchanged "$gtk_settings" "GTK settings after an invalid consent value"
# configure_roles runs first and may write role bindings; the theme binding must not appear.
assert_eq "$bindings_before" "$(grep -c 'hss-theme:toggle-binding' "$keys")" "theme bindings after an invalid consent value"

# Without HSS_HARMONIZATION_ADOPT an existing installation is only previewed.
ht_snapshot_tree "$HOME"
harmonize
[[ $HT_STATUS == 0 ]] || show_failure "preview of an existing installation failed"
assert_tree_unchanged "$HOME" "home after previewing an existing installation"
out_has 'Existing configuration was not changed' "preview notice"
out_has 'Preview for dark' "preview plan"
if grep -Fq 'Keeping customized' "$HT_ROOT/last.out"; then show_failure "the Waybar upgrade ran during a preview"; fi
[[ ! -e $XDG_CONFIG_HOME/hss-theme/state.json ]] || ht_fail "the preview wrote theme state"
ht_ok "an invalid consent value stops before harmonization writes and an unadopted installation is only previewed"

# Explicit adoption keeps the customized Waybar style and reports it.
harmonize HSS_HARMONIZATION_ADOPT=apply HSS_THEME_VARIANT=light
[[ $HT_STATUS == 0 ]] || show_failure "explicit adoption failed"
out_has 'Keeping customized' "the customized Waybar style is reported"
grep -Fqx '/* my waybar */' "$waybar_style" || ht_fail "the customized Waybar style was replaced"
grep -Fqx '#clock { color: #123456; }' "$waybar_style" || ht_fail "a customized Waybar rule was lost"
ht_assert_user_lines_preserved "$HT_ROOT/custom-style.css" "$waybar_style" \
    "$XDG_CONFIG_HOME/hss-theme/managed.json" "$waybar_style" "customized Waybar style"
assert_json "$XDG_CONFIG_HOME/hss-theme/state.json" '.variant == "light"' "requested variant on adoption"
ht_ok "adoption keeps a customized Waybar style, adding only the theme region, and reports it"

# A dry run of a previously adopted installation keeps the stored variant and writes nothing.
ht_snapshot_tree "$HOME"
harmonize DRY_RUN=true
[[ $HT_STATUS == 0 ]] || show_failure "dry run failed"
assert_tree_unchanged "$HOME" "home after a harmonization dry run"
out_has 'DRY-RUN SUMMARY' "dry-run summary"
assert_json "$XDG_CONFIG_HOME/hss-theme/state.json" '.variant == "light"' "state after a dry run"
[[ ! -s $(manifest_of "$(latest_run)") ]] || ht_fail "a dry run recorded writes"
assert_no_package_installation
ht_ok "a harmonization dry run writes nothing and installs nothing"
