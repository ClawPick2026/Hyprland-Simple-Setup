#!/usr/bin/env bash
set -euo pipefail

roles_file=${HSS_ROLES_FILE:-$HOME/.config/hypr/roles.json}
mode=normal
case "${1:-}" in
  --dmenu) mode=dmenu; shift ;;
  --toggle) mode=toggle; shift ;;
esac

# shellcheck source=dotfiles/.config/hypr/scripts/app_log.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/app_log.sh"
hss_start_app_log launcher
[[ -r "$roles_file" ]] || { printf 'Missing role data: %s\n' "$roles_file" >&2; exit 1; }
if [[ $(jq -er '.roles.launcher.package' "$roles_file") == bemenu ]]; then
  export BEMENU_BACKEND=wayland
  # Bemenu has no configuration file; its native appearance options come from the theme
  # renderer (unit "bemenu"). A BEMENU_OPTS value set by the user always wins.
  bemenu_opts_file="${XDG_CONFIG_HOME:-$HOME/.config}/hss-theme/generated/bemenu/bemenu.opts"
  if [[ -z ${BEMENU_OPTS+x} && -f $bemenu_opts_file && -r $bemenu_opts_file ]] \
    && IFS= read -r bemenu_opts < "$bemenu_opts_file" && [[ -n $bemenu_opts ]]; then
    export BEMENU_OPTS=$bemenu_opts
  fi
fi
process=$(jq -er '.roles.launcher.process' "$roles_file")

if [[ "$mode" == toggle ]]; then
  if pkill -u "$UID" -x -- "$process"; then
    exit 0
  else
    status=$?
  fi
  # No matching process means open the menu; other errors must remain visible.
  ((status == 1)) || exit "$status"
fi

if [[ "$mode" == dmenu ]]; then
  executable=$(jq -er '.roles.launcher.dmenu_executable' "$roles_file")
  mapfile -t args < <(jq -r '.roles.launcher.dmenu_args[]?' "$roles_file")
else
  executable=$(jq -er '.roles.launcher.executable' "$roles_file")
  mapfile -t args < <(jq -r '.roles.launcher.args[]?' "$roles_file")
fi

exec "$executable" "${args[@]}" "$@"
