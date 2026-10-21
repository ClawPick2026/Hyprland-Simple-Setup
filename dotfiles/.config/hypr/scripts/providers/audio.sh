#!/usr/bin/env bash
# shellcheck disable=SC2034 # HSS_PROVIDER/HSS_REASON/HSS_OBSERVED are read by action_exec.sh.

# Source-only audio provider (plan D04, policy P04). Opens the selected audio application in
# its general, per-application stream or device view. ALSA-only mixers have no stream view:
# streams requests return unsupported instead of opening another application. Status reads
# volume and mute through WirePlumber (wpctl) or PulseAudio's pactl and reports null when
# unknown. Contract: Documents/runtime-managed-configuration.md.

# shellcheck source=dotfiles/.config/hypr/scripts/providers/_launch.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/_launch.sh"

hss_audio_streams_supported() {
    case "${1:-}" in
        pavucontrol|pavucontrol-qt|ncpamixer) return 0 ;;
        *) return 1 ;;
    esac
}

# Open the selected audio application with extra native arguments through role_window.sh,
# which focuses an existing window or places a new one (terminal options go through
# role_exec.sh and term_exec.sh).
hss_audio_launch() {
    local -a command=()
    hss_launch_role_command audio command || return
    hss_launch_have_display || { hss_set_outcome unavailable "no graphical session is available"; return; }
    hss_have "${command[0]}" || { hss_set_outcome missing-dependency "${command[0]} is not installed"; return; }
    [[ -x $HSS_SCRIPTS_DIR/role_window.sh ]] || { hss_set_outcome missing-dependency "role_window.sh is not installed; rerun setup"; return; }
    hss_spawn "$HSS_SCRIPTS_DIR/role_window.sh" audio "$@" || return
    HSS_REASON="${command[0]} was opened${1:+ with $*}"
}

hss_action_audio_open() {
    hss_launch_select audio || return
    hss_audio_launch
}

hss_action_audio_streams_open() {
    hss_launch_select audio || return
    case "$HSS_PROVIDER" in
        pavucontrol|pavucontrol-qt) hss_audio_launch --tab=1 ;;
        ncpamixer) hss_audio_launch --tab=p ;;
        qastools) hss_set_outcome unsupported "QasMixer is an ALSA hardware mixer; it has no per-application stream controls" ;;
        alsa-utils) hss_set_outcome unsupported "Alsamixer is an ALSA hardware mixer; it has no per-application stream controls" ;;
        *) hss_set_outcome unsupported "$HSS_PROVIDER has no known per-application stream view" ;;
    esac
}

# Device-level controls: output devices for stream mixers, the mixer itself for ALSA mixers.
hss_action_audio_hardware_open() {
    hss_launch_select audio || return
    case "$HSS_PROVIDER" in
        pavucontrol|pavucontrol-qt) hss_audio_launch --tab=3 ;;
        ncpamixer) hss_audio_launch --tab=o ;;
        qastools|alsa-utils) hss_audio_launch ;;
        *) hss_set_outcome unsupported "$HSS_PROVIDER has no known device view" ;;
    esac
}

# Prints "PERCENT MUTED" from wpctl ("Volume: 0.35 [MUTED]"). Fails without a default node:
# wpctl then prints nothing on stdout but still exits 0.
hss_audio_wpctl_volume() {
    local output
    output=$(hss_run_bounded 3 wpctl get-volume "$1" 2>/dev/null) || return 1
    awk '$1 == "Volume:" && $2 ~ /^[0-9]+([.][0-9]+)?$/ {
        printf "%d %s\n", int($2 * 100 + 0.5), (index($0, "[MUTED]") ? "true" : "false"); found = 1; exit
    } END { exit !found }' <<<"$output"
}

# Prints "PERCENT MUTED" from pactl for @DEFAULT_SINK@ or @DEFAULT_SOURCE@.
hss_audio_pactl_volume() {
    local kind=$1 volume mute percent muted
    volume=$(hss_run_bounded 3 pactl "get-$kind-volume" "@DEFAULT_${kind^^}@" 2>/dev/null) || return 1
    mute=$(hss_run_bounded 3 pactl "get-$kind-mute" "@DEFAULT_${kind^^}@" 2>/dev/null) || return 1
    percent=$(grep -o '[0-9]\+%' <<<"$volume" | head -n 1)
    percent=${percent%\%}
    case "$mute" in
        *yes*) muted=true ;;
        *no*) muted=false ;;
        *) return 1 ;;
    esac
    [[ $percent =~ ^[0-9]+$ ]] || return 1
    printf '%s %s\n' "$percent" "$muted"
}

hss_audio_capabilities() {
    local package=${1:-}
    [[ -n $package ]] || { printf 'null\n'; return; }
    if hss_audio_streams_supported "$package"; then
        printf '{"streams":"supported","hardware":"supported"}\n'
    else
        case "$package" in
            qastools|alsa-utils) printf '{"streams":"unsupported","hardware":"supported"}\n' ;;
            *) printf '{"streams":"unverified","hardware":"unverified"}\n' ;;
        esac
    fi
}

hss_status_audio() {
    local package capabilities server="" output_line="" input_line="" info streams=""
    local output_volume="" output_muted="" input_volume="" input_muted="" availability=available error=""
    package=$(hss_role_package audio 2>/dev/null) || package=""
    capabilities=$(hss_audio_capabilities "$package")
    if [[ -n $package ]]; then
        if hss_audio_streams_supported "$package"; then streams=true; else streams=false; fi
    fi
    if hss_have wpctl && hss_run_bounded 3 wpctl status >/dev/null 2>&1; then
        server=pipewire
        output_line=$(hss_audio_wpctl_volume @DEFAULT_AUDIO_SINK@) || output_line=""
        input_line=$(hss_audio_wpctl_volume @DEFAULT_AUDIO_SOURCE@) || input_line=""
    elif hss_have pactl && info=$(hss_run_bounded 3 pactl info 2>/dev/null); then
        if grep -q 'on PipeWire' <<<"$info"; then server=pipewire; else server=pulseaudio; fi
        output_line=$(hss_audio_pactl_volume sink) || output_line=""
        input_line=$(hss_audio_pactl_volume source) || input_line=""
    elif ! hss_have wpctl && ! hss_have pactl; then
        availability=missing-dependency
        error="neither wpctl nor pactl is installed"
    else
        availability=unavailable
        error="no audio server is reachable"
    fi
    read -r output_volume output_muted <<<"$output_line"
    read -r input_volume input_muted <<<"$input_line"
    hss_status_emit audio "$package" "$availability" "$(jq -cn \
        --arg server "$server" --arg ov "$output_volume" --arg om "$output_muted" \
        --arg iv "$input_volume" --arg im "$input_muted" --arg streams "$streams" '
        def number: if . == "" then null else tonumber end;
        def boolean: if . == "true" then true elif . == "false" then false else null end;
        {server: (if $server == "" then null else $server end),
         output_volume: ($ov | number), output_muted: ($om | boolean),
         input_volume: ($iv | number), input_muted: ($im | boolean),
         streams_supported: ($streams | boolean)}')" "$capabilities" "$error"
}
