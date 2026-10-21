#!/usr/bin/env bash
# Toggle Bluetooth power for keybindings and bar gestures. The direction comes only from a
# successful observation of the controller; a failed or empty query never powers it on.
# The notification reports the state that was read back afterwards.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
status=0
result=$("$script_dir/action_exec.sh" --json bluetooth.radio.toggle) || status=$?

outcome=$(jq -r '.outcome // "failed"' <<<"$result" 2>/dev/null || printf 'failed')
reason=$(jq -r '.reason // ""' <<<"$result" 2>/dev/null || true)
powered=$(jq -r '.observed.powered | if . == null then "unknown" else tostring end' <<<"$result" 2>/dev/null || printf 'unknown')

notify() {
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send -e "$@" >/dev/null 2>&1 || true
}

case "$outcome:$powered" in
  completed:true) notify -u low "Bluetooth Enabled" "Bluetooth is on" ;;
  completed:false) notify -u low "Bluetooth Disabled" "Bluetooth is off" ;;
  *) notify -u normal "Bluetooth unchanged" "${reason:-The Bluetooth state could not be changed}" ;;
esac
exit "$status"
