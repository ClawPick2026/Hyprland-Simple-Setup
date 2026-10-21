#!/usr/bin/env bash
# hyprsunset.sh reads the running temperature over IPC and sets the opposite one; with no running
# daemon or an unreadable state it starts warm. PATH doubles stand in for hyprsunset and hyprctl.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/dotfiles/.config/hypr/scripts/hyprsunset.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
bin="$fixture/bin"
mkdir -p "$bin"
log="$fixture/calls"

stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$bin/$1"
  chmod +x "$bin/$1"
}
stub hyprsunset 'printf "hyprsunset %s\n" "$*" >> "$HSS_TEST_LOG"'
stub setsid 'shift; "$@"'
stub pkill 'printf "pkill %s\n" "$*" >> "$HSS_TEST_LOG"'
stub notify-send 'printf "notify %s\n" "${*: -1}" >> "$HSS_TEST_LOG"'
stub pgrep '[[ ${HSS_TEST_RUNNING:-0} == 1 ]]'
stub hyprctl 'printf "hyprctl %s\n" "$*" >> "$HSS_TEST_LOG"
if (($# == 2)); then printf "%s" "${HSS_TEST_QUERY:-}"; fi'

run() {
  : > "$log"
  env PATH="$bin:/usr/bin:/bin" HSS_TEST_LOG="$log" "$@" bash "$script"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cat "$log" >&2
  exit 1
}

run HSS_TEST_RUNNING=0 || fail "start when stopped"
grep -Fxq 'hyprsunset -t 4000' "$log" || fail "stopped daemon starts warm"
grep -Fxq 'notify Warm Mode (4000K)' "$log" || fail "warm start notifies"

run HSS_TEST_RUNNING=1 HSS_TEST_QUERY=4000 || fail "toggle from warm"
grep -Fxq 'hyprctl hyprsunset temperature 6000' "$log" || fail "warm switches to daylight"
! grep -q '^hyprsunset ' "$log" || fail "a running daemon is not restarted"

run HSS_TEST_RUNNING=1 HSS_TEST_QUERY='Temperature: 6000' || fail "toggle from daylight"
grep -Fxq 'hyprctl hyprsunset temperature 4000' "$log" || fail "daylight switches to warm"

run HSS_TEST_RUNNING=1 HSS_TEST_QUERY='invalid command' || fail "unreadable state"
grep -Fxq 'hyprsunset -t 4000' "$log" || fail "unreadable state restarts warm"
grep -q '^pkill ' "$log" || fail "unreadable state stops the old daemon first"

rm "$bin/hyprsunset"
status=0
env PATH="$bin" HSS_TEST_LOG="$log" /bin/bash "$script" || status=$?
((status == 6)) || fail "missing hyprsunset exits 6 (got $status)"

printf 'ok - night light toggles from the observed temperature and starts warm otherwise\n'
