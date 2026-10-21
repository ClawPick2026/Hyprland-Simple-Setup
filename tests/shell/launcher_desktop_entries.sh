#!/usr/bin/env bash
set -euo pipefail

# D02.3: menu.applications (native desktop-application mode) and menu.commands (native
# executable search) for all five launchers through action_exec.sh. The provider must use
# only native launcher modes: it never reads desktop entries itself, never substitutes another
# mode, and Bemenu's missing desktop-application mode is an explained `unsupported` outcome.
# Real-launcher desktop-entry behavior (NoDisplay/Hidden/TryExec/OnlyShowIn/shadowing) is
# recorded as evidence in capabilities.d/d02-launchers.json; here the synthetic entries only
# prove that the provider passes the XDG environment through untouched.

unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY BEMENU_OPTS
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
scripts="$repo_root/dotfiles/.config/hypr/scripts"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export HOME="$fixture/home" XDG_CONFIG_HOME="$fixture/home/.config" XDG_STATE_HOME="$fixture/state"
export XDG_DATA_HOME="$fixture/data" XDG_DATA_DIRS="$fixture/sysdata"
export STUB_LOG="$fixture/stub.log" LAUNCHER_STATE="$fixture/launcher"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$LAUNCHER_STATE" "$fixture/bin" \
    "$XDG_DATA_HOME/applications" "$XDG_DATA_DIRS/applications"
: > "$STUB_LOG"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

# Synthetic entries, including ones a conforming launcher must hide. They are fixtures for
# the environment check; the provider must not open them.
printf '[Desktop Entry]\nType=Application\nName=HssVisible\nExec=hss-visible\n' > "$XDG_DATA_HOME/applications/hss-visible.desktop"
printf '[Desktop Entry]\nType=Application\nName=HssHidden\nNoDisplay=true\nExec=hss-hidden\n' > "$XDG_DATA_HOME/applications/hss-hidden.desktop"
printf '[Desktop Entry]\nType=Application\nName=HssShadow\nExec=hss-system\n' > "$XDG_DATA_DIRS/applications/hss-shadow.desktop"

cat > "$fixture/bin/launcher-double" <<'STUB'
#!/usr/bin/env bash
set -u
state=${LAUNCHER_STATE:?}
count=$(( $(cat "$state/count" 2>/dev/null || printf 0) + 1 ))
printf '%s' "$count" > "$state/count"
printf '%s\0' "${0##*/}" "$@" > "$state/argv"
printf '%s\0' "${BEMENU_BACKEND-unset}" "${XDG_DATA_HOME-unset}" "${XDG_DATA_DIRS-unset}" > "$state/env"
cancel=1
[[ ${0##*/} == fuzzel ]] && cancel=2
case "${LAUNCHER_ACTION:-select}" in
    select) [[ -z ${LAUNCHER_PRINT:-} ]] || printf '%s\n' "$LAUNCHER_PRINT"; exit 0 ;;
    cancel) exit "$cancel" ;;
    fail) printf 'simulated launcher failure\n' >&2; exit 42 ;;
esac
STUB
chmod +x "$fixture/bin/launcher-double"
for executable in wofi rofi fuzzel bemenu bemenu-run tofi tofi-drun tofi-run; do
    ln -s launcher-double "$fixture/bin/$executable"
done
cat > "$fixture/bin/hss-probe-tool" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$#" > "$PROBE_LOG"
STUB
chmod +x "$fixture/bin/hss-probe-tool"
export PROBE_LOG="$fixture/probe.log"
export PATH="$fixture/bin:$PATH"

write_roles() {
    local package=$1
    export HSS_ROLES_FILE="$fixture/roles-$package.json"
    jq --arg package "$package" --arg home "$HOME" '
        def pick($role; $name): .roles[$role].options[] | select(.package == $name);
        {schema_version: 2, roles: {launcher: pick("launcher"; $package)}, selected: {launcher: [pick("launcher"; $package)]}}
        | walk(if type == "string" and startswith("{HOME}/") then $home + ltrimstr("{HOME}") else . end)
    ' "$repo_root/packages.json" > "$HSS_ROLES_FILE"
}

# act ACTION: run action_exec.sh --json; sets envelope and status.
# expect STATUS OUTCOME MESSAGE: the last act returned STATUS with that outcome.
expect() {
    if [[ $status != "$1" ]] || ! jq -e --arg o "$2" '.outcome == $o' <<<"$envelope" >/dev/null; then
        fail "$3 (status $status): $envelope"
    fi
}

act() {
    rm -f -- "$LAUNCHER_STATE"/*
    status=0
    envelope=$("$scripts/action_exec.sh" --json "$@" 2>/dev/null) || status=$?
    jq -e 'type == "object" and .schema == 1' <<<"$envelope" >/dev/null || fail "$*: no result envelope: $envelope"
}

argv_is() {
    local description=$1
    shift
    local -a actual=()
    [[ -s $LAUNCHER_STATE/argv ]] || fail "$description: launcher was not started"
    mapfile -d '' actual < "$LAUNCHER_STATE/argv"
    [[ ${actual[*]} == "$*" && ${#actual[@]} == "$#" ]] || fail "$description: argv '${actual[*]}', expected '$*'"
}

declare -A applications=(
    [wofi]="wofi --show drun --style $HOME/.config/wofi/menu.css"
    [rofi]="rofi -show drun"
    [fuzzel]="fuzzel"
    [tofi]="tofi-drun --drun-launch=true"
)
declare -A commands=(
    [wofi]="wofi --show run --style $HOME/.config/wofi/menu.css"
    [rofi]="rofi -show run"
    [fuzzel]="fuzzel --list-executables-in-path"
    [bemenu]="bemenu-run"
)

for package in wofi rofi fuzzel tofi; do
    write_roles "$package"
    LAUNCHER_ACTION=select act menu.applications
    [[ $status == 0 ]] || fail "$package menu.applications returned $status"
    jq -e --arg p "$package" '.outcome == "accepted" and .provider == $p and .action == "menu.applications"' <<<"$envelope" >/dev/null \
        || fail "$package menu.applications envelope: $envelope"
    # shellcheck disable=SC2086 # expected argv words are space-free except the style path
    argv_is "$package applications" ${applications[$package]}
    mapfile -d '' env_seen < "$LAUNCHER_STATE/env"
    [[ ${env_seen[1]} == "$XDG_DATA_HOME" && ${env_seen[2]} == "$XDG_DATA_DIRS" ]] \
        || fail "$package applications: XDG data directories were not passed through"
    # Super+Space keeps its meaning: the legacy toggle route opens the very same argv.
    rm -f -- "$LAUNCHER_STATE"/*
    "$scripts/menu_exec.sh" </dev/null >/dev/null 2>&1
    # shellcheck disable=SC2086
    argv_is "$package legacy route" ${applications[$package]}

    LAUNCHER_ACTION=cancel act menu.applications
    expect 3 cancelled "$package applications cancel"
    LAUNCHER_ACTION=fail act menu.applications
    expect 1 failed "$package applications failure"
done
printf 'ok - wofi, rofi, fuzzel and tofi open their native desktop-application mode with the catalog argv\n'

write_roles bemenu
act menu.applications
[[ $status == 5 ]] || fail "bemenu menu.applications returned $status"
jq -e '.outcome == "unsupported" and .provider == "bemenu" and (.reason | test("no native desktop-application mode"))' <<<"$envelope" >/dev/null \
    || fail "bemenu unsupported envelope: $envelope"
[[ ! -e $LAUNCHER_STATE/count ]] || fail "bemenu applications silently opened another mode"
rm -f -- "$LAUNCHER_STATE"/*
"$scripts/action_exec.sh" menu.applications >/dev/null 2>"$fixture/err" && fail "bemenu applications succeeded without --json"
grep -Fq 'menu.applications: unsupported' "$STUB_LOG" || fail "bemenu limitation was not explained to the user"
[[ ! -e $LAUNCHER_STATE/count ]] || fail "bemenu applications opened a launcher without --json"
printf 'ok - bemenu desktop-application action is unsupported, explained and opens nothing\n'

for package in wofi rofi fuzzel bemenu; do
    write_roles "$package"
    LAUNCHER_ACTION=select act menu.commands
    expect 0 accepted "$package menu.commands"
    # shellcheck disable=SC2086
    argv_is "$package commands" ${commands[$package]}
    if [[ $package == bemenu ]]; then
        mapfile -d '' env_seen < "$LAUNCHER_STATE/env"
        [[ ${env_seen[0]} == wayland ]] || fail "bemenu-run lost the Wayland backend"
    fi
    LAUNCHER_ACTION=cancel act menu.commands
    [[ $status == 3 ]] || fail "$package commands cancel returned $status"
done
printf 'ok - wofi, rofi, fuzzel and bemenu open their native executable search\n'

write_roles tofi
LAUNCHER_ACTION=select LAUNCHER_PRINT=hss-probe-tool act menu.commands
expect 0 accepted "tofi-run selection"
argv_is "tofi commands" tofi-run --require-match=true
for _ in $(seq 1 50); do
    [[ -e $PROBE_LOG ]] && break
    sleep 0.1
done
[[ -e $PROBE_LOG && $(<"$PROBE_LOG") == 0 ]] || fail "tofi-run selection was not started as one argv element"
for bad in '../hss-probe-tool' 'hss-probe-tool --flag' '-hss' 'hss-not-installed'; do
    rm -f -- "$PROBE_LOG"
    LAUNCHER_ACTION=select LAUNCHER_PRINT=$bad act menu.commands
    [[ $status == 1 && ! -e $PROBE_LOG ]] || fail "tofi-run selection '$bad' was executed (status $status)"
done
LAUNCHER_ACTION=cancel act menu.commands
[[ $status == 3 ]] || fail "tofi-run cancel returned $status"
LAUNCHER_ACTION=select LAUNCHER_PRINT='' act menu.commands
[[ $status == 3 ]] || fail "empty tofi-run selection returned $status"
printf 'ok - tofi-run starts only the printed executable that resolves on PATH\n'

write_roles wofi
rm "$fixture/bin/wofi"
act menu.applications
expect 6 missing-dependency "missing wofi"
act menu.commands
[[ $status == 6 ]] || fail "missing wofi commands returned $status"
ln -s launcher-double "$fixture/bin/wofi"
HSS_ROLES_FILE="$fixture/none.json" act menu.applications
expect 7 unavailable "missing role data"
act menu.applications extra
[[ $status == 2 ]] || fail "unexpected argument accepted"
printf 'ok - missing launcher, missing role data and bad arguments have distinct outcomes\n'

for package in wofi rofi fuzzel bemenu tofi; do
    write_roles "$package"
    status_json=$("$scripts/status_read.sh" menu)
    case "$package" in
        bemenu) expected='{"applications":"unsupported","commands":"supported"}' ;;
        fuzzel) expected='{"applications":"supported","commands":"partial"}' ;;
        *) expected='{"applications":"supported","commands":"supported"}' ;;
    esac
    jq -e --arg p "$package" --argjson e "$expected" '
        .schema == 1 and .domain == "menu" and .provider == $p and .availability == "available"
        and .capabilities.applications == $e.applications and .capabilities.commands == $e.commands
        and .capabilities.chooser == "supported"' <<<"$status_json" >/dev/null \
        || fail "$package menu status: $status_json"
done
printf 'ok - menu status reports per-launcher native mode support\n'
