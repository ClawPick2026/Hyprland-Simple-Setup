#!/usr/bin/env bash
# Initial dock pins from the selected roles (plan D01.4): the primary terminal, browser,
# graphical file manager and GUI editor, in that order. None roles are omitted.
#
# Usage: dock_pins.sh class|desktop-file
#   class         Hyprland window class (nwg-dock-hyprland matches pins to running windows
#                 by exact class and launches <class>.desktop)
#   desktop-file  desktop file name (nwg-panel's pinned module opens <applications>/<name>)
set -euo pipefail

roles_file=${HSS_ROLES_FILE:-$HOME/.config/hypr/roles.json}
kind=${1:-}
case "$kind" in class|desktop-file) ;; *) printf 'Usage: dock_pins.sh class|desktop-file\n' >&2; exit 2 ;; esac
[[ -r $roles_file ]] || { printf 'Missing role data: %s\n' "$roles_file" >&2; exit 1; }

# Desktop IDs from the Arch packages (pacman -F); classes follow the application IDs that
# those desktop entries declare. Terminals and browsers carry their class in roles.json.
pin_for() {
    local role=$1 package class desktop id=""
    package=$(jq -r --arg role "$role" '.roles[$role].package // ""' "$roles_file")
    [[ -n $package ]] || return 0
    class=$(jq -r --arg role "$role" '.roles[$role].class // ""' "$roles_file")
    desktop=$(jq -r --arg role "$role" '.roles[$role].desktop_file // ""' "$roles_file")
    case "$role:$package" in
        file_manager:dolphin) class=org.kde.dolphin; desktop=org.kde.dolphin.desktop ;;
        file_manager:thunar) class=thunar; desktop=thunar.desktop ;;
        file_manager:nautilus) class=org.gnome.Nautilus; desktop=org.gnome.Nautilus.desktop ;;
        file_manager:nemo) class=nemo; desktop=nemo.desktop ;;
        file_manager:pcmanfm-qt) class=pcmanfm-qt; desktop=pcmanfm-qt.desktop ;;
        gui_editor:zed) class=dev.zed.Zed ;;
        gui_editor:visual-studio-code-bin) class=code ;;
        gui_editor:cursor-bin) class=cursor ;;
        gui_editor:kate) class=org.kde.kate ;;
        gui_editor:mousepad) class=org.xfce.mousepad ;;
    esac
    [[ -n $desktop || -z $class ]] || desktop=$class.desktop
    [[ -n $class || -z $desktop ]] || class=${desktop%.desktop}
    if [[ $kind == class ]]; then id=$class; else id=$desktop; fi
    [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 0
    printf '%s\n' "$id"
}

declare -A seen=()
for role in terminal browser file_manager gui_editor; do
    id=$(pin_for "$role")
    [[ -n $id && -z ${seen[$id]+x} ]] || continue
    seen[$id]=1
    printf '%s\n' "$id"
done
