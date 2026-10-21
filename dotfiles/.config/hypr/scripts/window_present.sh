#!/usr/bin/env bash
set -euo pipefail

# Focus an existing window whose class matches CLASS_REGEX, or start COMMAND and wait
# for its window; then float, resize and center it on the focused output.

if (($# < 6)); then
    printf 'Usage: %s CLASS_REGEX WIDTH HEIGHT DISPLAY_NAME -- COMMAND [ARG ...]\n' "${0##*/}" >&2
    exit 2
fi

readonly CLASS_REGEX=$1
readonly WIDTH=$2
readonly HEIGHT=$3
readonly DISPLAY_NAME=$4
shift 4

if [[ ${1:-} != "--" ]]; then
    printf 'Expected -- before the command.\n' >&2
    exit 2
fi
shift

readonly COMMAND=$1
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly FLOAT_HELPER="$script_dir/window_place.sh"

notify_failure() {
    local message=$1
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical "${DISPLAY_NAME}" "$message"
    fi
    printf '%s: %s\n' "$DISPLAY_NAME" "$message" >&2
}

find_window_address() {
    hyprctl clients -j 2>/dev/null | jq -r --arg regex "$CLASS_REGEX" '
        first(
            .[]
            | select(
                ((.class // "") | test($regex; "i"))
                or ((.initialClass // "") | test($regex; "i"))
            )
            | .address
        ) // empty
    ' 2>/dev/null
}

focus_and_place() {
    local address=$1
    if [[ -x "$FLOAT_HELPER" ]]; then
        "$FLOAT_HELPER" "address:${address}" "$WIDTH" "$HEIGHT"
    else
        hyprctl dispatch "hl.dsp.focus({ window = \"address:${address}\" })" >/dev/null
    fi
}

if ! command -v "$COMMAND" >/dev/null 2>&1; then
    notify_failure "The '${COMMAND}' executable was not found."
    exit 127
fi

address="$(find_window_address)"
if [[ -n "$address" ]]; then
    focus_and_place "$address"
    exit 0
fi

"$@" >/dev/null 2>&1 &

for _ in {1..80}; do
    address="$(find_window_address)"
    if [[ -n "$address" ]]; then
        focus_and_place "$address"
        exit 0
    fi
    sleep 0.1
done

notify_failure "The application started, but its window could not be detected."
exit 1
