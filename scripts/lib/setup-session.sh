#!/usr/bin/env bash
# Setup-time session functions (plan D07). Source-only: defines functions, no side effects.
# Call configure_session_authentication_autostart, configure_session_wlogout_layout and
# configure_session_hypridle_dispatch after configure_hypr_autostart_optional_extras.
# Requires setup.sh helpers: replace_exact_trimmed_line, role_write_file, make_tmp,
# is_dry_run, write_file_atomic and print_message.

# Migrate the authentication-agent autostart requests that earlier setup versions wrote:
# Hyprpolkitagent becomes the managed owner through session.auth.start, and the duplicate
# setup-owned KDE agent request is removed. Only exact setup-written lines change; edited
# or user-added lines stay untouched, and no running agent is stopped.
configure_session_authentication_autostart() {
    local root lua_file conf_file
    local lua_old='hl.exec_cmd("systemctl --user start hyprpolkitagent")'
    local lua_new='    hl.exec_cmd(apps.hyprscripts .. "/action_exec.sh --quiet session.auth.start")'
    local lua_kde='hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1")'
    local conf_old='exec-once = systemctl --user start hyprpolkitagent &'
    # shellcheck disable=SC2016 # $hyprscripts is a literal Hyprland variable.
    local conf_new='exec-once = $hyprscripts/action_exec.sh --quiet session.auth.start'
    local conf_kde='exec-once = /usr/lib/polkit-kde-authentication-agent-1 &'

    for root in "$HOME/dotfiles/.config/hypr/sources" "$HOME/dotfiles/.config/hypr/sources_example"; do
        lua_file="$root/autostart.lua"
        conf_file="$root/autostart.conf"
        if [ -f "$lua_file" ]; then
            replace_exact_trimmed_line "$lua_file" "$lua_old" "$lua_new" "Start Hyprpolkitagent through session.auth.start" || return 1
            session_remove_exact_trimmed_line "$lua_file" "$lua_kde" "Remove duplicate KDE authentication agent autostart" || return 1
        fi
        if [ -f "$conf_file" ]; then
            replace_exact_trimmed_line "$conf_file" "$conf_old" "$conf_new" "Start Hyprpolkitagent through session.auth.start" || return 1
            session_remove_exact_trimmed_line "$conf_file" "$conf_kde" "Remove duplicate KDE authentication agent autostart" || return 1
        fi
    done
}

# Point the Wlogout buttons that earlier setup versions shipped at the shared session actions,
# so logout ends only the current session and logout/reboot/shutdown ask for confirmation.
# Only the exact shipped action lines change; customized buttons stay untouched.
configure_session_wlogout_layout() {
    local layout="$HOME/dotfiles/.config/wlogout/layout" old action
    [ -f "$layout" ] || return 0
    # shellcheck disable=SC2016 # $USER is part of the literal line shipped earlier
    local -a pairs=(
        'lock|loginctl lock-session'
        'hibernate|systemctl hibernate'
        'logout|loginctl terminate-user $USER'
        'shutdown|systemctl poweroff'
        'suspend|systemctl suspend'
        'reboot|systemctl reboot'
    )
    local pair
    for pair in "${pairs[@]}"; do
        action=${pair%%|*}
        old=${pair#*|}
        replace_exact_trimmed_line "$layout" "\"action\" : \"$old\"," \
            "    \"action\" : \"\\\"\$HOME/.config/hypr/scripts/action_exec.sh\\\" session.$action\"," \
            "Use session.$action in the power screen" || return 1
    done
}

# Hyprland 0.55+ reads hyprctl dispatchers as Lua; migrate the shipped Hypridle resume line.
configure_session_hypridle_dispatch() {
    local file="$HOME/dotfiles/.config/hypr/hypridle.conf"
    [ -f "$file" ] || return 0
    replace_exact_trimmed_line "$file" \
        'after_sleep_cmd = hyprctl dispatch dpms on  # to avoid having to press a key twice to turn on the display.' \
        "    after_sleep_cmd = hyprctl dispatch 'hl.dsp.dpms({action = \"on\"})' # turn the display on without a second key press." \
        "Use the Lua dpms dispatcher after sleep"
}

# session_remove_exact_trimmed_line FILE LINE REASON: drop lines whose trimmed text is LINE.
session_remove_exact_trimmed_line() {
    local file=$1 line=$2 reason=$3 tmp status=0
    [ -f "$file" ] || return 0
    if is_dry_run; then
        grep -Fxq -- "$line" <(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$file") || return 0
        write_file_atomic "$file" /dev/null "$reason"
        return 0
    fi
    make_tmp tmp session-edit.XXXXXX || return 1
    HSS_LINE=$line awk '
        {
            comparison = $0
            sub(/^[[:space:]]+/, "", comparison)
            sub(/[[:space:]]+$/, "", comparison)
            if (comparison == ENVIRON["HSS_LINE"]) { removed = 1; next }
            print
        }
        END { if (!removed) exit 3 }
    ' "$file" > "$tmp" || status=$?
    case "$status" in 0) ;; 3) return 0 ;; *) return "$status" ;; esac
    cmp -s -- "$file" "$tmp" && return 0
    role_write_file "$file" "$tmp" "$reason"
}
