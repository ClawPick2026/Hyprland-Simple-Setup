#!/usr/bin/env bash
# Toggle the night light between warm (4000K) and daylight (6000K). The direction comes from the
# temperature that the running hyprsunset reports over IPC. When hyprsunset is not running, or its
# state cannot be read, it is started warm.
set -uo pipefail

warm=4000
daylight=6000

notify() {
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send -e -u low "$@" >/dev/null 2>&1 || true
}

if ! command -v hyprsunset >/dev/null 2>&1; then
  notify -u normal "Night light unavailable" "hyprsunset is not installed"
  exit 6
fi

start_warm() {
  pkill -u "$(id -u)" -x hyprsunset >/dev/null 2>&1 || true
  if command -v setsid >/dev/null 2>&1; then
    setsid -f hyprsunset -t "$warm" </dev/null >/dev/null 2>&1
  else
    (hyprsunset -t "$warm" </dev/null >/dev/null 2>&1 &)
  fi || {
    notify -u normal "Night light unchanged" "hyprsunset could not be started"
    exit 1
  }
  notify "Warm Mode (${warm}K)"
}

pgrep -u "$(id -u)" -x hyprsunset >/dev/null 2>&1 || {
  start_warm
  exit 0
}

# hyprsunset answers a bare "temperature" query with the current value, e.g. "6000" or
# "Temperature: 6000"; take the first integer.
current=$(hyprctl hyprsunset temperature 2>/dev/null | grep -o -m 1 '[0-9]\+' | head -n 1)
if [[ -z $current ]]; then
  start_warm
  exit 0
fi

if ((current < daylight)); then
  target=$daylight label="Daylight Mode (${daylight}K)"
else
  target=$warm label="Warm Mode (${warm}K)"
fi

if hyprctl hyprsunset temperature "$target" >/dev/null 2>&1; then
  notify "$label"
else
  notify -u normal "Night light unchanged" "hyprsunset did not accept ${target}K"
  exit 1
fi
