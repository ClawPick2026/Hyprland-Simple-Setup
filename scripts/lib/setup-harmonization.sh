#!/usr/bin/env bash

# Setup-time desktop harmonization (plan I01.3/I01.4). Sourced by setup.sh; functions only.
# Theme rendering and commits go through the installed providers/theme.sh, which uses the
# active setup reliability run, so `setup.sh --rollback RUN_ID` also restores theme changes.
# Contract: Documents/runtime-managed-configuration.md, section 8.

HSS_DOTFILES_FRESH=${HSS_DOTFILES_FRESH:-false}
HSS_THEME_TOGGLE_MARKER='hss-theme:toggle-binding'

# Print the scripts directory that holds the runtime providers for this run.
harmonization_scripts_dir() {
    local installed="$HOME/dotfiles/.config/hypr/scripts"
    if [ -r "$installed/providers/theme.sh" ] && [ -r "$installed/lib/hss_runtime.sh" ]; then
        printf '%s\n' "$installed"
    else
        printf '%s\n' "$SETUP_SCRIPT_ROOT/dotfiles/.config/hypr/scripts"
    fi
}

harmonization_theme_root() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/hss-theme"
}

# Previously adopted installations keep applying selection changes; new adopters preview first.
harmonization_adoption_mode() {
    local requested=${HSS_HARMONIZATION_ADOPT:-} root
    root=$(harmonization_theme_root)
    if [ -n "$requested" ]; then
        case "$requested" in
            preview|apply|skip) printf '%s\n' "$requested"; return 0 ;;
            *) print_error "HSS_HARMONIZATION_ADOPT must be preview, apply or skip (got '$requested')" >&2; return 2 ;;
        esac
    fi
    if [ "$HSS_DOTFILES_FRESH" = true ]; then
        printf 'fresh\n'
    elif [ -s "$root/managed.json" ] && jq -e '(.keys | length) + (.regions | length) > 0' "$root/managed.json" >/dev/null 2>&1; then
        printf 'adopted\n'
    else
        printf 'preview\n'
    fi
}

harmonization_variant() {
    local requested=${HSS_THEME_VARIANT:-} state current
    if [ -n "$requested" ]; then
        case "$requested" in
            dark|light) printf '%s\n' "$requested"; return 0 ;;
            *) print_error "HSS_THEME_VARIANT must be dark or light (got '$requested')" >&2; return 2 ;;
        esac
    fi
    state="$(harmonization_theme_root)/state.json"
    current=$(jq -r '.variant // empty' "$state" 2>/dev/null || true)
    case "$current" in
        dark|light) printf '%s\n' "$current" ;;
        *) printf 'dark\n' ;;
    esac
}

# Add the Super+Shift+T theme binding unless the user already bound that chord.
harmonization_theme_binding() {
    local file=$1 adopt=$2 line status=0 existing
    [ -f "$file" ] || return 0
    grep -Fq "$HSS_THEME_TOGGLE_MARKER" "$file" && return 0
    existing=$(python3 "$SETUP_SCRIPT_ROOT/scripts/lib/keybinding-chords.py" "$file" SUPER SHIFT T 2>/dev/null) || status=$?
    if [ "$status" -eq 0 ]; then
        print_warning "Super+Shift+T is already bound in $file (line ${existing%%:*}); the theme toggle remains available from the bar."
        record_warning "configure_harmonization" "Super+Shift+T conflict in $(basename -- "$file"); theme binding not added"
        return 0
    elif [ "$status" -ne 1 ]; then
        print_warning "Could not check $file for an existing Super+Shift+T binding; the theme binding was not added."
        record_warning "configure_harmonization" "Keybinding check failed for $(basename -- "$file")"
        return 0
    fi
    [ "$adopt" = true ] || return 0
    line="bind(main_mod .. \" + SHIFT + T\", \"Toggle Dark/Light Theme\", hl.dsp.exec_cmd(apps.hyprscripts .. \"/action_exec.sh theme.toggle\")) -- $HSS_THEME_TOGGLE_MARKER"
    append_text_atomic "$file" "Add the dark/light theme binding" "$line
"
}

# Point Xcursor consumers at the matching Rose Pine Xcursor theme (exact stock line only).
harmonization_cursor_environment() {
    local file=$1
    replace_exact_trimmed_line "$file" 'hl.env("XCURSOR_THEME", apps.cursor)' \
        'hl.env("XCURSOR_THEME", "BreezeX-RosePine-Linux")' "Use the Xcursor build of the Rose Pine cursor"
}

harmonization_print_report() {
    local report=$1 status
    [ -r "$report" ] || return 0
    jq -r '
        (.units // []) as $plan
        | if has("applied") then
            "Applied: " + ((.applied | join(", ")) // "") ,
            (if (.skipped | length) > 0 then "Preserved or skipped: " + ([.skipped[] | "\(.id) (\(.status))"] | join(", ")) else empty end),
            (if (.pending | length) > 0 then "Pending: " + (.pending | join("; ")) else empty end)
          else
            "Preview for \(.variant):",
            ($plan[] | select(.status != "not-selected") | "  \(.id): \(.status)\(if .reason != "" then " - " + .reason else "" end)")
          end
    ' "$report" 2>/dev/null | while IFS= read -r status; do
        print_message "$status"
    done
}

configure_harmonization() {
    announce_step "Configuring desktop harmonization"
    local mode variant scripts adopt=false root
    mode=$(harmonization_adoption_mode) || { record_hard_failure "configure_harmonization" "Invalid HSS_HARMONIZATION_ADOPT"; return 1; }
    variant=$(harmonization_variant) || { record_hard_failure "configure_harmonization" "Invalid HSS_THEME_VARIANT"; return 1; }
    scripts=$(harmonization_scripts_dir)
    root="$HOME/dotfiles/.config/hypr"

    if [ "$mode" = skip ]; then
        print_message "Desktop harmonization skipped (HSS_HARMONIZATION_ADOPT=skip)."
        track_config_status "Desktop Harmonization" "$CIRCLE (Skipped)"
        record_skipped "configure_harmonization" "Skipped by HSS_HARMONIZATION_ADOPT=skip"
        return 0
    fi
    case "$mode" in fresh|adopted|apply) adopt=true ;; esac

    if [ ! -r "$scripts/providers/theme.sh" ]; then
        print_warning "Theme provider is unavailable; desktop harmonization was not applied."
        record_warning "configure_harmonization" "providers/theme.sh is missing"
        track_config_status "Desktop Harmonization" "$CROSS_MARK"
        return 0
    fi

    local file
    for file in "$root/sources/keybindings.lua" "$root/sources_example/keybindings.lua"; do
        harmonization_theme_binding "$file" "$adopt" || return 1
    done
    if [ "$adopt" = true ]; then
        for file in "$root/sources/environment_variables.lua" "$root/sources_example/environment_variables.lua"; do
            harmonization_cursor_environment "$file" || return 1
        done
    fi

    local outcome="" reason="" report="" status=0
    # The provider sets HSS_* globals; run it in this shell so writes join the setup run.
    HSS_SCRIPTS_DIR=$scripts
    # shellcheck source=dotfiles/.config/hypr/scripts/lib/hss_runtime.sh
    source "$scripts/lib/hss_runtime.sh"
    # shellcheck source=dotfiles/.config/hypr/scripts/providers/theme.sh
    source "$scripts/providers/theme.sh"
    HSS_ACTION_NOTIFY=0
    if [ "$mode" = preview ]; then
        hss_theme_apply "$variant" --preview || status=$?
    elif [ "$adopt" = true ]; then
        if declare -F panels_upgrade_stock_waybar_style >/dev/null; then
            panels_upgrade_stock_waybar_style || return 1
        fi
        # Automatic adoption (fresh install, earlier consent) only takes over files that setup
        # installed under ~/dotfiles, missing files and files the theme already manages; other
        # user files are left for an explicit HSS_HARMONIZATION_ADOPT=apply.
        local adopt_scope=""
        [ "$mode" = apply ] || adopt_scope="$HOME/dotfiles"
        HSS_THEME_ADOPT_SCOPE=$adopt_scope hss_theme_apply "$variant" --adopt || status=$?
    fi
    outcome=$HSS_OUTCOME
    reason=$HSS_REASON
    report=${HSS_THEME_REPORT:-}

    harmonization_print_report "$report"
    case "$mode:$outcome" in
        preview:completed)
            print_message "Existing configuration was not changed. Rerun with HSS_HARMONIZATION_ADOPT=apply (installer: Existing configuration -> Apply) to adopt the $variant theme."
            [ -z "$report" ] || print_message "Preview report: $report"
            track_config_status "Desktop Harmonization" "$CIRCLE (Preview only)"
            ;;
        *:completed)
            print_message "$reason"
            if [[ $reason == *"partially applied"* ]]; then
                record_warning "configure_harmonization" "$reason"
                track_config_status "Desktop Harmonization" "$CIRCLE (Partially applied)"
            else
                track_config_status "Desktop Harmonization" "$CHECK_MARK"
            fi
            ;;
        *)
            print_warning "Desktop harmonization did not complete: $reason"
            record_soft_error "configure_harmonization" "${reason:-theme step failed with status $status}"
            track_config_status "Desktop Harmonization" "$CROSS_MARK"
            ;;
    esac
    return 0
}
