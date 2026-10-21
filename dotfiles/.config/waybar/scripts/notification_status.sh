#!/usr/bin/env bash
# Presentation adapter (plan D01): translate `status_read.sh notifications` into bar output.
#
# SwayNC keeps its native streaming status (swaync-client -swb) while it runs. Every other
# provider, and SwayNC while it is stopped, is read through the shared status contract, so
# do-not-disturb, waiting count, inhibition and unavailable states are shown as observed.
# Unknown values stay unknown; nothing is invented. Notification content is never read.
#
# Usage: notification_status.sh [--once] [--format waybar|plain|nwg]
set -euo pipefail

scripts_dir=${HSS_SCRIPTS_DIR:-$HOME/.config/hypr/scripts}
roles_file=${HSS_ROLES_FILE:-$HOME/.config/hypr/roles.json}
interval=${HSS_BAR_STATUS_INTERVAL:-3}
format=waybar
once=false

usage() {
    printf 'Usage: notification_status.sh [--once] [--format waybar|plain|nwg]\n' >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --once) once=true ;;
        --format) [[ $# -ge 2 ]] || { usage; exit 2; }; format=$2; shift ;;
        --format=*) format=${1#--format=} ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
    shift
done
case "$format" in waybar|plain|nwg) ;; *) usage; exit 2 ;; esac
[[ $interval =~ ^[1-9][0-9]*$ ]] || interval=3

role_provider() {
    [[ -r $roles_file ]] || return 0
    jq -r '.roles.notifications.package // ""' "$roles_file" 2>/dev/null || true
}

read_status() {
    local output
    if command -v timeout >/dev/null 2>&1; then
        output=$(timeout --kill-after=1 8 "$scripts_dir/status_read.sh" notifications 2>/dev/null) || output=""
    else
        output=$("$scripts_dir/status_read.sh" notifications 2>/dev/null) || output=""
    fi
    if jq -e 'type == "object" and .schema == 1' <<<"$output" >/dev/null 2>&1; then
        printf '%s\n' "$output"
    else
        printf '{"schema":1,"domain":"notifications","availability":"error","state":null,"capabilities":null,"error":"notification status could not be read"}\n'
    fi
}

# Map a status object to a presentation record: alt, text, classes, tooltip.
# shellcheck disable=SC2016
present_filter='
def pname: {"swaync": "SwayNC", "mako": "Mako", "dunst": "Dunst", "fnott": "Fnott"}[.] // .;
def clean: tostring | gsub("[<>&[:cntrl:]]"; " ") | .[0:160];
def num: if type == "number" and . >= 0 then floor else null end;
. as $s
| (($s.provider // $role) | tostring) as $p
| (if $p == "" then "Notifications" else ($p | pname) end) as $name
| ($s.state // {}) as $st
| ($s.capabilities // {}) as $cap
| ($s.availability // "error") as $availability
| ($st.count | num) as $count
| if $availability != "available" then
    {alt: (if $availability == "disabled" then "disabled" elif $availability == "error" then "error" else "unavailable" end),
     text: "",
     classes: [$availability] + (if $p == "" then [] else [$p] end),
     tooltip: ($name + ": "
        + ({"disabled": "no notification daemon is selected",
            "missing-dependency": "not installed",
            "unavailable": "unavailable",
            "unsupported": "status is not supported",
            "error": "status could not be read"}[$availability] // $availability)
        + (if ($s.error // "") != "" then "\n" + ($s.error | clean) else "" end))}
  elif $st.running == false then
    {alt: "stopped", text: "", classes: ["stopped", $p],
     tooltip: ($name + " is not running\nLeft click: notifications • Right click: do not disturb")}
  else
    (($st.dnd == true) as $dnd
     | ($st.inhibited == true) as $inhibited
     | ((if $dnd then "dnd-" else "" end) + (if $inhibited then "inhibited-" else "" end)
        + (if ($count // 0) > 0 then "notification" else "none" end)) as $alt
     | {alt: $alt,
        text: (if ($count // 0) > 0 then ($count | tostring) else "" end),
        classes: ([$alt, $p]
          + (if $cap.dnd == "unsupported" then ["dnd-unsupported"] elif $st.dnd == null then ["dnd-unknown"] else [] end)
          + (if $count == null then ["count-unknown"] else [] end)),
        tooltip: ([
          ($name + " notifications"),
          ("Waiting: " + (if $count == null then "unknown" else ($count | tostring) end)),
          ("Do not disturb: " + (if $cap.dnd == "unsupported" then "not supported by " + $name
                                  elif $st.dnd == true then "on" elif $st.dnd == false then "off" else "unknown" end)),
          (if $inhibited then "Popups are inhibited by an application" else empty end),
          "Left click: notifications • Right click: do not disturb"
        ] | join("\n"))})
  end
| .classes |= map(select(. != ""))'

# Plain-text glyphs for bars that show a single label.
# shellcheck disable=SC2016
plain_filter='
({"none": "", "notification": "", "dnd-none": "", "dnd-notification": "",
  "inhibited-none": "", "inhibited-notification": "", "dnd-inhibited-none": "",
  "dnd-inhibited-notification": "", "stopped": "", "disabled": "",
  "unavailable": "", "error": ""}[.alt] // "") as $icon
| ({"stopped": "off", "disabled": "none", "unavailable": "n/a", "error": "err"}[.alt] // .text) as $word
| $icon + (if $word == "" then "" else " " + $word end)'

pango() {
    local text=$1
    # Quoted replacements keep "&" literal (bash 5.2 patsub_replacement).
    text=${text//&/"&amp;"}
    text=${text//</"&lt;"}
    printf '%s' "${text//>/"&gt;"}"
}

emit() {
    local status=$1 record
    record=$(jq -c --arg role "$(role_provider)" "$present_filter" <<<"$status")
    case "$format" in
        waybar) jq -c '{text, alt, class: .classes, tooltip}' <<<"$record" ;;
        plain) jq -r "$plain_filter" <<<"$record" ;;
        nwg)
            # nwg-panel executor: icon line (empty), label, tooltip markup.
            printf '\n%s\n%s\n' "$(pango "$(jq -r "$plain_filter" <<<"$record")")" "$(pango "$(jq -r '.tooltip' <<<"$record")")"
            ;;
    esac
}

child=""
cleanup() {
    [[ -z $child ]] || kill "$child" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT HUP

while true; do
    status=$(read_status)
    provider=$(jq -r '.provider // ""' <<<"$status")
    [[ -n $provider ]] || provider=$(role_provider)
    if ! $once && [[ $format == waybar && $provider == swaync ]] \
        && command -v swaync-client >/dev/null 2>&1 \
        && jq -e '.availability == "available" and .state.running == true' <<<"$status" >/dev/null 2>&1; then
        # Native SwayNC stream; when it ends (daemon stopped), fall back to observed status.
        swaync-client -swb &
        child=$!
        wait "$child" || true
        child=""
        status=$(read_status)
    fi
    emit "$status"
    $once && break
    sleep "$interval" &
    wait $! || true
done
