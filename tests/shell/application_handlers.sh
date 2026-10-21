#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329 # Literal $ in expected text; reliability hooks are called indirectly.
set -euo pipefail

# D06.2 default-handler intents: preview/apply/restore through a stateful xdg-mime double,
# the GUI-editor None desktop entry, missing entries, missing xdg-mime, apply failure and
# effective-handler mismatch. Hermetic: no session bus, display or real association files.
unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY XDG_CURRENT_DESKTOP KDE_SESSION_VERSION
system_path=$PATH

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# Stateful xdg-mime double. `default` edits [Default Applications] in
# $XDG_CONFIG_HOME/mimeapps.list; `query default` resolves the desktop-specific file first,
# then the user file, then $XDG_DATA_DIRS/applications/mimeapps.list. Every call is logged
# NUL-separated in its own file under $XDG_MIME_STUB_CALLS.
stub_bin="$base/stub-bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/xdg-mime" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
calls=${XDG_MIME_STUB_CALLS:?}
mkdir -p "$calls"
count=$(find "$calls" -type f | wc -l)
printf '%s\0' "$@" > "$calls/$(printf '%04d' $((count + 1)))"
config=${XDG_CONFIG_HOME:-$HOME/.config}
lookup() {
  local file=$1 mime=$2
  [[ -f $file ]] || return 1
  awk -v key="$mime" '
    /^\[/ { section = $0; next }
    section == "[Default Applications]" {
      eq = index($0, "=")
      if (eq > 0 && substr($0, 1, eq - 1) == key) value = substr($0, eq + 1)
    }
    END { split(value, parts, ";"); if (parts[1] == "") exit 1; print parts[1] }
  ' "$file"
}
case "${1:-}/${2:-}" in
  query/default)
    mime=$3
    desktops=${XDG_CURRENT_DESKTOP:-}
    for desktop in ${desktops//:/ }; do
      lookup "$config/${desktop,,}-mimeapps.list" "$mime" && exit 0
    done
    lookup "$config/mimeapps.list" "$mime" && exit 0
    IFS=: read -r -a dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    for dir in "${dirs[@]}"; do
      lookup "$dir/applications/mimeapps.list" "$mime" && exit 0
    done
    exit 0
    ;;
  default/*)
    case "${XDG_MIME_STUB_MODE:-ok}" in
      fail) exit 4 ;;
      noop) exit 0 ;;
    esac
    desktop=$2
    shift 2
    file="$config/mimeapps.list"
    mkdir -p "$config"
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
      ' "$file" > "$file.new"
      mv -f -- "$file.new" "$file"
    done
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub_bin/xdg-mime"

# Build a schema-2 roles.json from the catalog for the given primaries.
make_roles() {
  local out=$1 browser=$2 file_manager=$3 gui_editor=$4 tui_editor=$5 terminal=$6
  jq -n --slurpfile registry "$repo_root/packages.json" \
    --arg browser "$browser" --arg file_manager "$file_manager" --arg gui_editor "$gui_editor" \
    --arg tui_editor "$tui_editor" --arg terminal "$terminal" '
    $registry[0] as $r
    | def pick($role; $package):
        if $package == "" then null else ($r.roles[$role].options[] | select(.package == $package)) end;
    {
      schema_version: 2,
      roles: {
        browser: pick("browser"; $browser),
        file_manager: pick("file_manager"; $file_manager),
        gui_editor: pick("gui_editor"; $gui_editor),
        tui_editor: pick("tui_editor"; $tui_editor),
        terminal: pick("terminal"; $terminal)
      },
      selected: {},
      agent_executables: {}
    }
    | .selected = (.roles | with_entries(.value = (if .value == null then [] else [.value] end)))
  ' > "$out"
}

# Fresh fixture: HOME, XDG dirs, installed desktop entries, user association file.
new_fixture() {
  local name=$1
  fixture="$base/$name"
  export HOME="$fixture/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$fixture/state"
  export XDG_DATA_DIRS="$fixture/system"
  export XDG_MIME_STUB_CALLS="$fixture/calls"
  export HSS_ROLES_FILE="$fixture/roles.json"
  unset XDG_MIME_STUB_MODE HSS_HANDLERS_MODE
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/applications" "$XDG_STATE_HOME" "$XDG_DATA_DIRS/applications"
  local id
  for id in firefox.desktop chromium.desktop org.kde.dolphin.desktop thunar.desktop code.desktop org.kde.kate.desktop; do
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=touch %s/exec-was-run\n' "$id" "$fixture" > "$XDG_DATA_DIRS/applications/$id"
  done
  cp "$repo_root/dotfiles/.local/share/applications/hss-tui-editor.desktop" "$XDG_DATA_HOME/applications/"
  printf '[Default Applications]\ntext/plain=org.gnome.TextEditor.desktop\nimage/png=org.kde.gwenview.desktop\n\n[Added Associations]\ntext/plain=org.gnome.TextEditor.desktop;\n' \
    > "$XDG_CONFIG_HOME/mimeapps.list"
  mkdir -p "$XDG_CONFIG_HOME/xdg-desktop-portal"
  printf '[preferred]\ndefault = hyprland;gtk\norg.freedesktop.impl.portal.FileChooser = gtk\n' \
    > "$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf"
}

# Run handler functions inside a real setup reliability run in a subshell.
# Prints "status=N run=RUN_ID" on the last line.
in_setup_run() {
  (
    # shellcheck source=scripts/lib/setup-reliability.sh
    source "$repo_root/scripts/lib/setup-reliability.sh"
    # shellcheck source=scripts/lib/setup-handlers.sh
    source "$repo_root/scripts/lib/setup-handlers.sh"
    is_dry_run() { [[ ${DRY_RUN:-false} == true ]]; }
    log_dry_run_operation() { printf 'dry-run %s: %s\n' "$1" "$2"; }
    print_dry_run_summary() { :; }
    hss_begin_run "application_handlers test" || exit 99
    status=0
    "$@" 2>&1 || status=$?
    printf 'summary=%s\n' "${HSS_HANDLERS_SUMMARY:-}"
    printf 'status=%s run=%s\n' "$status" "$HSS_RUN_ID"
  )
}

last_status() { sed -n 's/^status=\([0-9]*\) run=.*/\1/p' <<<"$1" | tail -n1; }
last_run() { sed -n 's/^status=[0-9]* run=\(.*\)$/\1/p' <<<"$1" | tail -n1; }
user_value() {
  awk -v section="[$1]" -v key="$2" '/^\[/ { s = $0; next } s == section && index($0, key "=") == 1 { v = substr($0, length(key) + 2); f = 1 } END { if (f) print v; else print "<absent>" }' "$XDG_CONFIG_HOME/mimeapps.list"
}
record_field() {
  local run=$1 mime=$2 column=$3
  awk -F '\t' -v mime="$mime" -v column="$column" 'NR == 1 { for (i = 1; i <= NF; i++) index_of[$i] = i; next } $1 == mime { print $(index_of[column]) }' \
    "$XDG_STATE_HOME/hyprland-simple-setup/runs/$run/handlers.tsv"
}
calls_with() {
  local needle=$1 file count=0
  [[ -d $XDG_MIME_STUB_CALLS ]] || { printf '0\n'; return; }
  for file in "$XDG_MIME_STUB_CALLS"/*; do
    mapfile -d '' argv < "$file"
    [[ ${argv[0]} == "$needle" ]] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

export PATH="$stub_bin:$PATH"

# 1. Preview reports every target and changes nothing.
new_fixture preview
make_roles "$HSS_ROLES_FILE" firefox dolphin visual-studio-code-bin neovim kitty
before=$(sha256sum < "$XDG_CONFIG_HOME/mimeapps.list")
output=$(in_setup_run hss_handlers_preview)
[[ $(last_status "$output") == 0 ]] || fail "preview exits 0"
grep -Fxq 'x-scheme-handler/http: - -> firefox.desktop (would-apply)' <<<"$output" || fail "preview lists http"
grep -Fxq 'inode/directory: - -> org.kde.dolphin.desktop (would-apply)' <<<"$output" || fail "preview lists folders"
grep -Fxq 'text/plain: org.gnome.TextEditor.desktop -> code.desktop (would-apply)' <<<"$output" || fail "preview shows the current text handler"
[[ $(sha256sum < "$XDG_CONFIG_HOME/mimeapps.list") == "$before" ]] || fail "preview changed associations"
[[ $(calls_with default) == 0 ]] || fail "preview called xdg-mime default"
run=$(last_run "$output")
[[ $(wc -l < "$XDG_STATE_HOME/hyprland-simple-setup/runs/$run/handlers-preview.tsv") == 7 ]] || fail "preview report has six targets"
printf 'ok - preview lists browser, folder and text targets without changing associations\n'

# 2. Apply sets every target through xdg-mime, verifies it and records previous entries.
output=$(in_setup_run hss_handlers_apply)
[[ $(last_status "$output") == 0 ]] || fail "apply exits 0: $output"
run=$(last_run "$output")
for mime in x-scheme-handler/http x-scheme-handler/https text/html; do
  [[ $(user_value 'Default Applications' "$mime") == firefox.desktop ]] || fail "browser handler $mime"
  [[ $(record_field "$run" "$mime" status) == applied ]] || fail "browser status $mime"
  [[ $(record_field "$run" "$mime" before_default) == - ]] || fail "absence recorded for $mime"
done
[[ $(user_value 'Default Applications' inode/directory) == org.kde.dolphin.desktop ]] || fail "folder handler"
[[ $(user_value 'Default Applications' text/plain) == code.desktop ]] || fail "text handler"
[[ $(user_value 'Default Applications' application/x-shellscript) == code.desktop ]] || fail "script handler"
[[ $(record_field "$run" text/plain before_default) == '=org.gnome.TextEditor.desktop' ]] || fail "previous text default recorded"
[[ $(record_field "$run" text/plain before_added) == '=org.gnome.TextEditor.desktop;' ]] || fail "previous added association recorded"
[[ $(record_field "$run" text/plain before_effective) == org.gnome.TextEditor.desktop ]] || fail "previous effective handler recorded"
[[ $(user_value 'Default Applications' image/png) == org.kde.gwenview.desktop ]] || fail "unrelated association kept"
[[ $(calls_with default) == 6 ]] || fail "one xdg-mime default call per target"
for file in "$XDG_MIME_STUB_CALLS"/*; do
  mapfile -d '' argv < "$file"
  if [[ ${argv[0]} == default ]]; then
    [[ ${#argv[@]} == 3 ]] || fail "xdg-mime default receives exactly one desktop ID and one type"
  fi
done
[[ ! -e $fixture/exec-was-run ]] || fail "a desktop Exec line was run"
grep -Fxq 'org.freedesktop.impl.portal.FileChooser = gtk' "$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf" || fail "portal file changed"
printf 'ok - apply associates the primary browser, file manager and GUI editor and records prior entries including absence\n'

# 3. A second apply is idempotent.
output=$(in_setup_run hss_handlers_apply)
[[ $(last_status "$output") == 0 ]] || fail "second apply"
grep -Fq 'summary=unchanged=6' <<<"$output" || fail "second apply reports unchanged: $output"
[[ $(calls_with default) == 6 ]] || fail "second apply wrote again"
printf 'ok - reapplying an effective selection changes nothing\n'

# 4. Restore puts back only what the run changed and keeps later user edits.
apply_run=$run
awk '/^inode\/directory=/ { print "inode/directory=org.gnome.Nautilus.desktop"; next } { print }' \
  "$XDG_CONFIG_HOME/mimeapps.list" > "$base/edited" && mv "$base/edited" "$XDG_CONFIG_HOME/mimeapps.list"
output=$(in_setup_run hss_handlers_restore "$apply_run")
[[ $(last_status "$output") == 10 ]] || fail "restore reports the conflict: $output"
grep -Fq 'restored=5' <<<"$output" || fail "five keys restored: $output"
grep -Fq 'conflict=1' <<<"$output" || fail "one conflict: $output"
for mime in x-scheme-handler/http x-scheme-handler/https text/html application/x-shellscript; do
  [[ $(user_value 'Default Applications' "$mime") == '<absent>' ]] || fail "absence restored for $mime"
done
[[ $(user_value 'Default Applications' text/plain) == org.gnome.TextEditor.desktop ]] || fail "previous text default restored"
[[ $(user_value 'Added Associations' text/plain) == 'org.gnome.TextEditor.desktop;' ]] || fail "added association kept"
[[ $(user_value 'Default Applications' inode/directory) == org.gnome.Nautilus.desktop ]] || fail "later user edit kept"
[[ $(user_value 'Default Applications' image/png) == org.kde.gwenview.desktop ]] || fail "unrelated key kept by restore"
restore_run=$(last_run "$output")
grep -q $'\t'"$XDG_CONFIG_HOME/mimeapps.list"$'\t' "$XDG_STATE_HOME/hyprland-simple-setup/runs/$restore_run/manifest.tsv" \
  || fail "restore write is recorded in the reliability manifest"
output=$(in_setup_run hss_handlers_restore "$apply_run")
grep -Fq 'unchanged=5' <<<"$output" || fail "second restore is a no-op: $output"
printf 'ok - restore returns changed keys to their recorded state, including absence, and preserves later user edits\n'

# 5. GUI editor None uses the managed entry that opens the primary TUI editor in the terminal.
new_fixture none-editor
make_roles "$HSS_ROLES_FILE" chromium thunar '' helix foot
output=$(in_setup_run hss_handlers_apply)
[[ $(last_status "$output") == 0 ]] || fail "None editor apply: $output"
run=$(last_run "$output")
[[ $(user_value 'Default Applications' text/plain) == hss-tui-editor.desktop ]] || fail "None editor text handler"
[[ $(user_value 'Default Applications' application/x-shellscript) == hss-tui-editor.desktop ]] || fail "None editor script handler"
[[ $(record_field "$run" text/plain package) == 'none(tui_editor:helix)' ]] || fail "None editor record names the TUI editor"
[[ $(user_value 'Default Applications' inode/directory) == thunar.desktop ]] || fail "Thunar folder handler"
entry="$repo_root/dotfiles/.local/share/applications/hss-tui-editor.desktop"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$entry" || fail "managed desktop entry validates"
fi
grep -Fxq 'MimeType=text/plain;application/x-shellscript;' "$entry" || fail "entry declares text types"
grep -Fxq 'Terminal=false' "$entry" || fail "entry does not request a second terminal"
# Expand Exec exactly as the Desktop Entry Specification defines (string unescape, then
# argument quoting, then %F) and run the resulting argv against the real role scripts.
sandbox="$fixture/launch-home"
mkdir -p "$sandbox/.config/hypr/scripts" "$fixture/launch-bin" "$fixture/files with space"
cp "$repo_root/dotfiles/.config/hypr/scripts/role_exec.sh" "$repo_root/dotfiles/.config/hypr/scripts/term_exec.sh" "$sandbox/.config/hypr/scripts/"
cp "$HSS_ROLES_FILE" "$sandbox/.config/hypr/roles.json"
printf '#!/usr/bin/env bash\nprintf "%%s\\0" "$@" > "$TERMINAL_ARGV_LOG"\n' > "$fixture/launch-bin/foot"
chmod +x "$fixture/launch-bin/foot"
target="$fixture/files with space/notes \$(touch pwned).txt"
: > "$target"
mapfile -d '' exec_argv < <(python3 - "$entry" "$target" <<'PY'
import sys
entry, target = sys.argv[1], sys.argv[2]
value = None
for line in open(entry, encoding="utf-8"):
    if line.startswith("Exec="):
        value = line[len("Exec="):].rstrip("\n")
# String-level unescape (\s \n \t \r \\).
out, i = [], 0
while i < len(value):
    if value[i] == "\\" and i + 1 < len(value):
        out.append({"s": " ", "n": "\n", "t": "\t", "r": "\r", "\\": "\\"}.get(value[i + 1], "\\" + value[i + 1]))
        i += 2
    else:
        out.append(value[i]); i += 1
value = "".join(out)
# Exec argument quoting.
args, cur, i, quoted, started = [], [], 0, False, False
while i < len(value):
    c = value[i]
    if quoted:
        if c == "\\" and i + 1 < len(value) and value[i + 1] in '"`$\\':
            cur.append(value[i + 1]); i += 2; continue
        if c == '"':
            quoted = False; i += 1; continue
        cur.append(c); i += 1; continue
    if c == '"':
        quoted = True; started = True; i += 1; continue
    if c == " ":
        if started or cur:
            args.append("".join(cur)); cur = []; started = False
        i += 1; continue
    cur.append(c); started = True; i += 1
if started or cur:
    args.append("".join(cur))
final = []
for arg in args:
    if arg == "%F":
        final.append(target)
    else:
        final.append(arg)
sys.stdout.write("".join(a + "\0" for a in final))
PY
)
[[ ${exec_argv[0]} == sh && ${exec_argv[1]} == -c && ${exec_argv[3]} == hss-tui-editor ]] || fail "Exec parses to a constant sh -c program"
[[ ${exec_argv[2]} == 'exec "$HOME/.config/hypr/scripts/role_exec.sh" tui_editor -- "$@"' ]] || fail "Exec program text: ${exec_argv[2]}"
(
  cd "$fixture"
  HOME="$sandbox" HSS_ROLES_FILE="$sandbox/.config/hypr/roles.json" TERMINAL_ARGV_LOG="$fixture/terminal.argv" \
    PATH="$fixture/launch-bin:$PATH" "${exec_argv[@]}"
)
mapfile -d '' terminal_argv < "$fixture/terminal.argv"
expected=(--app-id=hss-tui_editor "--title=tui editor" helix "$target")
[[ ${#terminal_argv[@]} == "${#expected[@]}" ]] || fail "terminal argv length: ${terminal_argv[*]}"
for index in "${!expected[@]}"; do
  [[ ${terminal_argv[$index]} == "${expected[$index]}" ]] || fail "terminal argv $index: ${terminal_argv[$index]}"
done
[[ ! -e $fixture/pwned ]] || fail "file name was evaluated"
printf 'ok - GUI editor None associates text with the managed entry, which opens the primary TUI editor in the selected terminal with literal file names\n'

# 6. A missing desktop entry is reported and leaves that association untouched.
new_fixture missing-entry
make_roles "$HSS_ROLES_FILE" brave-bin dolphin kate neovim kitty
output=$(in_setup_run hss_handlers_apply)
[[ $(last_status "$output") == 6 ]] || fail "missing desktop entry exits 6: $output"
grep -Fq 'missing-desktop-entry=3' <<<"$output" || fail "three browser targets missing: $output"
grep -Fq 'brave-browser.desktop is not installed' <<<"$output" || fail "missing entry named"
[[ $(user_value 'Default Applications' x-scheme-handler/http) == '<absent>' ]] || fail "browser association untouched"
[[ $(user_value 'Default Applications' text/plain) == org.kde.kate.desktop ]] || fail "independent targets still applied"
printf 'ok - a missing desktop entry is distinct and does not block independent handlers\n'

# 7. Missing xdg-mime is distinct and changes nothing.
new_fixture missing-xdg-mime
make_roles "$HSS_ROLES_FILE" firefox dolphin kate neovim kitty
nobin="$fixture/nobin"
mkdir -p "$nobin"
for tool in bash jq awk tr cat rm mktemp mkdir timeout sha256sum readlink dirname basename date head od flock sed grep cp chmod sync mv sleep kill wc find; do
  real=$(command -v "$tool") || continue
  ln -s "$real" "$nobin/$tool"
done
before=$(sha256sum < "$XDG_CONFIG_HOME/mimeapps.list")
output=$(PATH="$nobin" in_setup_run hss_handlers_apply)
[[ $(last_status "$output") == 6 ]] || fail "missing xdg-mime exits 6: $output"
grep -Fq 'missing-dependency=6' <<<"$output" || fail "every target reports missing xdg-mime: $output"
[[ $(sha256sum < "$XDG_CONFIG_HOME/mimeapps.list") == "$before" ]] || fail "associations changed without xdg-mime"
printf 'ok - missing xdg-mime is reported separately and changes nothing\n'

# 8. An xdg-mime failure is distinct from a mismatch.
new_fixture apply-failure
make_roles "$HSS_ROLES_FILE" firefox dolphin kate neovim kitty
before=$(sha256sum < "$XDG_CONFIG_HOME/mimeapps.list")
output=$(XDG_MIME_STUB_MODE=fail in_setup_run hss_handlers_apply)
[[ $(last_status "$output") == 1 ]] || fail "apply failure exits 1: $output"
grep -Fq 'failed=6' <<<"$output" || fail "failures reported: $output"
[[ $(sha256sum < "$XDG_CONFIG_HOME/mimeapps.list") == "$before" ]] || fail "failed apply changed associations"
printf 'ok - a failing xdg-mime default is reported as failed\n'

# 9. Success without an effective change is a mismatch, never success.
new_fixture lying-double
make_roles "$HSS_ROLES_FILE" firefox dolphin kate neovim kitty
output=$(XDG_MIME_STUB_MODE=noop in_setup_run hss_handlers_apply)
[[ $(last_status "$output") == 10 ]] || fail "no-op xdg-mime is a mismatch: $output"
grep -Fq 'mismatch=6' <<<"$output" || fail "mismatches reported: $output"
new_fixture desktop-override
make_roles "$HSS_ROLES_FILE" firefox dolphin kate neovim kitty
printf '[Default Applications]\ninode/directory=org.gnome.Nautilus.desktop\n' > "$XDG_CONFIG_HOME/hyprland-mimeapps.list"
output=$(XDG_CURRENT_DESKTOP=Hyprland in_setup_run hss_handlers_apply)
[[ $(last_status "$output") == 10 ]] || fail "desktop-specific override is a mismatch: $output"
grep -Fq 'mismatch=1' <<<"$output" || fail "one mismatch: $output"
grep -Fq 'inode/directory is still org.gnome.Nautilus.desktop' <<<"$output" || fail "mismatch names the effective handler"
printf 'ok - an effective-handler mismatch is detected after a reported success\n'

# 10. Unverified desktop IDs, invalid catalog metadata, role None and missing role data.
new_fixture metadata
make_roles "$HSS_ROLES_FILE" firefox dolphin kate neovim kitty
jq '.roles.browser.package = "unknown-browser" | .roles.file_manager.desktop_file = "$(touch pwned).desktop"' \
  "$HSS_ROLES_FILE" > "$fixture/roles.tmp" && mv "$fixture/roles.tmp" "$HSS_ROLES_FILE"
output=$(in_setup_run hss_handlers_apply)
[[ $(last_status "$output") == 5 ]] || fail "unsupported metadata exits 5: $output"
grep -Fq 'unsupported=3' <<<"$output" || fail "unknown browser is unsupported: $output"
grep -Fq 'invalid=1' <<<"$output" || fail "unsafe desktop ID rejected: $output"
[[ ! -e $fixture/pwned && ! -e $PWD/pwned ]] || fail "desktop ID was evaluated"
jq '.roles.tui_editor = null | .roles.gui_editor = null' "$HSS_ROLES_FILE" > "$fixture/roles.tmp" && mv "$fixture/roles.tmp" "$HSS_ROLES_FILE"
output=$(in_setup_run hss_handlers_preview)
grep -Fq 'text/plain: - -> - (disabled)' <<<"$output" || fail "None without TUI editor is disabled: $output"
rm -f "$HSS_ROLES_FILE"
output=$(in_setup_run hss_handlers_preview)
grep -Fq 'x-scheme-handler/http: - -> - (unavailable)' <<<"$output" || fail "missing role data is unavailable: $output"
printf 'ok - unverified, unsafe, disabled and unavailable role metadata never reach xdg-mime\n'

# 11. Dry runs and the configure entry point only preview.
new_fixture dry-run
make_roles "$HSS_ROLES_FILE" firefox dolphin kate neovim kitty
before=$(sha256sum < "$XDG_CONFIG_HOME/mimeapps.list")
output=$(DRY_RUN=true in_setup_run hss_handlers_configure)
[[ $(last_status "$output") == 0 ]] || fail "dry run exits 0"
[[ $(sha256sum < "$XDG_CONFIG_HOME/mimeapps.list") == "$before" && $(calls_with default) == 0 ]] || fail "dry run changed associations"
output=$(HSS_HANDLERS_MODE=skip in_setup_run hss_handlers_configure)
[[ $(calls_with default) == 0 ]] || fail "skip mode applied handlers"
output=$(in_setup_run hss_handlers_configure)
[[ $(last_status "$output") == 0 && $(calls_with default) == 6 ]] || fail "configure applies by default: $output"
printf 'ok - dry run and skip mode never change associations; configure applies the approved selection\n'

# 12. The real xdg-utils CLI (when installed) writes, reads back and is restored.
if real_xdg_mime=$(PATH=$system_path command -v xdg-mime); then
  new_fixture real-xdg-utils
  make_roles "$HSS_ROLES_FILE" firefox dolphin kate neovim kitty
  output=$(PATH=$system_path in_setup_run hss_handlers_apply)
  [[ $(last_status "$output") == 0 ]] || fail "real xdg-mime apply: $output"
  grep -Fq 'summary=applied=6' <<<"$output" || fail "real xdg-mime applies six targets: $output"
  run=$(last_run "$output")
  [[ $(user_value 'Default Applications' x-scheme-handler/https) == firefox.desktop ]] || fail "real xdg-mime https entry"
  [[ $(user_value 'Default Applications' inode/directory) == org.kde.dolphin.desktop ]] || fail "real xdg-mime folder entry"
  [[ $(PATH=$system_path "$real_xdg_mime" query default text/plain) == org.kde.kate.desktop ]] || fail "real xdg-mime reads back the text handler"
  output=$(PATH=$system_path in_setup_run hss_handlers_restore "$run")
  [[ $(last_status "$output") == 0 ]] || fail "real xdg-mime restore status: $output"
  grep -Fq 'restored=6' <<<"$output" || fail "real xdg-mime restore count: $output"
  [[ $(user_value 'Default Applications' text/plain) == org.gnome.TextEditor.desktop ]] || fail "real restore of the previous text default"
  [[ $(user_value 'Default Applications' x-scheme-handler/http) == '<absent>' ]] || fail "real restore of absence"
  printf 'ok - the real xdg-mime CLI applies, reads back and restores the associations\n'
else
  printf 'ok - xdg-utils is not installed here; the stateful double covers the contract (skipped)\n'
fi

bash -n "$repo_root/scripts/lib/setup-handlers.sh"
