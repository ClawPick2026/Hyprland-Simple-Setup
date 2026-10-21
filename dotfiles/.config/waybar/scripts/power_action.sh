#!/usr/bin/env bash
# Compatibility entry point for power actions used by Waybar menus, keybindings and older
# configurations. All semantics live in the session provider (plan D07):
#   lock      immediate
#   suspend   direct
#   hibernate only when logind reports it can hibernate
#   logout, reboot, shutdown  confirmed through the shared chooser; logout ends only the
#             current session and never falls back to ending every session of the user
set -euo pipefail

action_exec="$HOME/.config/hypr/scripts/action_exec.sh"
action=${1:-}
case "$action" in
  lock|logout|reboot|shutdown|suspend|hibernate) ;;
  *)
    if command -v notify-send >/dev/null 2>&1; then
      notify-send "Power Menu" "Unknown action: $action" --urgency=critical || true
    fi
    printf 'Usage: power_action.sh lock|logout|reboot|shutdown|suspend|hibernate\n' >&2
    exit 2
    ;;
esac
shift
exec "$action_exec" "session.$action" "$@"
