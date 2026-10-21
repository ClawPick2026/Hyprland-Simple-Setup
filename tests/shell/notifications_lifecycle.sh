#!/usr/bin/env bash
set -euo pipefail

# D03.5: notification singleton ownership in role_exec.sh (contract section 6). A busctl
# double answers GetNameOwner/GetConnectionUnixProcessID from fixture state; owner processes
# are real fixture processes whose /proc/PID/comm is the provider name. The selected provider
# starts only when nobody owns org.freedesktop.Notifications (or the bus cannot be queried),
# is a no-op when it already owns the name, and a foreign owner is refused and left running.

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
export STATE="$fixture/bus"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$STATE" "$fixture/bin" "$fixture/owners"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

cat > "$fixture/bin/busctl" <<'STUB'
#!/usr/bin/env bash
# busctl double: --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus METHOD s NAME
printf '%s\0' "$@" >> "$STATE/busctl.log"
printf '\n' >> "$STATE/busctl.log"
mode=$(cat "$STATE/mode" 2>/dev/null || printf none)
method=${6:-}
case "$mode" in
    nobus) printf 'Failed to connect to bus: No such file or directory\n' >&2; exit 1 ;;
    slow) sleep 10; exit 0 ;;
esac
[[ $mode == owned || $mode == nopid ]] || { printf 'Call failed: The name is not activatable\n' >&2; exit 1; }
case "$method" in
    GetNameOwner) printf 's ":1.42"\n' ;;
    GetConnectionUnixProcessID)
        [[ $mode == owned ]] || { printf 'Call failed: Could not get PID\n' >&2; exit 1; }
        printf 'u %s\n' "$(cat "$STATE/pid")"
        ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$fixture/bin/busctl"
for provider in swaync mako dunst fnott; do
    # Provider double: records each start (the real daemon would block; this one returns).
    # shellcheck disable=SC2016 # the double's own shell expands these
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${0##*/}" >> "$STATE/starts"\n' > "$fixture/bin/$provider"
    chmod +x "$fixture/bin/$provider"
    # Owner process with the provider's comm name (a direct #!/bin/bash script keeps its own
    # name as comm; an env shebang would show "bash").
    printf '#!/bin/bash\nsleep 60 &\nwait\n' > "$fixture/owners/$provider"
    chmod +x "$fixture/owners/$provider"
done
export PATH="$fixture/bin:$PATH"

write_roles() {
    export HSS_ROLES_FILE="$fixture/roles.json"
    jq --arg package "$1" '
        def pick($role; $name): .roles[$role].options[] | select(.package == $name);
        {schema_version: 2, roles: {notifications: pick("notifications"; $package), browser: pick("browser"; "firefox")},
         selected: {notifications: [pick("notifications"; $package)]}}' "$repo_root/packages.json" > "$HSS_ROLES_FILE"
}

start_owner() {
    "$fixture/owners/$1" &
    owner_pids+=("$!")
    printf '%s' "$!" > "$STATE/pid"
    for _ in $(seq 1 50); do
        [[ $(cat "/proc/$!/comm" 2>/dev/null) == "$1" ]] && return 0
        sleep 0.05
    done
    fail "owner fixture $1 did not start"
}

run_role() {
    rm -f -- "$STATE/starts" "$STATE/busctl.log"
    status=0
    "$scripts/role_exec.sh" notifications >/dev/null 2>"$fixture/err" || status=$?
}

starts() {
    cat "$STATE/starts" 2>/dev/null || true
}

for provider in swaync mako dunst fnott; do
    write_roles "$provider"

    printf none > "$STATE/mode"
    run_role
    [[ $status == 0 && $(starts) == "$provider" ]] || fail "$provider: did not start without an owner (status $status)"
    grep -Fq 'GetNameOwner' "$STATE/busctl.log" || fail "$provider: owner was not queried"

    start_owner "$provider"
    printf owned > "$STATE/mode"
    run_role
    [[ $status == 0 && -z $(starts) ]] || fail "$provider: started a second instance while owning the name"

    foreign=dunst
    [[ $provider == dunst ]] && foreign=mako
    start_owner "$foreign"
    foreign_pid=$(<"$STATE/pid")
    run_role
    [[ $status == 10 && -z $(starts) ]] || fail "$provider: foreign owner $foreign not refused (status $status)"
    grep -Fq "owned by $foreign (pid $foreign_pid)" "$fixture/err" || fail "$provider: conflict message missing"
    kill -0 "$foreign_pid" 2>/dev/null || fail "$provider: foreign owner was terminated"
    grep -Fq "conflict: org.freedesktop.Notifications is owned by $foreign" \
        "$XDG_STATE_HOME/hyprland-simple-setup/apps/notifications.log" || fail "$provider: conflict was not logged"
    printf 'ok - %s starts only without an owner, is a no-op when it owns the bus name and refuses a foreign owner\n' "$provider"
done

write_roles swaync
printf nopid > "$STATE/mode"
run_role
[[ $status == 10 && -z $(starts) ]] || fail "an owner that cannot be identified was not refused"
grep -Fq 'owned by an unidentified process' "$fixture/err" || fail "unidentified owner message missing"

printf nobus > "$STATE/mode"
run_role
[[ $status == 0 && $(starts) == swaync ]] || fail "unreachable bus did not keep the legacy start"

printf slow > "$STATE/mode"
SECONDS=0
run_role
[[ $status == 0 && $(starts) == swaync ]] || fail "a timed-out owner query did not keep the legacy start"
((SECONDS < 9)) || fail "owner query was not bounded"

printf none > "$STATE/mode"
saved_path=$PATH
mv "$fixture/bin/busctl" "$fixture/busctl.off"
PATH="$fixture/bin:/usr/bin:/bin"
if ! command -v busctl >/dev/null 2>&1 && ! command -v dbus-send >/dev/null 2>&1; then
    run_role
    [[ $status == 0 && $(starts) == swaync ]] || fail "missing D-Bus tools did not keep the legacy start"
fi
PATH=$saved_path
mv "$fixture/busctl.off" "$fixture/bin/busctl"
printf 'ok - unreachable bus, query timeout and missing tools keep the legacy start; unidentified owners are refused\n'

# D-Bus activation runs the service file's Exec line; with no owner yet it must still start.
service="$repo_root/dotfiles/.local/share/dbus-1/services/org.freedesktop.Notifications.service"
grep -Fxq 'Name=org.freedesktop.Notifications' "$service" || fail "service name changed"
exec_line=$(sed -n 's/^Exec=//p' "$service")
[[ $exec_line == "/bin/sh -c 'exec \"\$HOME/.config/hypr/scripts/role_exec.sh\" notifications'" ]] || fail "service Exec changed: $exec_line"
mkdir -p "$HOME/.config/hypr"
ln -s "$scripts" "$HOME/.config/hypr/scripts"
rm -f -- "$STATE/starts"
/bin/sh -c 'exec "$HOME/.config/hypr/scripts/role_exec.sh" notifications' >/dev/null 2>&1
[[ $(starts) == swaync ]] || fail "D-Bus activation path no longer starts the selected provider"
printf 'ok - D-Bus activation through the service file still starts the selected provider\n'

# Other roles never query the notification bus name.
rm -f -- "$STATE/busctl.log"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/firefox"
chmod +x "$fixture/bin/firefox"
"$scripts/role_exec.sh" browser
[[ ! -e $STATE/busctl.log ]] || fail "a non-notification role queried the bus"
printf 'ok - other roles are unaffected by the notification ownership check\n'
