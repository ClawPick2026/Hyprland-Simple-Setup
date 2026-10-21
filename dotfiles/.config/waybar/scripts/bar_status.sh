#!/usr/bin/env bash
# Presentation adapter (plan D01.3) for bars without native device modules (Ironbar script
# widgets and nwg-panel executors). It only reads native state: the shared
# `status_read.sh` contract for audio/network/bluetooth, sysfs for backlight, battery and
# lock-key LEDs, and the existing temperature/update producers. It never changes state.
# Unknown values stay unknown, absent hardware is "n/a", and no SSIDs, addresses or device
# aliases are shown.
#
# Usage: bar_status.sh [--format plain|nwg] [--watch] audio|network|bluetooth|backlight|
#                      battery|locks|temperature|clock|updates
#   plain: one label line (Ironbar).  nwg: empty icon line, label, tooltip (nwg-panel
#   executor protocol; Pango-escaped).  --watch (updates only): one line per update event.
set -euo pipefail

scripts_dir=${HSS_SCRIPTS_DIR:-$HOME/.config/hypr/scripts}
waybar_scripts=${HSS_WAYBAR_SCRIPTS:-$HOME/.config/waybar/scripts}
sysfs=${HSS_SYSFS_ROOT:-/sys}
format=plain
watch=false

usage() {
    printf 'Usage: bar_status.sh [--format plain|nwg] [--watch] audio|network|bluetooth|backlight|battery|locks|temperature|clock|updates\n' >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --format) [[ $# -ge 2 ]] || { usage; exit 2; }; format=$2; shift ;;
        --format=*) format=${1#--format=} ;;
        --watch) watch=true ;;
        -h|--help) usage; exit 0 ;;
        -*) usage; exit 2 ;;
        *) break ;;
    esac
    shift
done
[[ $# -eq 1 ]] || { usage; exit 2; }
kind=$1
case "$format" in plain|nwg) ;; *) usage; exit 2 ;; esac

pango() {
    local text=$1
    # Quoted replacements keep "&" literal (bash 5.2 patsub_replacement).
    text=${text//&/"&amp;"}
    text=${text//</"&lt;"}
    printf '%s' "${text//>/"&gt;"}"
}

# emit LABEL TOOLTIP
emit() {
    local label=$1 tooltip=$2
    case "$format" in
        plain) printf '%s\n' "$label" ;;
        nwg) printf '\n%s\n%s\n' "$(pango "$label")" "$(pango "$tooltip")" ;;
    esac
}

read_status() {
    local domain=$1 output
    if command -v timeout >/dev/null 2>&1; then
        output=$(timeout --kill-after=1 8 "$scripts_dir/status_read.sh" "$domain" 2>/dev/null) || output=""
    else
        output=$("$scripts_dir/status_read.sh" "$domain" 2>/dev/null) || output=""
    fi
    if jq -e 'type == "object" and .schema == 1' <<<"$output" >/dev/null 2>&1; then
        printf '%s\n' "$output"
    else
        printf '{"schema":1,"availability":"error","state":null,"capabilities":null,"error":"status could not be read"}\n'
    fi
}

# Print "label<TAB>tooltip" for a shared-status domain.
status_presentation() {
    local domain=$1 status
    status=$(read_status "$domain")
    # shellcheck disable=SC2016
    jq -r --arg domain "$domain" '
def clean: tostring | gsub("[[:cntrl:]]"; " ") | .[0:160];
def pct: if type == "number" then (floor | tostring) + "%" else "?" end;
(.state // {}) as $st | (.capabilities // {}) as $cap | (.availability // "error") as $a
| if $a != "available" then
    ({"audio": "", "network": "", "bluetooth": ""}[$domain]) as $icon
    | [$icon + " n/a",
       ({"audio": "Audio", "network": "Network", "bluetooth": "Bluetooth"}[$domain]) + ": "
       + ({"disabled": "disabled", "missing-dependency": "not installed", "unavailable": "unavailable",
           "unsupported": "not supported", "error": "status could not be read"}[$a] // $a)
       + (if (.error // "") != "" then "\n" + (.error | clean) else "" end)]
  elif $domain == "audio" then
    [(if $st.output_muted == true then " muted" elif $st.output_volume == null then " ?" else " " + ($st.output_volume | pct) end)
     + (if $st.input_muted == true then " " elif $st.input_volume != null then "  " + ($st.input_volume | pct) else "" end),
     (["Output: " + (if $st.output_muted == true then "muted" else ($st.output_volume | pct) end),
       "Microphone: " + (if $st.input_muted == true then "muted" else ($st.input_volume | pct) end),
       (if $st.streams_supported == false or $cap.streams == "unsupported" then "Application volumes: not supported by the selected audio app" else empty end),
       "Left click: application volumes • Right click: device mixer"] | join("\n"))]
  elif $domain == "network" then
    [(if $st.wifi_radio == "disabled" and $st.primary_type != "ethernet" then " off"
      elif $st.primary_state == "connected" and $st.primary_type == "wifi" then " " + ($st.signal | pct)
      elif $st.primary_state == "connected" and $st.primary_type == "ethernet" then ""
      elif $st.primary_state == "connected" then ""
      elif $st.primary_state == "connecting" then " …"
      elif $st.primary_state == "unavailable" then " n/a"
      else "⚠ Disconnected" end)
     + (if ($st.connectivity == "limited" or $st.connectivity == "portal") then " !" else "" end),
     (["Network: " + (($st.primary_type // "unknown") | tostring) + ", " + (($st.primary_state // "unknown") | tostring),
       "Connectivity: " + (($st.connectivity // "unknown") | tostring),
       "Wi-Fi radio: " + (($st.wifi_radio // "unknown") | tostring),
       "Left click: choose network • Right click: edit connections"] | join("\n"))]
  else
    [(if $st.controller == "absent" then " n/a"
      elif $st.blocked == true then " blocked"
      elif $st.powered == false then " off"
      elif ($st.connected_devices // 0) > 0 then " " + ($st.connected_devices | tostring)
      elif $st.powered == true then ""
      else " ?" end),
     ((if $st.controller == "absent" then ["No Bluetooth controller found"]
       else ["Bluetooth: " + (if $st.blocked == true then "blocked" elif $st.powered == true then "on" elif $st.powered == false then "off" else "unknown" end),
             "Connected devices: " + (($st.connected_devices // "unknown") | tostring)] end)
      + ["Left click: devices • Right click: power"] | join("\n"))]
  end
| map(gsub("\t"; " ")) | join("\t")' <<<"$status"
}

backlight_presentation() {
    local path best="" best_max=-1 max current
    for path in "$sysfs"/class/backlight/*; do
        [[ -r $path/brightness && -r $path/max_brightness ]] || continue
        max=$(<"$path/max_brightness")
        [[ $max =~ ^[0-9]+$ ]] || continue
        if ((max > best_max)); then best=$path; best_max=$max; fi
    done
    if [[ -z $best || $best_max -le 0 ]]; then
        printf '%s\t%s\n' $' n/a' "No backlight device was found; brightness control is unavailable."
        return
    fi
    current=$(<"$best/brightness")
    [[ $current =~ ^[0-9]+$ ]] || current=0
    printf '%s\t%s\n' $''" $((current * 100 / best_max))%" \
        "Brightness: $((current * 100 / best_max))%"$'\n'"Scroll: adjust"
}

battery_presentation() {
    local path type scope capacity status icon
    for path in "$sysfs"/class/power_supply/*; do
        [[ -r $path/type ]] || continue
        type=$(<"$path/type")
        [[ $type == Battery ]] || continue
        scope=""
        [[ ! -r $path/scope ]] || scope=$(<"$path/scope")
        [[ $scope != Device ]] || continue
        capacity=""
        [[ ! -r $path/capacity ]] || capacity=$(<"$path/capacity")
        status=unknown
        [[ ! -r $path/status ]] || status=$(<"$path/status")
        [[ $capacity =~ ^[0-9]+$ ]] || { printf '%s\t%s\n' $' ?' "Battery capacity is unknown"; return; }
        if [[ $status == Charging ]]; then icon=$''
        elif ((capacity <= 15)); then icon=$''
        elif ((capacity <= 30)); then icon=$''
        elif ((capacity <= 60)); then icon=$''
        elif ((capacity <= 80)); then icon=$''
        else icon=$''; fi
        local label="$capacity% $icon"
        if [[ $status != Charging ]] && ((capacity <= 15)); then label+=" critical"
        elif [[ $status != Charging ]] && ((capacity <= 30)); then label+=" low"; fi
        printf '%s\t%s\n' "$label" "Battery: $capacity%"$'\n'"Status: ${status,,}"
        return
    done
    printf '%s\t%s\n' $' n/a' "No system battery was found; battery status is unavailable."
}

# Lock-key LEDs are world-readable in sysfs; the baseline shows Num Lock only.
locks_presentation() {
    local led state=""
    for led in "$sysfs"/class/leds/*::numlock; do
        [[ -r $led/brightness ]] || continue
        if [[ $(<"$led/brightness") != 0 ]]; then state=on; else state=${state:-off}; fi
    done
    case "$state" in
        on) printf '%s\t%s\n' $' Num' "Num Lock: on" ;;
        off) printf '%s\t%s\n' $' Num' "Num Lock: off" ;;
        *) printf '%s\t%s\n' $' n/a' "No keyboard lock-key LED was found; lock-key state is unavailable." ;;
    esac
}

temperature_presentation() {
    local output
    output=$("$waybar_scripts/temperature_status.sh" 2>/dev/null) || output=""
    jq -r 'select(type == "object")
        | [(.text // "?") + (if .class == "critical" then " !" else "" end), (.tooltip // "")]
        | map(tostring | gsub("\t"; " ")) | join("\t")' <<<"$output" 2>/dev/null \
        || printf '%s\t%s\n' $' n/a' "Temperature could not be read"
}

clock_presentation() {
    local tz=${HSS_BAR_TIMEZONE:-Europe/Zurich} label calendar=""
    label=$(TZ=$tz date '+%a %d %b %Y | %H:%M')
    if command -v cal >/dev/null 2>&1; then
        calendar=$(TZ=$tz cal 2>/dev/null || true)
    fi
    printf '%s\t%s\n' "$label" "${calendar:+$calendar$'\n'}Left click: open selected calendar"
}

case "$kind" in
    audio|network|bluetooth) line=$(status_presentation "$kind") ;;
    backlight) line=$(backlight_presentation) ;;
    battery) line=$(battery_presentation) ;;
    locks) line=$(locks_presentation) ;;
    temperature) line=$(temperature_presentation) ;;
    clock) line=$(clock_presentation) ;;
    updates)
        # The update producer streams Waybar JSON; it is only available in watch mode.
        $watch || { emit $' ?' "Update count needs a streaming bar widget"; exit 0; }
        "$waybar_scripts/updates_status.sh" | while IFS= read -r event; do
            label=$(jq -r '((.text // "") | tostring) as $t | if $t == "" or $t == "0" then "" else " " + $t end' <<<"$event" 2>/dev/null) || continue
            emit "$label" "Left click: start system update"
        done
        exit 0
        ;;
    *) usage; exit 2 ;;
esac
emit "${line%%$'\t'*}" "${line#*$'\t'}"
