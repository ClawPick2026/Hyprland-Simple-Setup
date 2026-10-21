#!/usr/bin/env bash
set -euo pipefail

roles_file=${HSS_ROLES_FILE:-$HOME/.config/hypr/roles.json}
role=${1:-}
[[ $role =~ ^[a-z][a-z0-9_]*$ ]] || {
  printf 'Usage: role_exec.sh ROLE [--] [args...]\n' >&2
  exit 2
}
shift
[[ ${1:-} != -- ]] || shift
if [[ $role == launcher ]]; then
  exec "$HOME/.config/hypr/scripts/menu_exec.sh" "$@"
fi
if [[ $role == bar || $role == dock ]]; then
  # shellcheck source=dotfiles/.config/hypr/scripts/app_log.sh
  source "$(dirname -- "${BASH_SOURCE[0]}")/app_log.sh"
  hss_start_app_log "$role"
fi
[[ -r $roles_file ]] || { printf 'Missing role data: %s\n' "$roles_file" >&2; exit 1; }

option=$(jq -ce --arg role "$role" '.roles[$role]' "$roles_file") || {
  if [[ $role == gui_editor ]]; then
    role=tui_editor
    option=$(jq -ce '.roles.tui_editor' "$roles_file")
  elif [[ $role == dock ]]; then
    exit 0
  else
    printf 'Role %s is unavailable\n' "$role" >&2
    exit 1
  fi
}

if [[ $(jq -r '.package' <<<"$option") == nwg-panel && ( $role == bar || $role == dock ) ]]; then
  exec "$HOME/.config/hypr/scripts/nwg_panel.sh" "$role" "$@"
fi
if [[ $role == dock && $(jq -r '.package' <<<"$option") == nwg-dock-hyprland ]]; then
  exec "$HOME/.config/hypr/scripts/nwg_dock.sh" "$@"
fi

executable=$(jq -er '.executable' <<<"$option")
mapfile -t args < <(jq -r '.args[]?' <<<"$option")

# Notification singleton ownership (Documents/runtime-managed-configuration.md, section 6):
# one org.freedesktop.Notifications owner per user bus. When the selected provider already
# owns the name nothing starts; a foreign owner is refused as `conflict` (exit 10) and never
# terminated. When the bus cannot be queried, or nobody owns the name (which is also the case
# while D-Bus activates this script through the service file), the provider starts as before.
if [[ $role == notifications ]]; then
  # shellcheck source=dotfiles/.config/hypr/scripts/lib/hss_runtime.sh
  if source "$(dirname -- "${BASH_SOURCE[0]}")/lib/hss_runtime.sh" 2>/dev/null \
    && owner=$(hss_dbus_name_owner org.freedesktop.Notifications 2>/dev/null) && [[ -n $owner ]]; then
    owner_pid=$(hss_dbus_name_pid org.freedesktop.Notifications 2>/dev/null) || owner_pid=""
    owner_name=$(hss_process_name "$owner_pid" 2>/dev/null) || owner_name=""
    expected_name=${executable##*/}
    if [[ -n $owner_name && $owner_name == "${expected_name:0:15}" ]]; then
      exit 0
    fi
    message="org.freedesktop.Notifications is owned by ${owner_name:-an unidentified process}${owner_pid:+ (pid $owner_pid)}; not starting $expected_name. Stop that notification service to use $expected_name."
    printf 'role_exec.sh: conflict: %s\n' "$message" >&2
    log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/hyprland-simple-setup/apps"
    (umask 077; mkdir -p -- "$log_dir" && printf '%(%Y-%m-%dT%H:%M:%S%z)T conflict: %s\n' -1 "$message" >> "$log_dir/notifications.log") 2>/dev/null || true
    exit 10
  fi
fi
if [[ $(jq -r '.terminal // false' <<<"$option") == true ]]; then
  exec "$HOME/.config/hypr/scripts/term_exec.sh" \
    --app-id "hss-$role" --title "${role//_/ }" -- \
    "$executable" "${args[@]}" "$@"
fi
exec "$executable" "${args[@]}" "$@"
