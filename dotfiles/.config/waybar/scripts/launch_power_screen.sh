#!/usr/bin/env bash
# Launch wlogout with the wallpaper currently active in hyprpaper. The command line comes
# from the session provider (plan D07), which hides the hibernate button unless logind
# reports that the system can hibernate. Wlogout runs in the foreground of this script.

set -u

readonly CACHE_DIR="$HOME/.cache/wlogout"
readonly BACKGROUND_LINK="$CACHE_DIR/current-wallpaper"

notify() {
    command -v notify-send >/dev/null 2>&1 && notify-send "$@" || true
}

if ! command -v wlogout >/dev/null 2>&1; then
    notify --urgency=critical "Power screen" "wlogout is not installed."
    exit 1
fi

mkdir -p "$CACHE_DIR" || exit 1

if [[ ! -f "$BACKGROUND_LINK" ]]; then
    notify --urgency=normal "Power screen" "No current wallpaper is cached; using the fallback background."
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
hypr_scripts="$script_dir/../../hypr/scripts"
[[ -r $hypr_scripts/providers/session.sh ]] || hypr_scripts="$HOME/.config/hypr/scripts"
command=(wlogout --protocol layer-shell --css "$HOME/.config/wlogout/style.css")
if [[ -r $hypr_scripts/lib/hss_runtime.sh && -r $hypr_scripts/providers/session.sh ]]; then
    HSS_SCRIPTS_DIR=$(cd -- "$hypr_scripts" && pwd)
    export HSS_SCRIPTS_DIR
    # shellcheck source=dotfiles/.config/hypr/scripts/lib/hss_runtime.sh
    source "$HSS_SCRIPTS_DIR/lib/hss_runtime.sh"
    # shellcheck source=dotfiles/.config/hypr/scripts/providers/session.sh
    source "$HSS_SCRIPTS_DIR/providers/session.sh"
    hss_session_wlogout_command command
fi

exec "${command[@]}"
