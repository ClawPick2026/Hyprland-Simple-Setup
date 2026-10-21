#!/usr/bin/env bash

# Source-only notification provider (plan D03). Contract: Documents/runtime-managed-configuration.md.
#
# Actions: notifications.primary, notifications.center.toggle, notifications.history.open, notifications.dismiss.all,
#          notifications.dnd.set <on|off>, notifications.dnd.toggle
# Status:  hss_status_notifications (state: running, dnd, count, history_count, center_visible,
#          inhibited; null when not observable; never notification content)
#
# Rules (evidence: capabilities.d/d03-notifications.json):
# - Only the selected provider's native CLI/D-Bus interface is used; a missing native capability
#   is `unsupported` with an explanation, never emulated or substituted.
# - Before any call, the owner of org.freedesktop.Notifications is checked with GetNameOwner /
#   GetConnectionUnixProcessID (these never activate a service). Provider clients are called
#   only when the selected provider owns the name: makoctl/dunstctl/swaync-client could
#   otherwise D-Bus-activate a daemon (E-D03-003). Not running -> unavailable; a foreign owner
#   -> conflict.
# - Readback uses `busctl --user --auto-start=no call ...`, which cannot start a daemon
#   (E-D03-004); `busctl get-property` is never used because it ignores --auto-start=no.
#   A requested state is `completed` only when the readback matches it.
# - Nothing read here is logged; history listings are only counted.

HSS_NOTIFY_BUS_NAME=org.freedesktop.Notifications

hss_notif_client_of() {
    case "$1" in
        swaync) printf 'swaync-client\n' ;;
        mako) printf 'makoctl\n' ;;
        dunst) printf 'dunstctl\n' ;;
        fnott) printf 'fnottctl\n' ;;
        *) return 1 ;;
    esac
}

hss_notif_label() {
    case "$1" in
        swaync) printf 'SwayNC\n' ;;
        mako) printf 'Mako\n' ;;
        dunst) printf 'Dunst\n' ;;
        fnott) printf 'Fnott\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# Static native capability map of a provider (status `capabilities`).
hss_notif_capabilities() {
    case "$1" in
        swaync) printf '{"dnd":"supported","history":"supported","center":"supported","dismiss":"supported","actions":"supported"}\n' ;;
        mako|dunst) printf '{"dnd":"supported","history":"unsupported","center":"unsupported","dismiss":"supported","actions":"supported"}\n' ;;
        fnott) printf '{"dnd":"unsupported","history":"unsupported","center":"unsupported","dismiss":"supported","actions":"supported"}\n' ;;
        *) printf 'null\n' ;;
    esac
}

# Sets HSS_NOTIF_PROVIDER/HSS_PROVIDER, or records an outcome and returns its status.
hss_notif_select() {
    hss_require_roles || return
    HSS_NOTIF_PROVIDER=$(hss_role_package notifications 2>/dev/null) || HSS_NOTIF_PROVIDER=""
    if [[ -z $HSS_NOTIF_PROVIDER ]]; then
        hss_set_outcome unavailable "no notification provider is selected; rerun setup"
        return
    fi
    # shellcheck disable=SC2034 # read by action_exec.sh for the result envelope
    HSS_PROVIDER=$HSS_NOTIF_PROVIDER
    if ! hss_notif_client_of "$HSS_NOTIF_PROVIDER" >/dev/null; then
        hss_set_outcome unsupported "$HSS_NOTIF_PROVIDER is not a known notification provider"
        return
    fi
}

# Sets HSS_NOTIF_OWNER to selected, none, foreign or unknown, and HSS_NOTIF_OWNER_NAME.
hss_notif_owner() {
    local provider=$1 pid name
    HSS_NOTIF_OWNER_NAME=""
    if pid=$(hss_dbus_name_pid "$HSS_NOTIFY_BUS_NAME" 2>/dev/null) && [[ $pid =~ ^[0-9]+$ ]]; then
        name=$(hss_process_name "$pid" 2>/dev/null) || name=""
        HSS_NOTIF_OWNER_NAME=$name
        if [[ -n $name && $name == "$provider" ]]; then
            HSS_NOTIF_OWNER=selected
        else
            HSS_NOTIF_OWNER=foreign
        fi
        return 0
    fi
    # Nobody owns the name, or there is no bus: the bus daemon itself always owns org.freedesktop.DBus.
    if hss_dbus_name_owner org.freedesktop.DBus >/dev/null 2>&1; then
        HSS_NOTIF_OWNER=none
    else
        HSS_NOTIF_OWNER=unknown
    fi
}

# Selected provider is installed and owns the bus name; otherwise records the outcome.
hss_notif_ready() {
    local client label
    client=$(hss_notif_client_of "$HSS_NOTIF_PROVIDER")
    label=$(hss_notif_label "$HSS_NOTIF_PROVIDER")
    hss_have "$client" || { hss_set_outcome missing-dependency "$client is not installed"; return; }
    hss_notif_owner "$HSS_NOTIF_PROVIDER"
    case "$HSS_NOTIF_OWNER" in
        selected) return 0 ;;
        none) hss_set_outcome unavailable "$label is not running" ;;
        foreign) hss_set_outcome conflict "another notification service (${HSS_NOTIF_OWNER_NAME:-unidentified}) owns the notification bus name" ;;
        *) hss_set_outcome unavailable "the session bus is not reachable" ;;
    esac
}

# Run a provider client with a bounded wait. Its output is discarded: state is read back
# separately and client output may contain notification text.
hss_notif_run() {
    local status=0
    hss_run_bounded 5 "$@" </dev/null >/dev/null 2>&1 || status=$?
    if ((status == 124 || status == 137)); then
        hss_set_outcome timeout "$1 did not answer in time"
        return
    fi
    if ((status != 0)); then
        hss_set_outcome failed "$1 failed with status $status"
        return
    fi
}

# busctl call without D-Bus activation. Prints busctl's reply.
hss_notif_bus() {
    hss_have busctl || return 2
    hss_run_bounded 3 busctl --user --auto-start=no call "$@" </dev/null 2>/dev/null
}

hss_notif_bool() {
    case "$1" in
        true) printf 'true\n' ;;
        false) printf 'false\n' ;;
        *) printf 'null\n' ;;
    esac
}

hss_notif_int() {
    if [[ $1 =~ ^[0-9]{1,9}$ ]]; then printf '%d\n' "$((10#$1))"; else printf 'null\n'; fi
}

# Read the provider state into HSS_NOTIF_{DND,COUNT,HISTORY,VISIBLE,INHIBITED} as JSON scalars.
# Only call while the selected provider owns the bus name.
hss_notif_read() {
    local provider=$1 reply a b c d e
    HSS_NOTIF_DND=null HSS_NOTIF_COUNT=null HSS_NOTIF_HISTORY=null HSS_NOTIF_VISIBLE=null HSS_NOTIF_INHIBITED=null
    case "$provider" in
        swaync)
            # GetSubscribeData -> "(bbub) DND VISIBLE COUNT INHIBITED"; COUNT is the control-center
            # list, which is also SwayNC's history, so history_count stays null.
            reply=$(hss_notif_bus org.erikreider.swaync.cc /org/erikreider/swaync/cc \
                org.erikreider.swaync.cc GetSubscribeData) || return 1
            read -r a b c d e <<<"$reply"
            [[ $a == '(bbub)' ]] || return 1
            HSS_NOTIF_DND=$(hss_notif_bool "$b")
            HSS_NOTIF_VISIBLE=$(hss_notif_bool "$c")
            HSS_NOTIF_COUNT=$(hss_notif_int "$d")
            HSS_NOTIF_INHIBITED=$(hss_notif_bool "$e")
            ;;
        mako)
            reply=$(hss_notif_bus "$HSS_NOTIFY_BUS_NAME" /fr/emersion/Mako org.freedesktop.DBus.Properties \
                Get ss fr.emersion.Mako Modes) || return 1
            [[ $reply == 'v as '* ]] || return 1
            if [[ " $reply " == *' "do-not-disturb" '* ]]; then HSS_NOTIF_DND=true; else HSS_NOTIF_DND=false; fi
            reply=$(hss_notif_bus "$HSS_NOTIFY_BUS_NAME" /fr/emersion/Mako fr.emersion.Mako ListNotifications) || return 1
            read -r a b _ <<<"$reply"
            [[ $a == 'aa{sv}' ]] && HSS_NOTIF_COUNT=$(hss_notif_int "$b")
            reply=$(hss_notif_bus "$HSS_NOTIFY_BUS_NAME" /fr/emersion/Mako fr.emersion.Mako ListHistory) || return 1
            read -r a b _ <<<"$reply"
            [[ $a == 'aa{sv}' ]] && HSS_NOTIF_HISTORY=$(hss_notif_int "$b")
            ;;
        dunst)
            local property value displayed=null waiting=null
            for property in paused displayedLength waitingLength historyLength; do
                reply=$(hss_notif_bus "$HSS_NOTIFY_BUS_NAME" /org/freedesktop/Notifications \
                    org.freedesktop.DBus.Properties Get ss org.dunstproject.cmd0 "$property") || return 1
                read -r a b value <<<"$reply"
                [[ $a == v ]] || return 1
                case "$property" in
                    paused) HSS_NOTIF_DND=$(hss_notif_bool "$value") ;;
                    displayedLength) displayed=$(hss_notif_int "$value") ;;
                    waitingLength) waiting=$(hss_notif_int "$value") ;;
                    historyLength) HSS_NOTIF_HISTORY=$(hss_notif_int "$value") ;;
                esac
            done
            if [[ $displayed != null && $waiting != null ]]; then
                HSS_NOTIF_COUNT=$((displayed + waiting))
            fi
            ;;
        fnott)
            # fnottctl talks to fnott's own socket and cannot activate anything; one line per notification.
            reply=$(hss_run_bounded 3 fnottctl list </dev/null 2>/dev/null) || return 1
            HSS_NOTIF_COUNT=$(grep -c . <<<"$reply" || true)
            ;;
    esac
}

hss_notif_observed() {
    # shellcheck disable=SC2034 # read by action_exec.sh for the result envelope
    HSS_OBSERVED=$(jq -cn --argjson dnd "$HSS_NOTIF_DND" --argjson count "$HSS_NOTIF_COUNT" \
        --argjson center_visible "$HSS_NOTIF_VISIBLE" '{dnd: $dnd, count: $count, center_visible: $center_visible}')
}

# Primary bar gesture (left click), matching the v0.7.0 baseline per provider: SwayNC toggles
# its control center; mako, dunst and fnott dismiss all popups. Reuses the semantic handlers.
hss_action_notifications_primary() {
    [[ $# -eq 0 ]] || { hss_set_outcome usage "notifications.primary takes no arguments"; return; }
    hss_notif_select || return
    if [[ $HSS_NOTIF_PROVIDER == swaync ]]; then
        hss_action_notifications_center_toggle "$@"
    else
        hss_action_notifications_dismiss_all "$@"
    fi
}

hss_action_notifications_center_toggle() {
    [[ $# -eq 0 ]] || { hss_set_outcome usage "notifications.center.toggle takes no arguments"; return; }
    hss_notif_select || return
    if [[ $HSS_NOTIF_PROVIDER != swaync ]]; then
        hss_set_outcome unsupported "$(hss_notif_label "$HSS_NOTIF_PROVIDER") has no notification center"
        return
    fi
    hss_notif_ready || return
    local before after
    hss_notif_read swaync || HSS_NOTIF_VISIBLE=null
    before=$HSS_NOTIF_VISIBLE
    hss_notif_run swaync-client --skip-wait --toggle-panel || return
    for _ in 1 2 3 4 5; do
        hss_notif_read swaync || HSS_NOTIF_VISIBLE=null
        after=$HSS_NOTIF_VISIBLE
        [[ $before == null || $after == null || $after != "$before" ]] && break
        sleep 0.2
    done
    hss_notif_observed
    if [[ $before == null || $after == null ]]; then
        hss_set_outcome accepted "the control center was toggled; its visibility could not be read back"
    elif [[ $after != "$before" ]]; then
        hss_set_outcome completed "the control center is now $([[ $after == true ]] && printf open || printf closed)"
    else
        hss_set_outcome failed "the control center visibility did not change"
    fi
}

hss_action_notifications_history_open() {
    [[ $# -eq 0 ]] || { hss_set_outcome usage "notifications.history.open takes no arguments"; return; }
    hss_notif_select || return
    case "$HSS_NOTIF_PROVIDER" in
        mako)
            hss_set_outcome unsupported "Mako keeps a native history but has no view to browse it; makoctl restore only shows the latest entry again"
            return
            ;;
        dunst)
            hss_set_outcome unsupported "Dunst keeps a native history but has no view to browse it; dunstctl history-pop only shows the latest entry again"
            return
            ;;
        fnott)
            hss_set_outcome unsupported "Fnott keeps no notification history"
            return
            ;;
    esac
    hss_notif_ready || return
    hss_notif_run swaync-client --skip-wait --open-panel || return
    for _ in 1 2 3 4 5; do
        hss_notif_read swaync || HSS_NOTIF_VISIBLE=null
        [[ $HSS_NOTIF_VISIBLE != false ]] && break
        sleep 0.2
    done
    hss_notif_observed
    case "$HSS_NOTIF_VISIBLE" in
        true) hss_set_outcome completed "the notification center with the history is open" ;;
        false) hss_set_outcome failed "the notification center did not open" ;;
        *) hss_set_outcome accepted "the notification center was opened; its visibility could not be read back" ;;
    esac
}

hss_action_notifications_dismiss_all() {
    [[ $# -eq 0 ]] || { hss_set_outcome usage "notifications.dismiss.all takes no arguments"; return; }
    hss_notif_select || return
    hss_notif_ready || return
    case "$HSS_NOTIF_PROVIDER" in
        swaync)
            # Hides every popup and keeps the entries in the control center (its history).
            hss_notif_run swaync-client --skip-wait --hide-all || return
            hss_set_outcome accepted "popups were hidden; the notification center keeps them"
            return
            ;;
        mako) hss_notif_run makoctl dismiss --all || return ;;
        dunst) hss_notif_run dunstctl close-all || return ;;
        fnott) hss_notif_run fnottctl dismiss all || return ;;
    esac
    local shown=null
    if hss_notif_read "$HSS_NOTIF_PROVIDER"; then
        shown=$HSS_NOTIF_COUNT
        if [[ $HSS_NOTIF_PROVIDER == dunst ]]; then
            local reply value
            reply=$(hss_notif_bus "$HSS_NOTIFY_BUS_NAME" /org/freedesktop/Notifications \
                org.freedesktop.DBus.Properties Get ss org.dunstproject.cmd0 displayedLength) || reply=""
            read -r _ _ value <<<"$reply"
            shown=$(hss_notif_int "$value")
        fi
    fi
    hss_notif_observed
    if [[ $shown == 0 ]]; then
        hss_set_outcome completed "all notifications were dismissed"
    elif [[ $shown == null ]]; then
        hss_set_outcome accepted "dismissal was requested; the result could not be read back"
    elif [[ $HSS_NOTIF_PROVIDER == dunst ]]; then
        hss_set_outcome accepted "notifications were dismissed; queued notifications were shown afterwards"
    else
        hss_set_outcome failed "$shown notification(s) are still shown"
    fi
}

hss_notif_dnd_unsupported() {
    hss_set_outcome unsupported "Fnott can pause notifications but cannot report whether it is paused, and pausing also hides critical notifications"
}

# hss_notif_dnd_apply on|off: change DND natively and require a matching readback.
hss_notif_dnd_apply() {
    local wanted=$1 want_bool
    [[ $wanted == on ]] && want_bool=true || want_bool=false
    hss_notif_read "$HSS_NOTIF_PROVIDER" || HSS_NOTIF_DND=null
    if [[ $HSS_NOTIF_DND != "$want_bool" ]]; then
        case "$HSS_NOTIF_PROVIDER:$wanted" in
            swaync:on) hss_notif_run swaync-client --skip-wait --dnd-on || return ;;
            swaync:off) hss_notif_run swaync-client --skip-wait --dnd-off || return ;;
            mako:on) hss_notif_run makoctl mode -a do-not-disturb || return ;;
            mako:off) hss_notif_run makoctl mode -r do-not-disturb || return ;;
            dunst:on) hss_notif_run dunstctl set-paused true || return ;;
            dunst:off) hss_notif_run dunstctl set-paused false || return ;;
        esac
        hss_notif_read "$HSS_NOTIF_PROVIDER" || HSS_NOTIF_DND=null
    fi
    hss_notif_observed
    if [[ $HSS_NOTIF_DND == "$want_bool" ]]; then
        hss_set_outcome completed "do not disturb is $wanted"
    elif [[ $HSS_NOTIF_DND == null ]]; then
        hss_set_outcome failed "do not disturb could not be read back after the change"
    else
        hss_set_outcome failed "do not disturb is still $([[ $want_bool == true ]] && printf off || printf on) after the change"
    fi
}

hss_action_notifications_dnd_set() {
    local wanted=${1:-}
    [[ $# -eq 1 && ( $wanted == on || $wanted == off ) ]] || { hss_set_outcome usage "notifications.dnd.set takes on or off"; return; }
    hss_notif_select || return
    [[ $HSS_NOTIF_PROVIDER != fnott ]] || { hss_notif_dnd_unsupported; return; }
    hss_notif_ready || return
    hss_notif_dnd_apply "$wanted"
}

hss_action_notifications_dnd_toggle() {
    [[ $# -eq 0 ]] || { hss_set_outcome usage "notifications.dnd.toggle takes no arguments"; return; }
    hss_notif_select || return
    [[ $HSS_NOTIF_PROVIDER != fnott ]] || { hss_notif_dnd_unsupported; return; }
    hss_notif_ready || return
    hss_notif_read "$HSS_NOTIF_PROVIDER" || HSS_NOTIF_DND=null
    case "$HSS_NOTIF_DND" in
        true) hss_notif_dnd_apply off ;;
        false) hss_notif_dnd_apply on ;;
        *) hss_set_outcome failed "the current do not disturb state could not be read" ;;
    esac
}

hss_status_notifications() {
    local provider="" capabilities=null availability error="" running=null state client
    HSS_NOTIF_DND=null HSS_NOTIF_COUNT=null HSS_NOTIF_HISTORY=null HSS_NOTIF_VISIBLE=null HSS_NOTIF_INHIBITED=null
    if [[ ! -r $(hss_roles_file) ]]; then
        availability=unavailable error="role data is missing"
    else
        provider=$(hss_role_package notifications 2>/dev/null) || provider=""
        capabilities=$(hss_notif_capabilities "$provider")
        if [[ -z $provider ]]; then
            availability=unavailable error="no notification provider is selected"
        elif ! client=$(hss_notif_client_of "$provider"); then
            availability=unsupported error="unknown notification provider"
        elif ! hss_have "$provider" || ! hss_have "$client"; then
            availability=missing-dependency running=false error="$provider or $client is not installed"
        else
            hss_notif_owner "$provider"
            case "$HSS_NOTIF_OWNER" in
                selected)
                    availability=available running=true
                    hss_notif_read "$provider" || error="the provider state could not be read"
                    ;;
                none) availability=unavailable running=false error="$provider is not running" ;;
                foreign) availability=unavailable running=false error="another notification service owns the notification bus name" ;;
                *) availability=unavailable error="the session bus is not reachable" ;;
            esac
        fi
    fi
    state=$(jq -cn --argjson running "$running" --argjson dnd "$HSS_NOTIF_DND" --argjson count "$HSS_NOTIF_COUNT" \
        --argjson history_count "$HSS_NOTIF_HISTORY" --argjson center_visible "$HSS_NOTIF_VISIBLE" \
        --argjson inhibited "$HSS_NOTIF_INHIBITED" \
        '{running: $running, dnd: $dnd, count: $count, history_count: $history_count,
          center_visible: $center_visible, inhibited: $inhibited}')
    hss_status_emit notifications "$provider" "$availability" "$state" "$capabilities" "$error"
}
