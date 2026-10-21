#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs and bash -c scripts are single-quoted on purpose.
set -euo pipefail
# F04.3/F02.4: D-Bus name ownership probes in lib/hss_runtime.sh against busctl and dbus-send
# doubles that model the user bus (reply formats observed with systemd 262 and dbus 1.16).
# Evidence level: modeled-effect; no host bus is contacted.
# shellcheck source=tests/shell/harmonization_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/harmonization_testlib.sh"
ht_fixture_init

lib="$HT_REPO_ROOT/dotfiles/.config/hypr/scripts/lib/hss_runtime.sh"
name=org.freedesktop.Notifications
# probe FUNCTION [PATH]: run one runtime function; output in $HT_STDOUT, status in HT_STATUS.
probe() {
    ht_run env PATH="${2:-$PATH}" "$BASH" -c 'source "$1"; "$2" "$3"' _ "$lib" "$1" "$name"
}

ht_dbus_own "$name" :1.42 4242
probe hss_dbus_name_owner
assert_status 0 "owner lookup status"
assert_eq ':1.42' "$(cat "$HT_STDOUT")" "owner through busctl"
assert_argv busctl 1 --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetNameOwner s "$name"
probe hss_dbus_name_pid
assert_status 0 "pid lookup status"
assert_eq 4242 "$(cat "$HT_STDOUT")" "pid through busctl"
assert_argv busctl 2 --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus \
    GetConnectionUnixProcessID s "$name"
assert_calls dbus-send 0 "dbus-send calls while busctl exists"
ht_ok "busctl reports the owner and owner pid of a well-known user-bus name"

ht_dbus_release "$name"
probe hss_dbus_name_owner
assert_status 1 "owner lookup for an unowned name"
assert_eq 0 "$(wc -c < "$HT_STDOUT")" "owner output for an unowned name"
probe hss_dbus_name_pid
assert_status 1 "pid lookup for an unowned name"
assert_eq 0 "$(wc -c < "$HT_STDOUT")" "pid output for an unowned name"
ht_ok "an unowned name returns 1 with empty output"

ht_remove_double busctl
no_busctl=$(ht_restricted_path timeout dirname)
ht_dbus_own "$name" :1.7 777
probe hss_dbus_name_owner "$no_busctl"
assert_status 0 "owner lookup through dbus-send"
assert_eq ':1.7' "$(cat "$HT_STDOUT")" "owner through dbus-send"
assert_argv dbus-send 1 --session --print-reply=literal --dest=org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.GetNameOwner "string:$name"
probe hss_dbus_name_pid "$no_busctl"
assert_eq 777 "$(cat "$HT_STDOUT")" "pid through dbus-send"
ht_dbus_release "$name"
probe hss_dbus_name_owner "$no_busctl"
assert_status 1 "dbus-send lookup for an unowned name"
ht_ok "without busctl the probes fall back to dbus-send on the session bus"

ht_remove_double dbus-send
neither=$(ht_restricted_path timeout dirname)
probe hss_dbus_name_owner "$neither"
assert_status 2 "owner lookup without bus tools"
probe hss_dbus_name_pid "$neither"
assert_status 2 "pid lookup without bus tools"
ht_ok "without busctl and dbus-send the probes return 2"

ht__write_double busctl <<'BODY'
exec sleep 30
BODY
start=$SECONDS
probe hss_dbus_name_owner
assert_status 1 "owner lookup against a hanging bus"
((SECONDS - start <= 7)) || ht_fail "the bus probe was not bounded"
ht_run "$BASH" -c 'source "$1"; hss_process_name "$$"; hss_process_name not-a-pid || printf "rejected\n"' _ "$lib"
assert_eq $'bash\nrejected' "$(cat "$HT_STDOUT")" "process names"
ht_ok "a hanging bus probe is bounded and process names come from /proc only for numeric pids"
