#!/usr/bin/env bash
# Presentation adapter (plan D01): show the current dark/light variant from
# `status_read.sh theme` on every bar. The bar control itself runs
# `action_exec.sh theme.toggle`; this script only reads state.
#
# Usage: theme_status.sh [--format waybar|plain|nwg]
set -euo pipefail

scripts_dir=${HSS_SCRIPTS_DIR:-$HOME/.config/hypr/scripts}
format=waybar

usage() {
    printf 'Usage: theme_status.sh [--format waybar|plain|nwg]\n' >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --format) [[ $# -ge 2 ]] || { usage; exit 2; }; format=$2; shift ;;
        --format=*) format=${1#--format=} ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
    shift
done
case "$format" in waybar|plain|nwg) ;; *) usage; exit 2 ;; esac

if command -v timeout >/dev/null 2>&1; then
    status=$(timeout --kill-after=1 8 "$scripts_dir/status_read.sh" theme 2>/dev/null) || status=""
else
    status=$("$scripts_dir/status_read.sh" theme 2>/dev/null) || status=""
fi
jq -e 'type == "object" and .schema == 1' <<<"$status" >/dev/null 2>&1 \
    || status='{"schema":1,"domain":"theme","availability":"error","state":null,"error":"theme status could not be read"}'

# shellcheck disable=SC2016
record=$(jq -c '
def variant_label: {"dark": "Catppuccin Mocha (dark)", "light": "Catppuccin Latte (light)"}[.] // .;
def other: if . == "light" then "dark" else "light" end;
(.state // {}) as $st
| (.availability // "error") as $availability
| ($st.variant | if . == "dark" or . == "light" then . else null end) as $variant
| if $availability == "available" and $variant != null then
    (($st.batch == "partial") as $partial
     | {alt: $variant,
        classes: [$variant] + (if $partial then ["partial"] else [] end),
        tooltip: ([("Theme: " + ($variant | variant_label)),
                   (if $partial then "Some files kept local edits: "
                      + (($st.partial_units // []) | map(tostring | gsub("[^A-Za-z0-9_.-]"; "")) | join(", ")) else empty end),
                   ("Left click: switch to " + ($variant | other))] | join("\n"))})
  elif $availability == "unavailable" then
    (($st.default_variant | if . == "light" then "light" else "dark" end) as $default
     | {alt: "unavailable", classes: ["unavailable"],
        tooltip: ("Theme has not been applied yet (default: " + $default + ")\nLeft click: apply the " + ($default | other) + " theme")})
  else
    {alt: "error", classes: ["error"], tooltip: "Theme state could not be read\nLeft click: switch theme"}
  end' <<<"$status")

pango() {
    local text=$1
    # Quoted replacements keep "&" literal (bash 5.2 patsub_replacement).
    text=${text//&/"&amp;"}
    text=${text//</"&lt;"}
    printf '%s' "${text//>/"&gt;"}"
}

case "$format" in
    waybar)
        jq -c '{text: ({"dark": "Dark", "light": "Light", "unavailable": "Theme", "error": "Theme"}[.alt]), alt, class: .classes, tooltip}' <<<"$record"
        ;;
    plain)
        jq -r '({"dark": "", "light": ""}[.alt] // "")' <<<"$record"
        ;;
    nwg)
        # nwg-panel executor: icon line (empty), label, tooltip markup.
        printf '\n%s\n%s\n' "$(pango "$(jq -r '({"dark": "", "light": ""}[.alt] // "")' <<<"$record")")" "$(pango "$(jq -r '.tooltip' <<<"$record")")"
        ;;
esac
