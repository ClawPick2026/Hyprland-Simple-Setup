#!/usr/bin/env bash
# Presentation adapter (plan D01, policy P01): report absent bar hardware explicitly.
#
# Waybar 0.15 hides its native backlight, battery and keyboard-state modules when no
# device can be used. Bars must keep showing that hardware as unavailable instead, so
# a companion module runs this adapter: `--absent KIND` succeeds only when the native
# module cannot work (Waybar exec-if), and `KIND` prints the explanation.
#
# Usage: hardware_state.sh [--absent] [--format waybar|plain|nwg] backlight|battery|keyboard
# States: present, unavailable (no device), denied (devices exist but none is readable).
set -euo pipefail

sysfs=${HSS_SYSFS_ROOT:-/sys}
devfs=${HSS_DEV_ROOT:-/dev}
absent=false
format=waybar

usage() {
    printf 'Usage: hardware_state.sh [--absent] [--format waybar|plain|nwg] backlight|battery|keyboard\n' >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --absent) absent=true ;;
        --format) [[ $# -ge 2 ]] || { usage; exit 2; }; format=$2; shift ;;
        --format=*) format=${1#--format=} ;;
        -h|--help) usage; exit 0 ;;
        -*) usage; exit 2 ;;
        *) break ;;
    esac
    shift
done
kind=${1:-}
[[ $# -eq 1 ]] || { usage; exit 2; }
case "$format" in waybar|plain|nwg) ;; *) usage; exit 2 ;; esac

backlight_state() {
    local path
    for path in "$sysfs"/class/backlight/*; do
        [[ -r $path/brightness && -r $path/max_brightness ]] && { printf 'present\n'; return; }
    done
    printf 'unavailable\n'
}

# Waybar counts power supplies of type Battery that are not peripheral (scope Device).
battery_state() {
    local path type scope
    for path in "$sysfs"/class/power_supply/*; do
        [[ -r $path/type ]] || continue
        type=$(<"$path/type")
        [[ $type == Battery ]] || continue
        scope=""
        [[ ! -r $path/scope ]] || scope=$(<"$path/scope")
        [[ $scope == Device ]] && continue
        printf 'present\n'
        return
    done
    printf 'unavailable\n'
}

# Lock-key LEDs are read from evdev devices that advertise LED capabilities.
keyboard_state() {
    local path name led found=false
    for path in "$sysfs"/class/input/event*; do
        [[ -r $path/device/capabilities/led ]] || continue
        led=$(<"$path/device/capabilities/led")
        [[ -n ${led//[0 ]/} ]] || continue
        found=true
        name=${path##*/}
        if [[ -r $devfs/input/$name ]]; then
            printf 'present\n'
            return
        fi
    done
    if $found; then printf 'denied\n'; else printf 'unavailable\n'; fi
}

case "$kind" in
    backlight) state=$(backlight_state) ;;
    battery) state=$(battery_state) ;;
    keyboard) state=$(keyboard_state) ;;
    *) usage; exit 2 ;;
esac

if $absent; then
    [[ $state != present ]]
    exit
fi

case "$kind:$state" in
    backlight:present) icon=$''; text=""; tooltip="Backlight device present" ;;
    backlight:*) icon=$''; text="n/a"; tooltip="No backlight device was found; brightness control is unavailable on this output." ;;
    battery:present) icon=$''; text=""; tooltip="Battery present" ;;
    battery:*) icon=$''; text="n/a"; tooltip="No system battery was found; battery status is unavailable." ;;
    keyboard:present) icon=$''; text=""; tooltip="Lock-key state is readable" ;;
    keyboard:denied) icon=$''; text="locks?"; tooltip="Num Lock and Caps Lock state cannot be read: input devices are not readable by this user (Waybar needs the input group)." ;;
    keyboard:*) icon=$''; text="n/a"; tooltip="No keyboard with lock-key LEDs was found; lock-key state is unavailable." ;;
esac

case "$format" in
    waybar)
        jq -cn --arg text "$icon${text:+ $text}" --arg state "$state" --arg kind "$kind" --arg tooltip "$tooltip" \
            '{text: $text, alt: $state, class: [$state, $kind], tooltip: $tooltip}'
        ;;
    plain) printf '%s\n' "$icon${text:+ $text}" ;;
    # nwg-panel executor: icon line (empty), label, tooltip (contains no markup characters).
    nwg) printf '\n%s\n%s\n' "$icon${text:+ $text}" "$tooltip" ;;
esac
