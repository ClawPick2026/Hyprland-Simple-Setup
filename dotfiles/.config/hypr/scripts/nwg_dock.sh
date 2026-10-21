#!/usr/bin/env bash
# Lifecycle for the nwg-dock-hyprland dock role (plan D01.4/D01.5).
#
# nwg-dock-hyprland 0.4.11 keeps pins in $XDG_CACHE_HOME/nwg-dock-pinned (one Hyprland
# window class per line, matched exactly) and only creates that file on the first manual
# pin. When no pin file exists yet, seed it from the selected roles (dock_pins.sh); an
# existing file, even an empty one, belongs to the user and is never rewritten. The dock
# runs resident (-r): a second start exits 0 without starting a duplicate.
#
# Usage: nwg_dock.sh [--seed-pins] [nwg-dock-hyprland args...]
set -euo pipefail

roles_file=${HSS_ROLES_FILE:-$HOME/.config/hypr/roles.json}
scripts_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
seed_only=false
if [[ ${1:-} == --seed-pins ]]; then
    seed_only=true
    shift
fi

[[ -r $roles_file ]] || { printf 'Missing role data: %s\n' "$roles_file" >&2; exit 1; }
dock=$(jq -r '.roles.dock.package // ""' "$roles_file")
# Dock None: nothing to start and nothing to seed.
[[ -n $dock ]] || exit 0
[[ $dock == nwg-dock-hyprland ]] || { printf 'nwg-dock-hyprland is not the selected dock\n' >&2; exit 2; }

# The dock panics without a cache directory; it is also where the pin file lives.
cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}
pinned_file=$cache_dir/nwg-dock-pinned
mkdir -p -- "$cache_dir"
if [[ ! -e $pinned_file && ! -L $pinned_file ]]; then
    tmp=$(mktemp "$cache_dir/.nwg-dock-pinned.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    HSS_ROLES_FILE=$roles_file "$scripts_dir/dock_pins.sh" class > "$tmp"
    chmod 644 -- "$tmp"
    mv -f -- "$tmp" "$pinned_file"
    trap - EXIT
fi
! $seed_only || exit 0

args=(-r -x -i 40)
# The launcher button opens the selected launcher; -c is split on spaces without a shell.
if [[ $scripts_dir =~ [[:space:]] ]]; then
    args+=(-nolauncher)
else
    args+=(-c "$scripts_dir/menu_exec.sh")
fi
[[ -z ${HSS_DOCK_OUTPUT:-} ]] || args+=(-o "$HSS_DOCK_OUTPUT")
exec nwg-dock-hyprland "${args[@]}" "$@"
