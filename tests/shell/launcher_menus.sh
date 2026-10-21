#!/usr/bin/env bash
set -euo pipefail

# D02.2/D02.5: shared chooser contract (menu_choose.sh) across all five launchers and the
# identity-safe repository picker. Launchers are stateful doubles that record argv and the
# exact stdin they were shown, and answer like the real launcher would (text or 0-based
# index output, launcher-specific cancel status). Evidence: capabilities.d/d02-launchers.json.

unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY BEMENU_OPTS
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
scripts="$repo_root/dotfiles/.config/hypr/scripts"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export HOME="$fixture/home" XDG_CONFIG_HOME="$fixture/home/.config" XDG_STATE_HOME="$fixture/state"
export STUB_LOG="$fixture/stub.log" LAUNCHER_STATE="$fixture/launcher"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$LAUNCHER_STATE" "$fixture/bin"
: > "$STUB_LOG"
launcher_log="$XDG_STATE_HOME/hyprland-simple-setup/apps/launcher.log"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

cat > "$fixture/bin/launcher-double" <<'STUB'
#!/usr/bin/env bash
# Stateful launcher double: records argv/stdin/env and answers according to LAUNCHER_ACTION.
set -u
name=${0##*/}
state=${LAUNCHER_STATE:?}
count=$(( $(cat "$state/count" 2>/dev/null || printf 0) + 1 ))
printf '%s' "$count" > "$state/count"
printf '%s\0' "$name" "$@" > "$state/argv"
printf '%s' "${BEMENU_BACKEND-unset}" > "$state/backend"
printf '%s' "${BEMENU_OPTS-unset}" > "$state/opts"
mapfile -t lines
printf '%s\n' "${lines[@]}" > "$state/stdin"
mode=text
args=("$@")
for index in "${!args[@]}"; do
    [[ ${args[$index]} == --index ]] && mode=index
    [[ ${args[$index]} == -format && ${args[$((index + 1))]:-} == i ]] && mode=index
done
cancel=1
[[ $name == fuzzel ]] && cancel=2
[[ -z ${LAUNCHER_REMOVE:-} ]] || rm -rf -- "$LAUNCHER_REMOVE"
printf '%s diagnostic\n' "$name" >&2
action=${LAUNCHER_ACTION:-cancel}
case "$action" in
    cancel) exit "$cancel" ;;
    fail:*) printf 'simulated launcher failure\n' >&2; exit "${action#fail:}" ;;
    empty) exit 0 ;;
    raw:*) printf '%s\n' "${action#raw:}"; exit 0 ;;
    multi) printf '%s\n%s\n' "${lines[0]}" "${lines[1]}"; exit 0 ;;
    nth:*)
        index=${action#nth:}
        if [[ $mode == index ]]; then printf '%s\n' "$index"; else printf '%s\n' "${lines[$index]}"; fi
        exit 0
        ;;
    pick:*)
        wanted=${action#pick:}
        for index in "${!lines[@]}"; do
            if [[ ${lines[$index]} == "$wanted" ]]; then
                if [[ $mode == index ]]; then printf '%s\n' "$index"; else printf '%s\n' "${lines[$index]}"; fi
                exit 0
            fi
        done
        # Not an offered row: a typed custom entry (index launchers print -1).
        if [[ $mode == index ]]; then printf -- '-1\n'; else printf '%s\n' "$wanted"; fi
        exit 0
        ;;
esac
exit 99
STUB
chmod +x "$fixture/bin/launcher-double"
for executable in wofi rofi fuzzel bemenu bemenu-run tofi tofi-drun tofi-run; do
    ln -s launcher-double "$fixture/bin/$executable"
done
export PATH="$fixture/bin:$PATH"

write_roles() {
    local package=$1
    export HSS_ROLES_FILE="$fixture/roles-$package.json"
    jq --arg package "$package" --arg home "$HOME" '
        def pick($role; $name): .roles[$role].options[] | select(.package == $name);
        {schema_version: 2,
         roles: {launcher: pick("launcher"; $package), terminal: pick("terminal"; "kitty"), tui_editor: pick("tui_editor"; "neovim")},
         selected: {launcher: [pick("launcher"; $package)]}}
        | walk(if type == "string" and startswith("{HOME}/") then $home + ltrimstr("{HOME}") else . end)
    ' "$repo_root/packages.json" > "$HSS_ROLES_FILE"
}

reset_double() {
    rm -f -- "$LAUNCHER_STATE"/*
}

calls() {
    cat "$LAUNCHER_STATE/count" 2>/dev/null || printf 0
}

# choose ACTION PROMPT [menu_choose args...] < records: sets out and status.
choose() {
    local action=$1
    shift
    reset_double
    status=0
    out=$(LAUNCHER_ACTION=$action "$scripts/menu_choose.sh" "$@") || status=$?
}

assert_shown() {
    local expected=$1 description=$2
    [[ $(<"$LAUNCHER_STATE/stdin") == "$expected" ]] || {
        printf 'shown:\n%s\n' "$(<"$LAUNCHER_STATE/stdin")" >&2
        fail "$description: launcher was shown unexpected rows"
    }
}

assert_argv_has() {
    local description=$1 expected
    shift
    local -a argv=()
    mapfile -d '' argv < "$LAUNCHER_STATE/argv"
    for expected in "$@"; do
        local found=false item
        for item in "${argv[@]}"; do
            [[ $item == "$expected" ]] && found=true
        done
        $found || fail "$description: launcher argv lacks '$expected' (got: ${argv[*]})"
    done
}

records=$'a\tAlpha\nb\tBeta'
for package in wofi rofi fuzzel bemenu tofi; do
    write_roles "$package"
    dmenu=$(jq -r '.roles.launcher.dmenu_executable' "$HSS_ROLES_FILE")

    choose pick:Beta --prompt Choose <<<"$records"
    [[ $status == 0 && $out == b ]] || fail "$package: selecting Beta returned status $status output '$out'"
    assert_shown $'Alpha\nBeta' "$package selection"
    mapfile -d '' argv < "$LAUNCHER_STATE/argv"
    [[ ${argv[0]} == "$dmenu" ]] || fail "$package: chooser did not use the dmenu executable"
    case "$package" in
        wofi) assert_argv_has wofi --dmenu --prompt=Choose --cache-file=/dev/null \
            --define=allow_markup=false --define=allow_images=false ;;
        rofi) assert_argv_has rofi -dmenu -p Choose -format i -no-custom -no-markup-rows ;;
        fuzzel) assert_argv_has fuzzel --dmenu '--prompt=Choose: ' --index --only-match --cache=/dev/null ;;
        bemenu)
            assert_argv_has bemenu -p Choose
            [[ $(<"$LAUNCHER_STATE/backend") == wayland ]] || fail "bemenu chooser does not force the Wayland backend"
            ;;
        tofi) assert_argv_has tofi '--prompt-text=Choose: ' --require-match=true ;;
    esac

    # Repeated labels stay distinguishable without stealing a natural "(2)" label.
    dup=$'r1\tRepo\nr2\tRepo\nr3\tRepo (2)\nr4\tRepo'
    choose 'pick:Repo (3)' --prompt Repos <<<"$dup"
    assert_shown $'Repo\nRepo (3)\nRepo (2)\nRepo (4)' "$package duplicates"
    [[ $status == 0 && $out == r2 ]] || fail "$package: duplicate label did not map to its own ID"
    choose 'pick:Repo (2)' --prompt Repos <<<"$dup"
    [[ $status == 0 && $out == r3 ]] || fail "$package: natural '(2)' label lost its identity"
    choose 'pick:Repo (4)' --prompt Repos <<<"$dup"
    [[ $status == 0 && $out == r4 ]] || fail "$package: third duplicate lost its identity"

    # Hostile labels are display text only: no execution, no control or bidi characters.
    # shellcheck disable=SC2016 # literal shell syntax is the payload under test
    hostile=$'h1\t$(touch '"$fixture"$'/pwned) `id`\nh2\t<b>bold</b> &amp; img:/etc/passwd:text:x\nh3\t  a\rb\x01c\xe2\x80\xaed  \nh4\t\x1b[31mred\x7f'
    # shellcheck disable=SC2016
    choose 'pick:$(touch '"$fixture"'/pwned) `id`' --prompt Hostile <<<"$hostile"
    [[ $status == 0 && $out == h1 ]] || fail "$package: hostile shell label not selectable by identity"
    [[ ! -e $fixture/pwned ]] || fail "$package: label text was executed"
    shown=$(<"$LAUNCHER_STATE/stdin")
    shown=${shown//$'\n'/}
    [[ $shown != *[$'\x01'-$'\x1f']* && $shown != *$'\x7f'* && $shown != *$'\xe2\x80\xae'* ]] \
        || fail "$package: control or bidi characters reached the launcher"
    # shellcheck disable=SC2016
    assert_shown $'$(touch '"$fixture"$'/pwned) `id`\n<b>bold</b> &amp; img:/etc/passwd:text:x\na bcd\n[31mred' "$package hostile labels"
    choose 'pick:a bcd' --prompt Hostile <<<"$hostile"
    [[ $status == 0 && $out == h3 ]] || fail "$package: sanitized label did not map back to its ID"

    choose cancel --prompt Choose <<<"$records"
    [[ $status == 3 && -z $out ]] || fail "$package: cancellation returned status $status output '$out'"
    choose empty --prompt Choose <<<"$records"
    [[ $status == 3 && -z $out ]] || fail "$package: empty selection is not a cancellation"
    choose 'raw:Not offered' --prompt Choose <<<"$records"
    [[ $status == 1 && -z $out ]] || fail "$package: unoffered output was accepted"
    choose pick:Bet --prompt Choose <<<"$records"
    [[ $status == 1 && -z $out ]] || fail "$package: a typed partial label was fuzzy-matched"
    choose multi --prompt Choose <<<"$records"
    [[ $status == 1 && -z $out ]] || fail "$package: multi-line output was accepted"
    choose fail:42 --prompt Choose <<<"$records"
    [[ $status == 1 && -z $out ]] || fail "$package: launcher failure returned status $status"
    grep -Fq 'simulated launcher failure' "$launcher_log" || fail "$package: launcher stderr not kept in the launcher log"

    # Confirmation: stdin is ignored, No is offered first, only Yes is consent.
    choose pick:Yes --prompt 'Log out?' --confirm <<<$'ignored\tStdin'
    assert_shown $'No\nYes' "$package confirmation rows"
    [[ $status == 0 && $out == yes ]] || fail "$package: confirming Yes returned $status"
    choose pick:No --prompt 'Log out?' --confirm </dev/null
    [[ $status == 3 && -z $out ]] || fail "$package: declining returned $status"
    choose nth:0 --prompt 'Log out?' --confirm </dev/null
    [[ $status == 3 ]] || fail "$package: the first (default) confirmation row is not No"
    choose pick:yes --prompt 'Log out?' --confirm </dev/null
    [[ $status == 1 ]] || fail "$package: typed text implied consent"
    choose cancel --prompt 'Log out?' --confirm </dev/null
    [[ $status == 3 ]] || fail "$package: cancelled confirmation is not a cancellation"
    printf 'ok - %s chooser: identity, duplicates, hostile labels, cancel, invalid output, failure and confirmation\n' "$package"
done

# Index launchers: indices outside the offered records are failures.
write_roles rofi
choose raw:2 --prompt Choose <<<"$records"
[[ $status == 1 ]] || fail "rofi: out-of-range index accepted"
choose raw:99999999999999999999 --prompt Choose <<<"$records"
[[ $status == 1 ]] || fail "rofi: overflowing index accepted"
write_roles fuzzel
choose raw:-1 --prompt Choose <<<"$records"
[[ $status == 1 ]] || fail "fuzzel: custom-entry index accepted"
choose raw:1 --prompt Choose <<<"$records"
[[ $status == 0 && $out == b ]] || fail "fuzzel: index output not mapped"
printf 'ok - index launchers refuse custom, out-of-range and overflowing indices\n'

# Invalid requests never open the launcher.
write_roles wofi
for request in 'no-prompt' 'bad-id' 'dup-id' 'no-tab' 'empty-label' 'no-records' 'blank-prompt'; do
    reset_double
    status=0
    case "$request" in
        no-prompt) LAUNCHER_ACTION=nth:0 "$scripts/menu_choose.sh" <<<"$records" >/dev/null 2>&1 || status=$? ;;
        bad-id) LAUNCHER_ACTION=nth:0 "$scripts/menu_choose.sh" --prompt P <<<$'a b\tAlpha' >/dev/null 2>&1 || status=$? ;;
        dup-id) LAUNCHER_ACTION=nth:0 "$scripts/menu_choose.sh" --prompt P <<<$'a\tAlpha\na\tBeta' >/dev/null 2>&1 || status=$? ;;
        no-tab) LAUNCHER_ACTION=nth:0 "$scripts/menu_choose.sh" --prompt P <<<'Alpha' >/dev/null 2>&1 || status=$? ;;
        empty-label) LAUNCHER_ACTION=nth:0 "$scripts/menu_choose.sh" --prompt P <<<$'a\t \x01 ' >/dev/null 2>&1 || status=$? ;;
        no-records) LAUNCHER_ACTION=nth:0 "$scripts/menu_choose.sh" --prompt P </dev/null >/dev/null 2>&1 || status=$? ;;
        blank-prompt) LAUNCHER_ACTION=nth:0 "$scripts/menu_choose.sh" --prompt ' ' <<<"$records" >/dev/null 2>&1 || status=$? ;;
    esac
    [[ $status == 2 ]] || fail "invalid request $request returned $status"
    [[ $(calls) == 0 ]] || fail "invalid request $request opened the launcher"
done
printf 'ok - invalid requests exit 2 without opening the launcher\n'

# Missing role data or launcher executable is a failure, not a cancellation.
rm "$fixture/bin/wofi"
choose nth:0 --prompt Choose <<<"$records"
[[ $status == 1 && $(calls) == 0 ]] || fail "missing launcher returned $status"
ln -s launcher-double "$fixture/bin/wofi"
HSS_ROLES_FILE="$fixture/missing.json" choose nth:0 --prompt Choose <<<"$records"
[[ $status == 1 ]] || fail "missing role data returned $status"
printf 'ok - missing launcher or role data is a failure\n'

# Privacy: labels and selections never reach the launcher log or legacy stdout channels.
write_roles wofi
choose 'pick:Secret repository' --prompt Choose <<<$'s\tSecret repository'
[[ $out == s ]] || fail "privacy fixture selection failed"
if grep -Fq 'Secret repository' "$launcher_log"; then
    fail "chooser labels leaked into the launcher log"
fi
printf 'ok - chooser labels and selections stay out of logs\n'

# Bemenu appearance comes from the generated options file unless the user set BEMENU_OPTS.
write_roles bemenu
mkdir -p "$XDG_CONFIG_HOME/hss-theme/generated/bemenu"
printf '%s\n' "--fn 'Noto Sans 10' --nb '#1e1e2e'" > "$XDG_CONFIG_HOME/hss-theme/generated/bemenu/bemenu.opts"
choose pick:Alpha --prompt Choose <<<"$records"
[[ $(<"$LAUNCHER_STATE/opts") == "--fn 'Noto Sans 10' --nb '#1e1e2e'" ]] || fail "generated bemenu options were not exported"
reset_double
BEMENU_OPTS='--fn Custom' LAUNCHER_ACTION=pick:Alpha "$scripts/menu_choose.sh" --prompt Choose <<<"$records" >/dev/null
[[ $(<"$LAUNCHER_STATE/opts") == '--fn Custom' ]] || fail "user BEMENU_OPTS was overridden"
reset_double
"$scripts/menu_exec.sh" </dev/null >/dev/null 2>&1 || true
[[ $(<"$LAUNCHER_STATE/opts") == "--fn 'Noto Sans 10' --nb '#1e1e2e'" ]] || fail "bemenu-run did not receive the generated options"
mapfile -d '' argv < "$LAUNCHER_STATE/argv"
[[ ${#argv[@]} == 1 && ${argv[0]} == bemenu-run ]] || fail "menu_exec.sh normal argv changed for bemenu"
printf 'ok - bemenu receives themed BEMENU_OPTS and a user value wins\n'

# ---------------------------------------------------------------------------
# D02.5 repository picker: identity-safe selection with preserved routes.

installed="$HOME/.config/hypr/scripts"
mkdir -p "$installed"
for item in menu_choose.sh menu_exec.sh app_log.sh lib; do
    ln -s "$scripts/$item" "$installed/$item"
done
cat > "$installed/term_exec.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$PWD" "$@" > "$TERM_LOG"
STUB
chmod +x "$installed/term_exec.sh"
export TERM_LOG="$fixture/term.log"

# fd double: honors --max-depth and the root, records argv so exclusions stay asserted.
cat > "$fixture/bin/fd" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$FD_LOG"
depth=6
args=("$@")
for index in "${!args[@]}"; do
    [[ ${args[$index]} == --max-depth ]] && depth=${args[$((index + 1))]}
done
root=${args[-1]}
find "$root" -mindepth 1 -maxdepth "$depth" -type d -name .git -print0
STUB
chmod +x "$fixture/bin/fd"
export FD_LOG="$fixture/fd.log"

repos="$fixture/repos"
mkdir -p "$HOME/GitHub/proj/.git" "$repos/other/Github/proj/.git" "$HOME/GitHub/proj (2)/.git" \
    "$HOME/GitHub/new"$'\n'"line/.git" "$HOME/GitHub/deep/a/b/c/d/e/f/.git"
expected_paths=("$HOME/GitHub/proj" "$repos/other/Github/proj" "$HOME/GitHub/proj (2)" "$HOME/GitHub/new"$'\n'"line")
export REPOS_WOFI_ROOTS="$HOME/GitHub:$repos/other"
write_roles wofi

pick_repo() {
    local action=$1
    reset_double
    rm -f -- "$TERM_LOG"
    status=0
    LAUNCHER_ACTION=$action "$scripts/repos_wofi.sh" >/dev/null 2>"$fixture/repos.err" || status=$?
}

pick_repo cancel
[[ $status == 0 && ! -e $TERM_LOG ]] || fail "repository cancel launched something (status $status)"
mapfile -t shown < "$LAUNCHER_STATE/stdin"
((${#shown[@]} == ${#expected_paths[@]})) || fail "repository picker offered ${#shown[@]} rows, expected ${#expected_paths[@]}"
[[ $(printf '%s\n' "${shown[@]}" | sort | uniq -d) == "" ]] || fail "repository labels collide"
printf '%s\n' "${shown[@]}" | grep -Fxq 'new line' || fail "newline path label not sanitized"
mapfile -d '' fd_argv < "$FD_LOG"
for expected in -H -I -t d --max-depth 6 .cache .claude .cargo .local proc sys dev run tmp System_BackUp -0 '^\.git$'; do
    printf '%s\n' "${fd_argv[@]}" | grep -Fxq -- "$expected" || fail "repository discovery lost fd argument '$expected'"
done
printf 'ok - repository picker cancel launches nothing; labels are unique and discovery argv is preserved\n'

declare -A reached=()
for index in "${!shown[@]}"; do
    pick_repo "nth:$index"
    [[ $status == 0 && -e $TERM_LOG ]] || fail "repository row $index did not open (status $status)"
    mapfile -d '' term < "$TERM_LOG"
    [[ ${term[1]} == --app-id && ${term[2]} == hss-repos && ${term[3]} == --title \
        && ${term[4]} == "$(basename -- "${term[0]}")" && ${term[5]} == -- && ${term[6]} == nvim && ${term[7]} == . ]] \
        || fail "repository terminal route changed: ${term[*]}"
    reached[${term[0]}]=1
done
for path in "${expected_paths[@]}"; do
    [[ -n ${reached[$path]+x} ]] || fail "repository $path was not reachable by its own row"
done
printf 'ok - every repository, including duplicate and newline names, opens its own directory with the selected editor\n'

pick_repo 'raw:proj (9)'
[[ $status == 1 && ! -e $TERM_LOG ]] || fail "unoffered repository selection was accepted"
pick_repo fail:5
[[ $status == 1 && ! -e $TERM_LOG ]] || fail "launcher failure was collapsed into success (status $status)"
grep -Fq 'Repository selection failed' "$STUB_LOG" || fail "launcher failure was not shown to the user"
LAUNCHER_REMOVE="$HOME/GitHub/proj (2)" pick_repo 'pick:proj (2)'
[[ $status == 1 && ! -e $TERM_LOG ]] || fail "vanished repository was opened"
grep -Fq 'Chosen repo directory not found' "$fixture/repos.err" || fail "vanished repository error not reported"
printf 'ok - invalid selections, launcher failures and vanished repositories are visible failures\n'

REPOS_WOFI_ROOTS="$fixture/empty" pick_repo nth:0
[[ $status == 1 && $(calls) == 0 ]] || fail "empty discovery opened the launcher"
grep -Fq 'No git repos found' "$STUB_LOG" || fail "discovery failure was not shown to the user"
printf 'ok - discovery failures are reported without opening a menu\n'
