#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

cat > "$fixture/pass.sh" <<'PASS'
#!/usr/bin/env bash
set -euo pipefail
[[ -d $HOME && -d $XDG_CONFIG_HOME && -d $XDG_STATE_HOME && -d $XDG_RUNTIME_DIR ]]
[[ $PATH == "$HYPRLAND_SETUP_DIR/tests/stubs:"* ]]
printf 'ok - nested passing fixture saw isolated paths and stubs\n'
PASS
cat > "$fixture/fail.sh" <<'FAIL'
#!/usr/bin/env bash
printf 'intentional runner regression failure\n' >&2
exit 23
FAIL

set +e
runner_output=$("$repo_root/tests/run.sh" "$fixture/pass.sh" "$fixture/fail.sh" 2>&1)
runner_status=$?
set -e
[[ $runner_status -ne 0 ]]
grep -Fq 'ok - nested passing fixture saw isolated paths and stubs' <<<"$runner_output"
grep -Fq 'not ok - ' <<<"$runner_output"
grep -Fq '(exit 23)' <<<"$runner_output"
grep -Fq '1 test programs passed, 1 failed' <<<"$runner_output"
printf 'ok - test runner preserves isolation, continues after failure, and exits nonzero\n'

printf '{}\n' > "$fixture/invalid-packages.json"
set +e
checker_output=$(HSS_PACKAGES_JSON="$fixture/invalid-packages.json" \
  "$repo_root/tests/check_packages_json.sh" 2>&1)
checker_status=$?
set -e
[[ $checker_status -ne 0 ]]
grep -Fq 'not ok - package registry failed offline schema checks' <<<"$checker_output"

jq '.roles.launcher.options[0].namespace = "bad/name"' \
  "$repo_root/packages.json" > "$fixture/bad-token-packages.json"
set +e
checker_output=$(HSS_PACKAGES_JSON="$fixture/bad-token-packages.json" \
  "$repo_root/tests/check_packages_json.sh" 2>&1)
checker_status=$?
set -e
[[ $checker_status -ne 0 ]]
grep -Fq 'not ok - package registry failed offline schema checks' <<<"$checker_output"
printf 'ok - package registry checker rejects malformed roots and restricted tokens with slashes\n'

# F04.2: the runner removes inherited host session variables and keeps everything else.
cat > "$fixture/session.sh" <<'SESSION'
#!/usr/bin/env bash
set -euo pipefail
for name in DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY XDG_SESSION_ID; do
  if [[ -n ${!name+x} ]]; then
    printf 'leaked host session variable %s\n' "$name" >&2
    exit 1
  fi
done
[[ ${HSS_HARNESS_PROBE:-} == kept ]]
printf 'ok - nested fixture saw no host session variables\n'
SESSION
set +e
session_output=$(DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/hostile-bus \
  WAYLAND_DISPLAY=hostile-wayland-0 HYPRLAND_INSTANCE_SIGNATURE=hostile-signature \
  DISPLAY=:99 XDG_SESSION_ID=hostile-session HSS_HARNESS_PROBE=kept \
  "$repo_root/tests/run.sh" "$fixture/session.sh" 2>&1)
session_status=$?
set -e
[[ $session_status -eq 0 ]] || { printf '%s\n' "$session_output" >&2; exit 1; }
grep -Fq 'ok - nested fixture saw no host session variables' <<<"$session_output"
printf 'ok - test runner unsets inherited D-Bus, Wayland, Hyprland, X11 and session variables\n'

# F04.2: the harmonization fixture library fails closed and cleans up after itself.
cat > "$fixture/testlib.sh" <<'TESTLIB'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$HYPRLAND_SETUP_DIR/tests/shell/harmonization_testlib.sh"
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/hostile-bus WAYLAND_DISPLAY=hostile DISPLAY=:99
ht_fixture_init
printf '%s\n' "$HT_ROOT" > "$FIXTURE_ROOT_RECORD"
[[ -z ${DBUS_SESSION_BUS_ADDRESS+x} && -z ${WAYLAND_DISPLAY+x} && -z ${DISPLAY+x} ]]
[[ $HOME == "$HT_ROOT"/* && $XDG_CONFIG_HOME == "$HT_ROOT"/* && $XDG_DATA_HOME == "$HT_ROOT"/* ]]
[[ $XDG_STATE_HOME == "$HT_ROOT"/* && $XDG_RUNTIME_DIR == "$HT_ROOT"/* && $TMPDIR == "$HT_ROOT"/* ]]
for tool in notify-send pgrep pkill gsettings busctl dbus-send; do
  [[ $(command -v "$tool") == "$HT_BIN/$tool" ]]
done
notify-send -- 'two words' '' $'line\nbreak'
assert_calls notify-send 1
assert_argv notify-send 1 -- 'two words' '' $'line\nbreak'
ht_expect_failure assert_argv notify-send 1 -- 'two words'
pkill -u "$(id -u)" -x -USR1 -- kitty && exit 1
[[ -z $(ht_signals) ]]
ht_proc_start kitty
pkill -u "$(id -u)" -x -USR1 -- kitty
[[ $(ht_signals) == 'kitty USR1' ]]
ht_double fake-tool
ht_double_exit fake-tool 7
ht_run fake-tool arg
assert_status 7
ht_write_roles "$HT_ROOT/roles.json" terminal=foot,kitty agent= dock=
assert_json "$HT_ROOT/roles.json" '.schema_version == 2 and .roles.terminal.package == "foot"
  and ([.selected.terminal[].package] == ["kitty", "foot"]) and .roles.agent == null
  and .selected.agent == [] and .roles.dock == null and .roles.browser.package == "zen-browser-bin"'
if ht_write_roles "$HT_ROOT/bad.json" terminal=not-a-terminal 2>/dev/null; then exit 1; fi
sleep 30 &
ht_track_pid $!
printf '%s\n' "$!" > "$FIXTURE_PID_RECORD"
printf 'ok - fixture library isolation, doubles and roles writer\n'
TESTLIB
set +e
testlib_output=$(FIXTURE_ROOT_RECORD="$fixture/root-record" FIXTURE_PID_RECORD="$fixture/pid-record" \
  "$repo_root/tests/run.sh" "$fixture/testlib.sh" 2>&1)
testlib_status=$?
set -e
[[ $testlib_status -eq 0 ]] || { printf '%s\n' "$testlib_output" >&2; exit 1; }
grep -Fq 'ok - fixture library isolation, doubles and roles writer' <<<"$testlib_output"
[[ ! -e $(cat "$fixture/root-record") ]]
if kill -0 "$(cat "$fixture/pid-record")" 2>/dev/null; then
  printf 'not ok - fixture background process survived cleanup\n' >&2
  exit 1
fi
printf 'ok - harmonization fixtures scrub the session, record argv, and remove their root and processes\n'
