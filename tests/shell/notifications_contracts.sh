#!/usr/bin/env bash
set -euo pipefail

# D03.3: notification actions and status through action_exec.sh / status_read.sh against
# stateful doubles. busctl answers owner and readback calls from fixture state; the provider
# clients (swaync-client, makoctl, dunstctl, fnottctl) change that state. A `lazy` client that
# reports success without changing state must make the action fail. Owners are real fixture
# processes whose /proc/PID/comm is the provider name. Evidence: capabilities.d/d03-notifications.json.

unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
scripts="$repo_root/dotfiles/.config/hypr/scripts"
fixture=$(mktemp -d)
owner_pids=()
cleanup() {
    local pid
    for pid in "${owner_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf -- "$fixture"
}
trap cleanup EXIT
export HOME="$fixture/home" XDG_CONFIG_HOME="$fixture/home/.config" XDG_STATE_HOME="$fixture/state"
export NS="$fixture/ns" STUB_LOG="$fixture/stub.log"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$NS" "$fixture/bin" "$fixture/owners"
: > "$STUB_LOG"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Doubles

cat > "$fixture/bin/busctl" <<'STUB'
#!/usr/bin/env bash
# busctl double. State lives in $NS: owner_pid (empty = no owner), bus (up|down), dnd, visible,
# count, waiting, history, inhibited, modes.
printf '%s ' "$@" >> "$NS/busctl.log"
printf '\n' >> "$NS/busctl.log"
st() { cat "$NS/$1" 2>/dev/null || printf '%s' "${2:-}"; }
[[ $(st bus up) == up ]] || { printf 'Failed to connect to bus\n' >&2; exit 1; }
args=("$@")
autostart=yes
rest=()
for arg in "${args[@]}"; do
    case "$arg" in
        --user) ;;
        --auto-start=no) autostart=no ;;
        *) rest+=("$arg") ;;
    esac
done
[[ ${rest[0]} == call ]] || exit 1
destination=${rest[1]} path=${rest[2]} interface=${rest[3]} method=${rest[4]}
if [[ $destination == org.freedesktop.DBus ]]; then
    name=${rest[6]}
    if [[ $name == org.freedesktop.DBus ]]; then
        [[ $method == GetNameOwner ]] && { printf 's "org.freedesktop.DBus"\n'; exit 0; }
    fi
    pid=$(st owner_pid)
    [[ $name == org.freedesktop.Notifications && -n $pid ]] || { printf 'Call failed: name has no owner\n' >&2; exit 1; }
    case "$method" in
        GetNameOwner) printf 's ":1.42"\n' ;;
        GetConnectionUnixProcessID) printf 'u %s\n' "$pid" ;;
        *) exit 1 ;;
    esac
    exit 0
fi
# Provider calls must never be able to activate a daemon.
if [[ $autostart != no ]]; then
    printf 'ACTIVATION-RISK %s\n' "$*" >> "$NS/violations"
    exit 1
fi
[[ -n $(st owner_pid) ]] || { printf 'Call failed: The name is not activatable\n' >&2; exit 1; }
case "$destination $path $interface $method" in
    "org.erikreider.swaync.cc /org/erikreider/swaync/cc org.erikreider.swaync.cc GetSubscribeData")
        printf '(bbub) %s %s %s %s\n' "$(st dnd false)" "$(st visible false)" "$(st count 0)" "$(st inhibited false)" ;;
    "org.freedesktop.Notifications /fr/emersion/Mako org.freedesktop.DBus.Properties Get")
        modes=$(st modes default)
        set -- $modes
        printf 'v as %d' "$#"; printf ' "%s"' "$@"; printf '\n' ;;
    "org.freedesktop.Notifications /fr/emersion/Mako fr.emersion.Mako ListNotifications")
        printf 'aa{sv} %s {"summary" s "SECRET-SUMMARY"}\n' "$(st count 0)" ;;
    "org.freedesktop.Notifications /fr/emersion/Mako fr.emersion.Mako ListHistory")
        printf 'aa{sv} %s {"body" s "SECRET-BODY"}\n' "$(st history 0)" ;;
    "org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.DBus.Properties Get")
        case "${rest[7]}" in
            paused) printf 'v b %s\n' "$(st dnd false)" ;;
            displayedLength) printf 'v u %s\n' "$(st count 0)" ;;
            waitingLength) printf 'v u %s\n' "$(st waiting 0)" ;;
            historyLength) printf 'v u %s\n' "$(st history 0)" ;;
            *) exit 1 ;;
        esac ;;
    *) exit 1 ;;
esac
STUB

cat > "$fixture/bin/client-double" <<'STUB'
#!/usr/bin/env bash
# Provider client double. CLIENT_MODE: normal (changes state), lazy (succeeds without changing
# state), hang (never answers), fail (exits 1).
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$NS/client.log"
case "${CLIENT_MODE:-normal}" in
    lazy) [[ "$name $*" == "fnottctl list" ]] || exit 0 ;;  # read-only calls still tell the truth
    hang) exec sleep 30 ;;
    fail) exit 1 ;;
esac
st() { cat "$NS/$1" 2>/dev/null || printf '%s' "${2:-}"; }
put() { printf '%s' "$2" > "$NS/$1"; }
case "$name $*" in
    "swaync-client --skip-wait --toggle-panel") [[ $(st visible false) == true ]] && put visible false || put visible true ;;
    "swaync-client --skip-wait --open-panel") put visible true ;;
    "swaync-client --skip-wait --hide-all") ;;
    "swaync-client --skip-wait --dnd-on") put dnd true; printf 'true\n' ;;
    "swaync-client --skip-wait --dnd-off") put dnd false; printf 'false\n' ;;
    "makoctl dismiss --all") put history $(( $(st history 0) + $(st count 0) )); put count 0 ;;
    "makoctl mode -a do-not-disturb") put modes "$(st modes default) do-not-disturb" ;;
    "makoctl mode -r do-not-disturb") put modes "$(st modes default | sed 's/ do-not-disturb//g')" ;;
    "dunstctl close-all") put history $(( $(st history 0) + $(st count 0) )); put count 0 ;;
    "dunstctl set-paused true") put dnd true ;;
    "dunstctl set-paused false") put dnd false ;;
    "fnottctl dismiss all") put count 0 ;;
    "fnottctl list")
        [[ -n $(st owner_pid) ]] || exit 1
        for ((i = 1; i <= $(st count 0); i++)); do printf '%d: SECRET-SUMMARY\n' "$i"; done ;;
    *) printf 'unexpected client call\n' >&2; exit 64 ;;
esac
STUB
chmod +x "$fixture/bin/busctl" "$fixture/bin/client-double"
for client in swaync-client makoctl dunstctl fnottctl; do
    ln -s client-double "$fixture/bin/$client"
done
for provider in swaync mako dunst fnott; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/$provider"
    chmod +x "$fixture/bin/$provider"
    printf '#!/bin/bash\nsleep 120 &\nwait\n' > "$fixture/owners/$provider"
    chmod +x "$fixture/owners/$provider"
done
export PATH="$fixture/bin:$PATH"

write_roles() {
    export HSS_ROLES_FILE="$fixture/roles.json"
    jq --arg package "$1" '
        def pick($role; $name): .roles[$role].options[] | select(.package == $name);
        {schema_version: 2, roles: {notifications: pick("notifications"; $package)},
         selected: {notifications: [pick("notifications"; $package)]}}' "$repo_root/packages.json" > "$HSS_ROLES_FILE"
}

declare -A owner_of=()
start_owner() {
    local comm=$1
    if [[ -z ${owner_of[$comm]:-} ]]; then
        "$fixture/owners/$comm" &
        owner_pids+=("$!")
        owner_of[$comm]=$!
        for _ in $(seq 1 50); do
            [[ $(cat "/proc/$!/comm" 2>/dev/null) == "$comm" ]] && break
            sleep 0.05
        done
    fi
    printf '%s' "${owner_of[$comm]}" > "$NS/owner_pid"
}

reset_state() {
    rm -f -- "$NS"/*
    printf '%s' "$1" > "$NS/count"
    printf '%s' "$2" > "$NS/history"
}

# act ACTION [ARG]: sets envelope and status.
act() {
    : > "$NS/client.log"
    status=0
    envelope=$("$scripts/action_exec.sh" --json "$@" 2>/dev/null) || status=$?
    jq -e 'type == "object" and .schema == 1' <<<"$envelope" >/dev/null || fail "$*: no result envelope: $envelope"
}

expect() {
    if [[ $status != "$1" ]] || ! jq -e --arg o "$2" '.outcome == $o' <<<"$envelope" >/dev/null; then
        fail "$3 (status $status): $envelope"
    fi
}

read_status() {
    : > "$NS/client.log"
    status_json=$("$scripts/status_read.sh" notifications)
    jq -e '.schema == 1 and .domain == "notifications"
        and (.state | keys == ["center_visible", "count", "dnd", "history_count", "inhibited", "running"])' \
        <<<"$status_json" >/dev/null || fail "status shape: $status_json"
    if grep -Fq SECRET <<<"$status_json"; then fail "status exposed notification content"; fi
}

state_is() {
    jq -e --argjson expected "$1" '.state == $expected' <<<"$status_json" >/dev/null || fail "$2: $status_json"
}

no_violations() {
    [[ ! -s $NS/violations ]] || fail "a provider call could activate a daemon: $(<"$NS/violations")"
}

# ---------------------------------------------------------------------------
# Status

write_roles swaync
reset_state 3 0
printf true > "$NS/inhibited"
start_owner swaync
read_status
jq -e '.provider == "swaync" and .availability == "available" and .error == null
    and .capabilities == {"dnd":"supported","history":"supported","center":"supported","dismiss":"supported","actions":"supported"}' \
    <<<"$status_json" >/dev/null || fail "swaync status header: $status_json"
state_is '{"running":true,"dnd":false,"count":3,"history_count":null,"center_visible":false,"inhibited":true}' "swaync status"
[[ ! -s $NS/client.log ]] || fail "swaync status used a client that can activate the daemon"

write_roles mako
reset_state 2 7
printf 'default do-not-disturb' > "$NS/modes"
start_owner mako
read_status
state_is '{"running":true,"dnd":true,"count":2,"history_count":7,"center_visible":null,"inhibited":null}' "mako status"
jq -e '.capabilities.history == "unsupported" and .capabilities.center == "unsupported" and .capabilities.dnd == "supported"' \
    <<<"$status_json" >/dev/null || fail "mako capabilities: $status_json"

write_roles dunst
reset_state 1 4
printf 2 > "$NS/waiting"
printf true > "$NS/dnd"
start_owner dunst
read_status
state_is '{"running":true,"dnd":true,"count":3,"history_count":4,"center_visible":null,"inhibited":null}' "dunst status"

write_roles fnott
reset_state 2 0
start_owner fnott
read_status
state_is '{"running":true,"dnd":null,"count":2,"history_count":null,"center_visible":null,"inhibited":null}' "fnott status"
jq -e '.capabilities.dnd == "unsupported"' <<<"$status_json" >/dev/null || fail "fnott DND claimed: $status_json"
no_violations
printf 'ok - status reports running, dnd, count, history_count, center visibility and inhibition per provider, null when unknown\n'

for provider in swaync mako dunst fnott; do
    write_roles "$provider"
    reset_state 5 5
    read_status
    jq -e '.availability == "unavailable" and .state.running == false and .state.count == null and .state.dnd == null' \
        <<<"$status_json" >/dev/null || fail "$provider not running: $status_json"
    [[ ! -s $NS/client.log ]] || fail "$provider status touched a client while the daemon was not running"
done
write_roles swaync
start_owner dunst
read_status
jq -e '.availability == "unavailable" and .state.running == false and (.error | test("another notification service"))' \
    <<<"$status_json" >/dev/null || fail "foreign owner status: $status_json"
rm -f -- "$NS/owner_pid"
printf down > "$NS/bus"
read_status
jq -e '.availability == "unavailable" and .state.running == null' <<<"$status_json" >/dev/null || fail "no bus status: $status_json"
rm -f -- "$NS/bus"
rm "$fixture/bin/makoctl"
write_roles mako
read_status
jq -e '.availability == "missing-dependency"' <<<"$status_json" >/dev/null || fail "missing client status: $status_json"
ln -s client-double "$fixture/bin/makoctl"
HSS_ROLES_FILE="$fixture/none.json" read_status
jq -e '.availability == "unavailable" and .provider == null' <<<"$status_json" >/dev/null || fail "missing roles status: $status_json"
no_violations
printf 'ok - status never starts or calls a stopped provider and distinguishes stopped, foreign, no bus, missing and no roles\n'

# ---------------------------------------------------------------------------
# Do not disturb

for provider in swaync mako dunst; do
    write_roles "$provider"
    reset_state 0 0
    start_owner "$provider"
    act notifications.dnd.set on
    expect 0 completed "$provider dnd on"
    jq -e '.observed.dnd == true' <<<"$envelope" >/dev/null || fail "$provider dnd on not observed: $envelope"
    act notifications.dnd.set on
    expect 0 completed "$provider dnd on again"
    [[ ! -s $NS/client.log ]] || fail "$provider re-applied an already observed state"
    act notifications.dnd.toggle
    expect 0 completed "$provider dnd toggle"
    jq -e '.observed.dnd == false' <<<"$envelope" >/dev/null || fail "$provider toggle did not turn DND off: $envelope"
    act notifications.dnd.set off
    expect 0 completed "$provider dnd off"

    # A client that claims success without changing state must not be reported as done.
    CLIENT_MODE=lazy act notifications.dnd.set on
    expect 1 failed "$provider lazy client"
    CLIENT_MODE=fail act notifications.dnd.set on
    expect 1 failed "$provider failing client"
    SECONDS=0
    CLIENT_MODE=hang act notifications.dnd.set on
    expect 8 timeout "$provider hanging client"
    ((SECONDS < 15)) || fail "$provider client wait was not bounded"
    act notifications.dnd.set maybe
    expect 2 usage "$provider bad DND argument"
done
case "$(grep -c . "$NS/busctl.log")" in 0) fail "DND readback did not use the bus" ;; esac
no_violations

write_roles mako
reset_state 0 0
start_owner mako
act notifications.dnd.set on
argv=$(cat "$NS/client.log")
[[ $argv == *"makoctl mode -a do-not-disturb"* ]] || fail "mako DND did not use its native mode: $argv"
printf 'ok - DND set/toggle complete only when the native readback matches; lazy, failing and hanging clients are reported\n'

write_roles fnott
reset_state 0 0
start_owner fnott
for action in "notifications.dnd.set on" "notifications.dnd.toggle"; do
    # shellcheck disable=SC2086 # action and argument are separate words
    act $action
    expect 5 unsupported "fnott $action"
    jq -e '.reason | test("cannot report whether it is paused")' <<<"$envelope" >/dev/null || fail "fnott DND reason: $envelope"
    [[ ! -s $NS/client.log ]] || fail "fnott DND called fnottctl"
done
rm -f -- "$NS/owner_pid"
act notifications.dnd.set on
expect 5 unsupported "fnott DND while stopped"
printf 'ok - fnott DND is unsupported, explained and never touches fnott\n'

# ---------------------------------------------------------------------------
# Center, history and dismissal

write_roles swaync
reset_state 2 0
start_owner swaync
act notifications.center.toggle
expect 0 completed "swaync center open"
jq -e '.observed.center_visible == true' <<<"$envelope" >/dev/null || fail "center not observed open: $envelope"
act notifications.center.toggle
expect 0 completed "swaync center close"
CLIENT_MODE=lazy act notifications.center.toggle
expect 1 failed "swaync lazy center toggle"
act notifications.history.open
expect 0 completed "swaync history open"
act notifications.dismiss.all
expect 0 accepted "swaync dismiss all"
grep -Fq 'swaync-client --skip-wait --hide-all' "$NS/client.log" || fail "swaync dismissal did not hide popups natively"
[[ $(<"$NS/count") == 2 ]] || fail "swaync dismissal erased the notification center"

for provider in mako dunst fnott; do
    write_roles "$provider"
    reset_state 3 1
    start_owner "$provider"
    act notifications.center.toggle
    expect 5 unsupported "$provider center"
    act notifications.history.open
    expect 5 unsupported "$provider history"
    [[ ! -s $NS/client.log ]] || fail "$provider unsupported action called its client"
    act notifications.dismiss.all
    expect 0 completed "$provider dismiss all"
    [[ $(<"$NS/count") == 0 ]] || fail "$provider dismissal did not clear notifications"
    reset_state 3 1
    start_owner "$provider"
    CLIENT_MODE=lazy act notifications.dismiss.all
    if [[ $provider == dunst ]]; then
        expect 0 accepted "dunst lazy dismissal must not claim completion"
    else
        expect 1 failed "$provider lazy dismissal"
    fi
done
grep -q . "$NS/busctl.log" || fail "dismissal readback did not run"
no_violations
printf 'ok - center/history are native-only (SwayNC) and dismissal is verified by readback\n'

# Primary bar gesture: SwayNC toggles its center, the others dismiss all popups.
write_roles swaync
reset_state 2 0
start_owner swaync
act notifications.primary
expect 0 completed "swaync primary gesture"
jq -e '.action == "notifications.primary" and .observed.center_visible == true' <<<"$envelope" >/dev/null \
    || fail "swaync primary did not open the center: $envelope"
grep -Fq 'swaync-client --skip-wait --toggle-panel' "$NS/client.log" || fail "swaync primary did not toggle the panel"
[[ $(<"$NS/count") == 2 ]] || fail "swaync primary dismissed notifications"
for provider in mako dunst fnott; do
    write_roles "$provider"
    reset_state 3 1
    start_owner "$provider"
    act notifications.primary
    expect 0 completed "$provider primary gesture"
    [[ $(<"$NS/count") == 0 ]] || fail "$provider primary did not dismiss all notifications"
done
grep -Fq 'fnottctl dismiss all' "$NS/client.log" || fail "fnott primary did not use its native dismissal"
act notifications.primary extra
expect 2 usage "primary with an argument"
printf 'ok - notifications.primary toggles the SwayNC center and dismisses all for mako, dunst and fnott\n'

# ---------------------------------------------------------------------------
# Ownership, dependencies and argument errors

write_roles mako
reset_state 1 0
start_owner dunst
act notifications.dismiss.all
expect 10 conflict "foreign owner"
[[ ! -s $NS/client.log ]] || fail "client called while a foreign provider owns the bus name"
kill -0 "${owner_of[dunst]}" || fail "foreign owner was terminated"
rm -f -- "$NS/owner_pid"
act notifications.dismiss.all
expect 7 unavailable "stopped provider"
[[ ! -s $NS/client.log ]] || fail "client called while the provider is stopped"
printf down > "$NS/bus"
act notifications.dnd.set on
expect 7 unavailable "no session bus"
rm -f -- "$NS/bus"
rm "$fixture/bin/dunstctl"
write_roles dunst
act notifications.dismiss.all
expect 6 missing-dependency "missing dunstctl"
ln -s client-double "$fixture/bin/dunstctl"
HSS_ROLES_FILE="$fixture/none.json" act notifications.dnd.toggle
expect 7 unavailable "missing role data"
act notifications.center.toggle extra
expect 2 usage "extra argument"
printf 'ok - foreign owners conflict, stopped providers are unavailable and nothing is started or terminated\n'

# Without --json the user gets an explanation (no notification content) and stdout stays empty.
write_roles fnott
: > "$STUB_LOG"
out=$("$scripts/action_exec.sh" notifications.dnd.toggle 2>/dev/null) && fail "unsupported action succeeded"
[[ -z $out ]] || fail "action wrote to stdout without --json"
grep -Fq 'notifications.dnd.toggle: unsupported' "$STUB_LOG" || fail "unsupported DND was not explained"
printf 'ok - unsupported outcomes are explained to the user without stdout output\n'
