#!/usr/bin/env bash

# Source-only theme provider (plan F03). Renders with theme/hss_theme.py, commits through
# lib/hss_reliability.sh so every change is a recoverable run (setup.sh --rollback RUN_ID),
# and activates only declared safe reloads. Contract: Documents/runtime-managed-configuration.md.
# HSS_* result globals are read by action_exec.sh; fallback hooks are called by hss_reliability.sh.
# shellcheck disable=SC2034,SC2329

hss_theme_dir() {
    printf '%s\n' "${HSS_THEME_DIR:-$(cd -- "$HSS_SCRIPTS_DIR/../theme" && pwd)}"
}

hss_theme_root() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/hss-theme"
}

hss_theme_current_variant() {
    local state
    state="$(hss_theme_root)/state.json"
    [[ -r $state ]] || return 0
    jq -r '.variant // empty' "$state" 2>/dev/null || true
}

hss_theme_default_variant() {
    jq -r '.default_variant // "dark"' "$(hss_theme_dir)/tokens.json" 2>/dev/null || printf 'dark\n'
}

# Provide the setup.sh hooks the reliability library expects when running outside setup.
hss_theme_reliability_init() {
    declare -F is_dry_run >/dev/null || is_dry_run() { [[ ${DRY_RUN:-false} == true ]]; }
    declare -F log_dry_run_operation >/dev/null || log_dry_run_operation() { printf '[dry-run] %s: %s\n' "$1" "$2" >&2; }
    declare -F print_dry_run_summary >/dev/null || print_dry_run_summary() { :; }
    declare -F write_file_atomic >/dev/null && return 0
    # shellcheck source=dotfiles/.config/hypr/scripts/lib/hss_reliability.sh
    source "$HSS_SCRIPTS_DIR/lib/hss_reliability.sh"
}

hss_theme_python() {
    if hss_have python3; then
        printf 'python3\n'
    elif hss_have python; then
        printf 'python\n'
    else
        return 1
    fi
}

# Run one activation step declared by a unit. Prints a pending note for deferred work.
hss_theme_activate_step() {
    local unit=$1 step=$2 kind process signal schema key value current
    local -a argv=()
    kind=$(jq -r '.kind' <<<"$step")
    case "$kind" in
        signal)
            process=$(jq -r '.process' <<<"$step")
            signal=$(jq -r '.signal' <<<"$step")
            if hss_process_running "$process"; then
                pkill -u "$(id -u)" -x -"$signal" -- "$process" >/dev/null 2>&1 \
                    || printf '%s: could not signal %s\n' "$unit" "$process"
            fi
            ;;
        reload)
            mapfile -t argv < <(jq -r '.argv[]' <<<"$step")
            process=$(jq -r '.process // empty' <<<"$step")
            if [[ -n $process ]] && ! hss_process_running "$process"; then
                return 0
            fi
            hss_have "${argv[0]}" || { printf '%s: %s is not installed\n' "$unit" "${argv[0]}"; return 0; }
            hss_run_bounded 5 "${argv[@]}" </dev/null >/dev/null 2>&1 \
                || printf '%s: reload command %s failed; restart it to apply the theme\n' "$unit" "${argv[0]}"
            ;;
        gsettings)
            schema=$(jq -r '.schema' <<<"$step")
            key=$(jq -r '.key' <<<"$step")
            value=$(jq -r '.value' <<<"$step")
            # gsettings writable prints true or false and exits 0 for any known key.
            if ! hss_have gsettings || [[ $(hss_run_bounded 3 gsettings writable "$schema" "$key" 2>/dev/null) != true ]]; then
                # Notes are joined with "; ", so a note must not contain that separator.
                printf '%s: %s %s is unavailable, so it applies after login\n' "$unit" "$schema" "$key"
                return 0
            fi
            current=$(hss_run_bounded 3 gsettings get "$schema" "$key" 2>/dev/null || true)
            [[ ${current//\'/} == "$value" ]] && return 0
            [[ -z ${HSS_THEME_GSETTINGS_LOG:-} ]] || printf '%s\t%s\t%s\n' "$schema" "$key" "$current" >> "$HSS_THEME_GSETTINGS_LOG"
            hss_run_bounded 3 gsettings set "$schema" "$key" "$value" >/dev/null 2>&1 \
                || printf '%s: could not set %s %s\n' "$unit" "$schema" "$key"
            ;;
        next-launch) printf '%s: applies the next time the application starts\n' "$unit" ;;
        relogin) printf '%s: applies after the next login\n' "$unit" ;;
        *) printf '%s: unknown activation %s\n' "$unit" "$kind" ;;
    esac
}

# hss_theme_apply VARIANT [--adopt] [--preview] [--units LIST]
# Sets HSS_THEME_REPORT to the report path and returns an outcome status.
hss_theme_apply() {
    local variant=$1
    shift
    local adopt=false preview=false units="" python theme_dir theme_root staging plan roles
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --adopt) adopt=true ;;
            --preview) preview=true ;;
            --units) units=$2; shift ;;
            *) hss_set_outcome usage "unknown theme option $1"; return ;;
        esac
        shift
    done
    [[ $variant == dark || $variant == light ]] || { hss_set_outcome usage "variant must be dark or light"; return; }
    HSS_PROVIDER=hss-theme
    python=$(hss_theme_python) || { hss_set_outcome missing-dependency "python3 is required to render the theme"; return; }
    theme_dir=$(hss_theme_dir)
    theme_root=$(hss_theme_root)
    [[ -r $theme_dir/hss_theme.py ]] || { hss_set_outcome missing-dependency "theme renderer is not installed; rerun setup"; return; }

    # Runtime switching changes only configuration that setup already adopted with consent.
    if [[ ${HSS_RUN_ACTIVE:-false} != true ]] && ! $adopt && ! $preview && [[ ! -s $theme_root/managed.json ]]; then
        hss_set_outcome unavailable "the desktop theme has not been adopted yet; rerun setup and choose to apply the harmonized configuration"
        return
    fi

    hss_theme_reliability_init
    if [[ ${HSS_RUN_ACTIVE:-false} != true ]]; then
        if ! hss_begin_run "theme.set $variant" 2>/dev/null; then
            hss_set_outcome conflict "another setup or theme change is running"
            return
        fi
    fi

    staging=$(mktemp -d "${HSS_RUN_TMP_DIR:-${TMPDIR:-/tmp}}/theme.XXXXXX") || { hss_set_outcome failed "cannot create staging directory"; return; }
    plan="$staging/plan.json"
    roles=$(hss_roles_file)
    local -a plan_args=(
        "$theme_dir/hss_theme.py" plan --variant "$variant"
        --home "$HOME" --config-home "${XDG_CONFIG_HOME:-$HOME/.config}"
        --data-home "${XDG_DATA_HOME:-$HOME/.local/share}" --theme-root "$theme_root"
        --staging "$staging/candidates" --out "$plan"
    )
    [[ -r $roles ]] && plan_args+=(--roles "$roles")
    $adopt && plan_args+=(--adopt)
    # HSS_THEME_ADOPT_SCOPE (colon-separated directories) limits adoption of existing user files;
    # setup sets it for automatic adoption. The theme's own directory is always in scope.
    if $adopt && [[ -n ${HSS_THEME_ADOPT_SCOPE:-} ]]; then
        local scope
        local -a scopes=()
        IFS=: read -r -a scopes <<<"$HSS_THEME_ADOPT_SCOPE"
        for scope in "${scopes[@]}" "$theme_root"; do
            [[ -n $scope ]] && plan_args+=(--adopt-scope "$scope")
        done
    fi
    [[ -z $units ]] || plan_args+=(--units "$units")
    if ! "$python" "${plan_args[@]}" 2>"$staging/render.err"; then
        HSS_REASON=$(head -c 400 "$staging/render.err")
        rm -rf -- "$staging"
        hss_set_outcome failed "theme rendering failed: $HSS_REASON"
        return
    fi

    HSS_THEME_REPORT="${HSS_RUN_DIR:-${TMPDIR:-/tmp}}/theme-report.json"
    if $preview; then
        # The report lists units, targets and reasons only; staged copies of user files are removed.
        jq '{variant, adopt, summary, units: [.units[] | {id, owner, status, reason,
             outputs: [.outputs[] | {target, class, action}], missing_assets}]}' "$plan" > "$HSS_THEME_REPORT" 2>/dev/null \
            || HSS_THEME_REPORT=""
        HSS_OBSERVED=$(jq -c '{variant, summary, units: [.units[] | {id, status, reason}]}' "$plan")
        rm -rf -- "$staging"
        hss_set_outcome completed "theme preview written"
        return
    fi

    local unit unit_status target staged canonical superseded failed_units="" applied="" unchanged="" blocked_units="" pending=""
    local -A unit_failed=()
    : > "$staging/written"
    while IFS= read -r unit; do
        unit_status=$(jq -r --arg id "$unit" '.units[] | select(.id == $id) | .status' "$plan")
        local blocked=false dependency
        while IFS= read -r dependency; do
            [[ -n $dependency && -n ${unit_failed[$dependency]+x} ]] && blocked=true
        done < <(jq -r --arg id "$unit" '.units[] | select(.id == $id) | .depends[]?' "$plan")
        if $blocked; then
            unit_failed[$unit]=1
            [[ $unit_status == ready || $unit_status == unchanged ]] && blocked_units+="${blocked_units:+,}$unit"
            continue
        fi
        case "$unit_status" in
            unchanged) unchanged+="${unchanged:+,}$unit"; continue ;;
            ready) ;;
            not-selected) continue ;;
            failed) unit_failed[$unit]=1; failed_units+="${failed_units:+,}$unit"; continue ;;
            *) unit_failed[$unit]=1; continue ;;
        esac
        local ok=true
        while IFS=$'\t' read -r target staged canonical superseded; do
            [[ -n $staged && $staged != null && $superseded != true ]] || continue
            if ! is_dry_run; then
                mkdir -p -- "$(dirname -- "$target")" || { ok=false; break; }
            fi
            write_file_atomic "$target" "$staged" "theme $variant: $unit" || { ok=false; break; }
            printf '%s\n' "$canonical" >> "$staging/written"
        done < <(jq -r --arg id "$unit" '.units[] | select(.id == $id) | .outputs[] | select(.action != "unchanged")
                 | [.target, .staged, .canonical, (.superseded // false | tostring)] | @tsv' "$plan")
        if $ok; then
            applied+="${applied:+,}$unit"
        else
            unit_failed[$unit]=1
            failed_units+="${failed_units:+,}$unit"
        fi
    done < <(jq -r '.units[].id' "$plan")

    if ! is_dry_run; then
        mkdir -p -- "$theme_root"
        if "$python" "$theme_dir/hss_theme.py" finalize --plan "$plan" --theme-root "$theme_root" \
            --applied "$applied" --unchanged "$unchanged" --failed "$failed_units" --blocked "$blocked_units" \
            --written-file "$staging/written" \
            --out-managed "$staging/managed.json" --out-state "$staging/state.json"; then
            write_file_atomic "$theme_root/managed.json" "$staging/managed.json" "theme $variant: managed state" || failed_units+="${failed_units:+,}managed-state"
            write_file_atomic "$theme_root/state.json" "$staging/state.json" "theme $variant: state" || failed_units+="${failed_units:+,}managed-state"
        else
            failed_units+="${failed_units:+,}managed-state"
        fi
    fi

    local step note
    HSS_THEME_GSETTINGS_LOG="$staging/gsettings-previous.tsv"
    : > "$HSS_THEME_GSETTINGS_LOG"
    if ! is_dry_run; then
        while IFS=$'\t' read -r unit step; do
            [[ -n $unit ]] || continue
            case ",$applied,$unchanged," in *",$unit,"*) ;; *) continue ;; esac
            # File-free reloads matter only after a change; gsettings is reapplied idempotently.
            if [[ ,$unchanged, == *",$unit,"* && $(jq -r '.kind' <<<"$step") != gsettings ]]; then
                continue
            fi
            note=$(hss_theme_activate_step "$unit" "$step")
            [[ -z $note ]] || pending+="${pending:+; }$note"
        done < <(jq -r '.units[] | .id as $id | .activation[] | [$id, (. | tojson)] | @tsv' "$plan")
    fi

    local package
    while IFS=$'\t' read -r unit package; do
        [[ -n $unit ]] || continue
        pending+="${pending:+; }$unit: theme asset missing, install $package"
    done < <(jq -r '.units[] | select(.status | IN("ready", "unchanged")) | .id as $id | .missing_assets[]? | [$id, .package] | @tsv' "$plan")

    jq --arg applied "$applied" --arg unchanged "$unchanged" --arg failed "$failed_units" \
        --arg blocked "$blocked_units" --arg pending "$pending" \
        --rawfile gsettings "$HSS_THEME_GSETTINGS_LOG" \
        '($blocked | split(",") | map(select(. != ""))) as $blocked_list
         | {variant, adopt, summary,
          applied: ($applied | split(",") | map(select(. != ""))),
          unchanged: ($unchanged | split(",") | map(select(. != ""))),
          failed: ($failed | split(",") | map(select(. != ""))),
          skipped: ([.units[] | select(.status | IN("skipped-conflict", "skipped-dependency", "not-adopted", "failed")) | {id, status, reason}]
                    + [$blocked_list[] | {id: ., status: "skipped-dependency", reason: "a required unit failed while writing"}]),
          gsettings_previous: [$gsettings | split("\n")[] | select(. != "") | split("\t") | {schema: .[0], key: .[1], value: .[2]}],
          pending: ($pending | split("; ") | map(select(. != "")))}' "$plan" > "$staging/report.json" 2>/dev/null \
        && cp -- "$staging/report.json" "$HSS_THEME_REPORT" 2>/dev/null || true
    HSS_OBSERVED=$(jq -c '{variant, applied, failed, skipped: [.skipped[] | {id, status}]}' "$staging/report.json" 2>/dev/null || true)
    HSS_PENDING=$pending
    local skipped_count changed_count
    skipped_count=$(jq '[.skipped[]] | length' "$staging/report.json" 2>/dev/null || printf '0')
    # theme-core and the portal font/cursor unit change no application configuration on their own.
    changed_count=$(jq '[(.applied + .unchanged)[] | select(. != "theme-core" and . != "desktop-fonts-cursor")] | length' \
        "$staging/report.json" 2>/dev/null || printf '0')
    rm -rf -- "$staging"
    if [[ -n $failed_units ]]; then
        hss_set_outcome failed "theme $variant failed for: $failed_units"
    elif ((changed_count == 0 && skipped_count > 0)); then
        hss_set_outcome conflict "theme $variant was not applied: every application configuration was preserved or skipped"
    elif ((skipped_count > 0)); then
        hss_set_outcome completed "theme $variant partially applied; $skipped_count unit(s) preserved or skipped"
    else
        hss_set_outcome completed "theme $variant applied"
    fi
}

hss_action_theme_set() {
    local variant=${1:-}
    hss_theme_apply "$variant"
    local status=$?
    if [[ $HSS_REASON == *"partially applied"* ]]; then
        hss_notify_user "Theme partially applied" "Some configuration files had local edits and were preserved. Rerun setup to review them."
    fi
    return "$status"
}

hss_action_theme_toggle() {
    local current
    current=$(hss_theme_current_variant)
    [[ -n $current ]] || current=$(hss_theme_default_variant)
    if [[ $current == dark ]]; then
        hss_action_theme_set light
    else
        hss_action_theme_set dark
    fi
}

hss_action_theme_apply() {
    local current
    current=$(hss_theme_current_variant)
    [[ -n $current ]] || current=$(hss_theme_default_variant)
    hss_action_theme_set "$current"
}

hss_status_theme() {
    local state
    state="$(hss_theme_root)/state.json"
    if [[ ! -r $state ]]; then
        hss_status_emit theme hss-theme unavailable "$(jq -cn --arg variant "$(hss_theme_default_variant)" '{variant: null, default_variant: $variant, batch: null}')" null "theme has not been applied"
        return 0
    fi
    hss_status_emit theme hss-theme available \
        "$(jq -c '{variant, batch, partial_units: [.units | to_entries[] | select(.value | IN("skipped-conflict", "skipped-dependency", "not-adopted", "failed")) | .key]}' "$state")" \
        '{"switch":"supported"}'
}
