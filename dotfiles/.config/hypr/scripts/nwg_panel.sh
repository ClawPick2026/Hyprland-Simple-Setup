#!/usr/bin/env bash
set -euo pipefail

# One nwg-panel process owns the bar and the dock (upstream nwg-panel terminates other
# instances on start). Profiles are merged into hss-panels; only the bar answers the RT
# toggle signal. Plan D01.4/D01.5.
role=${1:-}
case "$role" in bar|dock) shift ;; *) printf 'Usage: nwg_panel.sh bar|dock [args...]\n' >&2; exit 2 ;; esac
roles_file=${HSS_ROLES_FILE:-$HOME/.config/hypr/roles.json}
scripts_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
selected=$(jq -er --arg role "$role" '.roles[$role].package' "$roles_file")
[[ $selected == nwg-panel ]] || { printf 'nwg-panel is not selected for %s\n' "$role" >&2; exit 2; }
bar=$(jq -r '.roles.bar.package // ""' "$roles_file")
dock=$(jq -r '.roles.dock.package // ""' "$roles_file")

# Upstream nwg-panel replaces existing instances. One process must own both panels.
if [[ $role == dock && $bar == nwg-panel ]]; then
    exit 0
fi
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/nwg-panel"
profiles=("$config_dir/$role")
if [[ $role == bar && $dock == nwg-panel ]]; then
    profiles+=("$config_dir/dock")
fi
for profile in "${profiles[@]}"; do
    [[ -r $profile ]] || { printf 'Missing nwg-panel profile: %s\n' "$profile" >&2; exit 1; }
done
signal=$(kill -l RTMIN)
tmp=$(mktemp "$config_dir/.hss-panels.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
# Executor scripts are split on spaces without a shell, so {HOME} becomes an absolute path.
jq -s --argjson signal "$signal" --arg home "$HOME" '
    add | map(
        .["use-sigrt"] = (.name == "bar")
        | if .name == "bar" then .sigrt = $signal else . end
    )
    | walk(if type == "string" then gsub("\\{HOME\\}"; $home) else . end)
' "${profiles[@]}" > "$tmp"
mv -f -- "$tmp" "$config_dir/hss-panels"
trap - EXIT

# The pinned module reads desktop file names from nwg-pin-cache and creates no pin area
# when the file is missing at start. Seed it once; an existing file belongs to the user.
if jq -e 'any(.[]; (.["modules-left"] + .["modules-center"] + .["modules-right"]) | index("pinned"))' \
    "$config_dir/hss-panels" >/dev/null 2>&1; then
    cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}
    if [[ ! -e $cache_dir/nwg-pin-cache && ! -L $cache_dir/nwg-pin-cache ]]; then
        mkdir -p -- "$cache_dir"
        pins=$(mktemp "$cache_dir/.nwg-pin-cache.XXXXXX")
        HSS_ROLES_FILE=$roles_file "$scripts_dir/dock_pins.sh" desktop-file > "$pins" || { rm -f -- "$pins"; exit 1; }
        chmod 644 -- "$pins"
        mv -f -- "$pins" "$cache_dir/nwg-pin-cache"
    fi
fi

# Themed stylesheet: hss-style.css holds the theme region and the user's own rules. Use it
# only when every stylesheet it imports exists, so a removed theme never breaks startup.
style_args=()
if [[ -r $config_dir/hss-style.css ]]; then
    usable=true
    while IFS= read -r imported; do
        # Import URLs are percent-encoded (for example a space is %20).
        imported=$(printf '%b' "${imported//%/\\x}")
        [[ -r $imported ]] || usable=false
    done < <(grep -o 'url("file://[^"]*")' "$config_dir/hss-style.css" | sed 's|^url("file://||; s|")$||')
    if $usable; then
        style_args=(-s hss-style.css)
    fi
fi
exec nwg-panel -c hss-panels "${style_args[@]}" "$@"
