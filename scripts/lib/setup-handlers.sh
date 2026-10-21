#!/usr/bin/env bash

# Default-handler intents for setup.sh (plan D06.2, product policy P06). Source-only:
# this file defines functions and has no top-level side effects.
#
# Primary selections drive URL, folder and text-file handlers:
#   browser      -> x-scheme-handler/http, x-scheme-handler/https, text/html
#   file_manager -> inode/directory
#   gui_editor   -> text/plain, application/x-shellscript
# With GUI editor None the managed entry hss-tui-editor.desktop is used instead; it opens
# the primary TUI editor in the selected terminal through role_exec.sh and term_exec.sh.
#
# The FileChooser portal backend is not a folder handler and is never changed here.
# Desktop entries are only checked for existence; their Exec lines are never parsed,
# evaluated or run. Associations are applied with the native `xdg-mime` CLI and read
# back with `xdg-mime query default`. The previous user entries (including absence) are
# recorded in the setup run as handlers.tsv so that hss_handlers_restore puts back only
# the keys this run changed, and only while they still hold the value written here.
#
# Per-target statuses: applied, unchanged, disabled, would-apply (preview/dry run),
# missing-desktop-entry, missing-dependency (xdg-mime), unsupported (no verified desktop
# ID), failed (xdg-mime default failed) and mismatch (the effective handler differs after
# a successful write, for example because a desktop-specific mimeapps.list overrides it).
# Restore statuses: restored, unchanged, conflict, failed.

# Exit codes follow Documents/runtime-managed-configuration.md: 0 completed, 1 failed,
# 2 usage, 5 unsupported, 6 missing-dependency, 10 conflict. After each call
# HSS_HANDLERS_SUMMARY holds a one-line count summary and HSS_HANDLERS_REPORT the path of
# the run-local TSV report, for the caller's status output.
# shellcheck disable=SC2034 # HSS_HANDLERS_REPORT and HSS_HANDLERS_SUMMARY are caller outputs.

# Managed desktop entry used for text files when the GUI editor role is None.
hss_handlers_tui_editor_entry() {
    printf 'hss-tui-editor.desktop\n'
}

hss_handlers_roles_file() {
    printf '%s\n' "${HSS_ROLES_FILE:-$HOME/.config/hypr/roles.json}"
}

hss_handlers_user_file() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
}

hss_handlers_say() {
    local level=$1 message=$2
    case "$level" in
        warning)
            if declare -F print_warning >/dev/null; then print_warning "$message"; else printf 'Warning: %s\n' "$message" >&2; fi
            ;;
        *)
            if declare -F print_message >/dev/null; then print_message "$message"; else printf '%s\n' "$message" >&2; fi
            ;;
    esac
}

hss_handlers_dry_run() {
    declare -F is_dry_run >/dev/null && is_dry_run
}

hss_handlers_bounded() {
    local seconds=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=2 "$seconds" "$@"
    else
        "$@"
    fi
}

# Role, MIME type pairs in a fixed order.
hss_handlers_targets() {
    printf '%s\t%s\n' \
        browser x-scheme-handler/http \
        browser x-scheme-handler/https \
        browser text/html \
        file_manager inode/directory \
        gui_editor text/plain \
        gui_editor application/x-shellscript
}

hss_handlers_valid_desktop_id() {
    [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.desktop$ ]]
}

hss_handlers_valid_mime() {
    [[ ${1:-} =~ ^[a-z0-9][a-z0-9.+-]*/[A-Za-z0-9][A-Za-z0-9.+_-]*$ ]]
}

# Desktop IDs verified from the packaged desktop files (capability ledger evidence
# E-D06-001 to E-D06-004). A valid catalog `desktop_file` is tried first; the verified
# packaged ID is the second candidate for the same application (for example the
# visual-studio-code-bin package installs code.desktop, not the catalog's
# visual-studio-code.desktop). Cursor's ID is unverified upstream packaging evidence.
hss_handlers_known_desktop_id() {
    case "$1/$2" in
        browser/firefox) printf 'firefox.desktop\n' ;;
        browser/chromium) printf 'chromium.desktop\n' ;;
        browser/vivaldi) printf 'vivaldi-stable.desktop\n' ;;
        browser/zen-browser-bin) printf 'zen.desktop\n' ;;
        browser/brave-bin) printf 'brave-browser.desktop\n' ;;
        file_manager/dolphin) printf 'org.kde.dolphin.desktop\n' ;;
        file_manager/thunar) printf 'thunar.desktop\n' ;;
        file_manager/nautilus) printf 'org.gnome.Nautilus.desktop\n' ;;
        file_manager/nemo) printf 'nemo.desktop\n' ;;
        file_manager/pcmanfm-qt) printf 'pcmanfm-qt.desktop\n' ;;
        gui_editor/zed) printf 'dev.zed.Zed.desktop\n' ;;
        gui_editor/visual-studio-code-bin) printf 'code.desktop\n' ;;
        gui_editor/cursor-bin) printf 'cursor.desktop\n' ;;
        gui_editor/kate) printf 'org.kde.kate.desktop\n' ;;
        gui_editor/mousepad) printf 'org.xfce.mousepad.desktop\n' ;;
        *) return 1 ;;
    esac
}

# Print "PACKAGE<TAB>DESKTOP_ID" for the primary member of ROLE.
# Returns 4 when the role is None (and no managed fallback exists), 5 when no verified
# desktop ID is known, 2 for invalid metadata and 1 when role data is unavailable.
hss_handlers_role_desktop() {
    local role=$1 file package desktop
    file=$(hss_handlers_roles_file)
    [[ -r $file ]] || return 1
    package=$(jq -r --arg role "$role" '.roles[$role].package // empty' "$file" 2>/dev/null) || return 1
    if [[ -z $package ]]; then
        if [[ $role == gui_editor ]]; then
            # P06: GUI editor None uses the managed entry that opens the primary TUI editor.
            package=$(jq -r '.roles.tui_editor.package // empty' "$file" 2>/dev/null) || return 1
            [[ -n $package ]] || return 4
            printf 'none(tui_editor:%s)\t%s\n' "$package" "$(hss_handlers_tui_editor_entry)"
            return 0
        fi
        return 4
    fi
    [[ $package =~ ^[a-z0-9@._+-]+$ ]] || return 2
    local catalog known candidate
    local -a candidates=()
    catalog=$(jq -r --arg role "$role" '.roles[$role].desktop_file // empty' "$file" 2>/dev/null) || return 1
    if [[ -n $catalog ]]; then
        hss_handlers_valid_desktop_id "$catalog" || return 2
        candidates+=("$catalog")
    fi
    if known=$(hss_handlers_known_desktop_id "$role" "$package") && [[ $known != "$catalog" ]]; then
        candidates+=("$known")
    fi
    ((${#candidates[@]} > 0)) || return 5
    # Prefer an installed candidate; otherwise report the first one as missing.
    desktop=${candidates[0]}
    for candidate in "${candidates[@]}"; do
        if hss_handlers_desktop_path "$candidate" >/dev/null; then
            desktop=$candidate
            break
        fi
    done
    printf '%s\t%s\n' "$package" "$desktop"
}

# Print the path of an installed desktop entry, searching $XDG_DATA_HOME, $XDG_DATA_DIRS
# and the Flatpak export directories.
hss_handlers_desktop_path() {
    local id=$1 dir
    local -a dirs=()
    hss_handlers_valid_desktop_id "$id" || return 1
    IFS=: read -r -a dirs <<< "${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share"
    for dir in "${dirs[@]}"; do
        [[ $dir == /* ]] || continue
        if [[ -f $dir/applications/$id ]]; then
            printf '%s\n' "$dir/applications/$id"
            return 0
        fi
    done
    return 1
}

hss_handlers_clean_field() {
    local value=$1
    value=${value%%$'\n'*}
    value=${value//$'\t'/ }
    value=${value//$'\r'/}
    [[ -n $value ]] || value=-
    printf '%s' "$value"
}

# Effective default for MIME as reported by xdg-mime, or "-" when none.
hss_handlers_effective() {
    local mime=$1 output=""
    output=$(hss_handlers_bounded 10 xdg-mime query default "$mime" 2>/dev/null) || output=""
    hss_handlers_clean_field "$output"
    printf '\n'
}

# Raw user entry for KEY in SECTION of FILE: "=VALUE" when present, "-" when absent.
hss_handlers_user_raw() {
    local file=$1 section=$2 key=$3
    if [[ ! -f $file ]]; then
        printf -- '-\n'
        return 0
    fi
    awk -v section="[$section]" -v key="$key" '
        /^[[:space:]]*\[/ { current = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", current); next }
        current == section {
            eq = index($0, "=")
            if (eq > 0) {
                name = substr($0, 1, eq - 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
                if (name == key) { value = substr($0, eq + 1); found = 1 }
            }
        }
        END { if (found) print "=" value; else print "-" }
    ' "$file" | tr -d '\t\r'
}

# Write FILE's content with KEY in SECTION set to RAW ("=VALUE") or removed ("-") to stdout.
# Every other line is preserved byte for byte.
hss_handlers_edit_key() {
    local file=$1 section=$2 key=$3 raw=$4
    local mode="remove" value=""
    if [[ $raw == =* ]]; then
        mode="set"
        value=${raw#=}
    fi
    if [[ -f $file ]]; then cat -- "$file"; fi | awk -v section="[$section]" -v key="$key" -v mode="$mode" -v value="$value" '
        function flush_section() {
            if (in_section && mode == "set" && !written) { print key "=" value; written = 1 }
        }
        /^[[:space:]]*\[/ {
            flush_section()
            current = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)
            in_section = (current == section)
            if (in_section) seen = 1
            print
            next
        }
        in_section {
            eq = index($0, "=")
            if (eq > 0) {
                name = substr($0, 1, eq - 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
                if (name == key) {
                    if (mode == "set" && !written) { print key "=" value; written = 1 }
                    next
                }
            }
        }
        { print }
        END {
            flush_section()
            if (!seen && mode == "set") { print ""; print section; print key "=" value }
        }
    '
}

# Resolve every target into "ROLE<TAB>MIME<TAB>PACKAGE<TAB>DESKTOP<TAB>STATE" where STATE
# is ok, disabled, unsupported, invalid or unavailable.
hss_handlers_resolve() {
    local role mime resolved package desktop status
    local -A cache_status=() cache_value=()
    while IFS=$'\t' read -r role mime; do
        if [[ -z ${cache_status[$role]+x} ]]; then
            status=0
            resolved=$(hss_handlers_role_desktop "$role") || status=$?
            cache_status[$role]=$status
            cache_value[$role]=$resolved
        fi
        status=${cache_status[$role]}
        resolved=${cache_value[$role]}
        case "$status" in
            0)
                IFS=$'\t' read -r package desktop <<< "$resolved"
                printf '%s\t%s\t%s\t%s\tok\n' "$role" "$mime" "$package" "$desktop"
                ;;
            4) printf '%s\t%s\t-\t-\tdisabled\n' "$role" "$mime" ;;
            5) printf '%s\t%s\t%s\t-\tunsupported\n' "$role" "$mime" "$(jq -r --arg role "$role" '.roles[$role].package // "-"' "$(hss_handlers_roles_file)" 2>/dev/null)" ;;
            2) printf '%s\t%s\t-\t-\tinvalid\n' "$role" "$mime" ;;
            *) printf '%s\t%s\t-\t-\tunavailable\n' "$role" "$mime" ;;
        esac
    done < <(hss_handlers_targets)
}

# Severity order for the combined exit status.
hss_handlers_exit_for() {
    local statuses=" $* "
    # unavailable: role data could not be read, so no handler was checked or changed.
    if [[ $statuses == *" failed "* || $statuses == *" unavailable "* ]]; then return 1; fi
    if [[ $statuses == *" mismatch "* || $statuses == *" conflict "* ]]; then return 10; fi
    if [[ $statuses == *" missing-desktop-entry "* || $statuses == *" missing-dependency "* ]]; then return 6; fi
    if [[ $statuses == *" unsupported "* || $statuses == *" invalid "* ]]; then return 5; fi
    return 0
}

hss_handlers_summarize() {
    local -n hss_handlers_counts=$1
    local key summary=""
    for key in applied restored would-apply unchanged disabled missing-desktop-entry missing-dependency unsupported invalid unavailable failed mismatch conflict; do
        [[ -n ${hss_handlers_counts[$key]:-} ]] || continue
        summary+="${summary:+, }$key=${hss_handlers_counts[$key]}"
    done
    printf '%s\n' "${summary:-nothing to do}"
}

# Preview the handler changes for the current selection. Writes handlers-preview.tsv in
# the active setup run when one exists and prints one line per target.
hss_handlers_preview() {
    local role mime package desktop state current action report="" have_xdg_mime=false
    local -A counts=()
    local -a statuses=()
    command -v xdg-mime >/dev/null 2>&1 && have_xdg_mime=true
    if [[ -n ${HSS_RUN_DIR:-} && -d $HSS_RUN_DIR ]]; then
        report="$HSS_RUN_DIR/handlers-preview.tsv"
        printf 'mime\trole\tpackage\tdesired\tcurrent\taction\n' > "$report"
    fi
    while IFS=$'\t' read -r role mime package desktop state; do
        current=-
        case "$state" in
            ok)
                if ! hss_handlers_desktop_path "$desktop" >/dev/null; then
                    action=missing-desktop-entry
                elif ! $have_xdg_mime; then
                    action=missing-dependency
                else
                    current=$(hss_handlers_effective "$mime")
                    if [[ $current == "$desktop" ]]; then action=unchanged; else action=would-apply; fi
                fi
                ;;
            *) action=$state ;;
        esac
        counts[$action]=$(( ${counts[$action]:-0} + 1 ))
        statuses+=("$action")
        printf '%s: %s -> %s (%s)\n' "$mime" "$current" "$desktop" "$action"
        [[ -z $report ]] || printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$mime" "$role" "$package" "$desktop" "$current" "$action" >> "$report"
    done < <(hss_handlers_resolve)
    HSS_HANDLERS_REPORT=$report
    HSS_HANDLERS_SUMMARY=$(hss_handlers_summarize counts)
    hss_handlers_exit_for "${statuses[@]}"
}

# Apply the handler changes for the current selection with xdg-mime, verify the effective
# handler and record the previous user entries in $HSS_RUN_DIR/handlers.tsv.
hss_handlers_apply() {
    local role mime package desktop state status before_effective after_effective
    local before_default before_added after_default after_added user_file record have_xdg_mime=false
    local section_default="Default Applications" section_added="Added Associations"
    local -A counts=()
    local -a statuses=()
    if [[ -z ${HSS_RUN_DIR:-} || ! -d $HSS_RUN_DIR ]]; then
        HSS_HANDLERS_SUMMARY="handler changes need an active setup run record"
        hss_handlers_say warning "$HSS_HANDLERS_SUMMARY"
        return 1
    fi
    user_file=$(hss_handlers_user_file)
    record="$HSS_RUN_DIR/handlers.tsv"
    [[ -f $record ]] || printf 'mime\trole\tpackage\tdesired\tstatus\tbefore_effective\tbefore_default\tbefore_added\tafter_default\tafter_added\tafter_effective\n' > "$record"
    command -v xdg-mime >/dev/null 2>&1 && have_xdg_mime=true
    while IFS=$'\t' read -r role mime package desktop state; do
        before_effective=- before_default=- before_added=- after_default=- after_added=- after_effective=-
        if [[ $state != ok ]]; then
            status=$state
        elif ! hss_handlers_desktop_path "$desktop" >/dev/null; then
            status=missing-desktop-entry
        elif ! $have_xdg_mime; then
            status=missing-dependency
        else
            before_effective=$(hss_handlers_effective "$mime")
            before_default=$(hss_handlers_user_raw "$user_file" "$section_default" "$mime")
            before_added=$(hss_handlers_user_raw "$user_file" "$section_added" "$mime")
            if [[ $before_effective == "$desktop" ]]; then
                status=unchanged
            elif hss_handlers_dry_run; then
                status=would-apply
                declare -F log_dry_run_operation >/dev/null \
                    && log_dry_run_operation hss_handlers_apply "would associate $mime with $desktop"
            elif ! hss_handlers_bounded 20 xdg-mime default "$desktop" "$mime" </dev/null >/dev/null 2>&1; then
                status=failed
            else
                after_default=$(hss_handlers_user_raw "$user_file" "$section_default" "$mime")
                after_added=$(hss_handlers_user_raw "$user_file" "$section_added" "$mime")
                after_effective=$(hss_handlers_effective "$mime")
                if [[ $after_effective == "$desktop" ]]; then status=applied; else status=mismatch; fi
            fi
        fi
        counts[$status]=$(( ${counts[$status]:-0} + 1 ))
        statuses+=("$status")
        case "$status" in
            applied|unchanged|disabled|would-apply) ;;
            missing-desktop-entry) hss_handlers_say warning "Default handler for $mime not changed: $desktop is not installed" ;;
            missing-dependency) hss_handlers_say warning "Default handler for $mime not changed: xdg-mime is unavailable" ;;
            unsupported) hss_handlers_say warning "Default handler for $mime not changed: no verified desktop entry for $package" ;;
            failed) hss_handlers_say warning "Default handler for $mime not changed: xdg-mime default $desktop failed" ;;
            mismatch) hss_handlers_say warning "Default handler for $mime is still $after_effective after selecting $desktop; another association file takes precedence" ;;
            *) hss_handlers_say warning "Default handler for $mime not changed: role $role is $status" ;;
        esac
        if ! hss_handlers_dry_run; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mime" "$role" "$package" "$desktop" "$status" \
                "$before_effective" "$before_default" "$before_added" "$after_default" "$after_added" "$after_effective" >> "$record"
        fi
    done < <(hss_handlers_resolve)
    HSS_HANDLERS_REPORT=$record
    HSS_HANDLERS_SUMMARY=$(hss_handlers_summarize counts)
    hss_handlers_exit_for "${statuses[@]}"
}

# Entry point for setup.sh:configure_filepicker. HSS_HANDLERS_MODE=apply (default),
# preview or skip. Dry runs only preview. Approving a primary selection approves its
# handler changes (P06); the preview is still recorded in the run directory.
hss_handlers_configure() {
    local mode=${HSS_HANDLERS_MODE:-apply} status=0
    hss_handlers_dry_run && mode=preview
    case "$mode" in
        skip)
            HSS_HANDLERS_SUMMARY="handler changes skipped"
            return 0
            ;;
        preview)
            hss_handlers_preview || status=$?
            return "$status"
            ;;
        apply)
            hss_handlers_preview >/dev/null || true
            hss_handlers_apply || status=$?
            return "$status"
            ;;
        *)
            HSS_HANDLERS_SUMMARY="invalid HSS_HANDLERS_MODE '$mode'"
            return 2
            ;;
    esac
}

# Restore the user association entries changed by setup run RUN_ID. Each key is restored
# only while it still holds the value that run wrote; later user changes are reported as
# conflicts and kept. Requires an active reliability run (write_file_atomic).
hss_handlers_restore() {
    local run_id=${1:-} record user_file tmp line_number=0
    local mime role package desktop status before_effective before_default before_added after_default after_added after_effective
    local current_default current_added outcome
    local section_default="Default Applications" section_added="Added Associations"
    local -A counts=()
    local -a statuses=()
    hss_valid_run_id "$run_id" || { HSS_HANDLERS_SUMMARY="invalid run ID"; return 2; }
    record="$(hss_state_root)/runs/$run_id/handlers.tsv"
    if [[ ! -e $record ]]; then
        HSS_HANDLERS_SUMMARY="no handler changes recorded"
        return 0
    fi
    [[ -f $record && ! -L $record ]] || { HSS_HANDLERS_SUMMARY="handler record is not a regular file"; return 1; }
    user_file=$(hss_handlers_user_file)
    while IFS=$'\t' read -r mime role package desktop status before_effective before_default before_added after_default after_added after_effective; do
        line_number=$((line_number + 1))
        ((line_number > 1)) || continue
        case "$status" in applied|mismatch) ;; *) continue ;; esac
        if ! hss_handlers_valid_mime "$mime" \
            || ! [[ $before_default == - || $before_default == =* ]] || ! [[ $before_added == - || $before_added == =* ]] \
            || ! [[ $after_default == - || $after_default == =* ]] || ! [[ $after_added == - || $after_added == =* ]]; then
            HSS_HANDLERS_SUMMARY="handler record line $line_number is malformed; nothing restored from it"
            hss_handlers_say warning "$HSS_HANDLERS_SUMMARY"
            outcome=failed
            counts[$outcome]=$(( ${counts[$outcome]:-0} + 1 ))
            statuses+=("$outcome")
            continue
        fi
        current_default=$(hss_handlers_user_raw "$user_file" "$section_default" "$mime")
        current_added=$(hss_handlers_user_raw "$user_file" "$section_added" "$mime")
        if [[ $current_default == "$before_default" && $current_added == "$before_added" ]]; then
            outcome=unchanged
        elif [[ $current_default != "$after_default" || $current_added != "$after_added" ]]; then
            outcome=conflict
            hss_handlers_say warning "Default handler for $mime changed after run $run_id; keeping the current association"
        elif hss_handlers_dry_run; then
            outcome=would-apply
            declare -F log_dry_run_operation >/dev/null \
                && log_dry_run_operation hss_handlers_restore "would restore $mime in $user_file"
        else
            outcome=failed
            if make_tmp tmp handlers.XXXXXX \
                && hss_handlers_edit_key "$user_file" "$section_default" "$mime" "$before_default" > "$tmp.default" \
                && hss_handlers_edit_key "$tmp.default" "$section_added" "$mime" "$before_added" > "$tmp" \
                && rm -f -- "$tmp.default" \
                && write_file_atomic "$user_file" "$tmp" "restore default handler for $mime from run $run_id"; then
                if [[ $(hss_handlers_user_raw "$user_file" "$section_default" "$mime") == "$before_default" \
                    && $(hss_handlers_user_raw "$user_file" "$section_added" "$mime") == "$before_added" ]]; then
                    outcome=restored
                fi
            fi
            [[ -z ${tmp:-} ]] || rm -f -- "$tmp.default"
        fi
        counts[$outcome]=$(( ${counts[$outcome]:-0} + 1 ))
        statuses+=("$outcome")
    done < "$record"
    HSS_HANDLERS_SUMMARY=$(hss_handlers_summarize counts)
    hss_handlers_exit_for "${statuses[@]}"
}
