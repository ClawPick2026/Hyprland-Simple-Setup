#!/usr/bin/env bash
set -euo pipefail

# D03.4: notification theme units render deterministically for both variants, consume only
# shared tokens, carry the native retention/DND settings, keep every non-appearance setting
# (scripts, rules, timeouts, urgency policy) and user content outside their regions or keys.
# Real-daemon checks (swaync, mako, dunst, fnott accepting the rendered files, user settings
# after the region winning) are evidence in capabilities.d/d03-notifications.json.

unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
theme="$repo_root/dotfiles/.config/hypr/theme"
fragment="$theme/units.d/30-d03-notifications.json"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

python3 "$theme/hss_theme.py" check >/dev/null || fail "theme registry check failed"
jq -e '[.units[] | select(.owner != "D03")] | length == 0' "$fragment" >/dev/null || fail "fragment declares units of another plan"
jq -e '[.units[] | .id as $id | .outputs[] | {file: .target, unit: $id}] | group_by(.file)
    | all(map(.unit) | unique | length == 1)' "$fragment" >/dev/null || fail "a target file is owned by more than one unit"
if jq -r '.units[].outputs[].target' "$fragment" | grep -Fq 'swaync/config.json'; then
    fail "a unit targets the SwayNC behavior configuration"
fi
if jq -r '.units[].outputs[] | .content // empty' "$fragment" | grep -Fq '../'; then fail "an include uses a relative path"; fi
jq -e '
    (.units[] | select(.id == "swaync") | .activation) == [{"kind": "reload", "argv": ["swaync-client", "--reload-css", "--skip-wait"], "process": "swaync"}]
    and (.units[] | select(.id == "mako") | .activation) == [{"kind": "reload", "argv": ["makoctl", "reload"], "process": "mako"}]
    and (.units[] | select(.id == "dunst") | .activation) == [{"kind": "reload", "argv": ["dunstctl", "reload"], "process": "dunst"}]
    and (.units[] | select(.id == "fnott") | .activation) == [{"kind": "next-launch"}]' "$fragment" >/dev/null \
    || fail "activation must be a native reload of a running daemon only (fnott: next launch)"
printf 'ok - notification units pass the registry check, own one file each and reload only running daemons\n'

roles="$fixture/roles.json"
jq '{schema_version: 2, roles: {}, selected: {notifications: [.roles.notifications.options[] | {package}]}}' "$repo_root/packages.json" > "$roles"

plan_notifications() {
    local variant=$1 home=$2
    shift 2
    python3 "$theme/hss_theme.py" plan --variant "$variant" --roles "$roles" --home "$home" \
        --config-home "$home/.config" --data-home "$home/.local/share" --theme-root "$home/.config/hss-theme" \
        --staging "$home/stage-$variant" --units theme-core,swaync,mako,dunst,fnott --out "$home/plan.json" "$@"
}

commit_plan() {
    local target staged
    while IFS=$'\t' read -r target staged; do
        mkdir -p -- "$(dirname -- "$target")"
        cp -- "$staged" "$target"
    done < <(jq -r '.units[].outputs[] | select(.staged != null) | [.target, .staged] | @tsv' "$1/plan.json")
}

unit_status() {
    jq -r --arg id "$2" '.units[] | select(.id == $id) | .status' "$1/plan.json"
}

# Keys verified against fnott 1.8 (any unknown fnott key is fatal, E-D03-027).
fnott_allowed='title-font summary-font body-font background border-color border-size border-radius title-color summary-color body-color progress-color'

for variant in dark light; do
    home="$fixture/$variant"
    mkdir -p "$home/.config/swaync" "$home/.config/dunst" "$home/.config/fnott" "$home/.config/mako"
    cp "$repo_root/dotfiles/.config/swaync/style.css" "$repo_root/dotfiles/.config/swaync/config.json" "$home/.config/swaync/"
    printf '[my_rule]\n    appname = synthetic-app\n    script = /usr/local/bin/hss-example\n    timeout = 3\n' > "$home/.config/dunst/dunstrc"
    printf 'max-width=400\n\n[critical]\nborder-color=000000ff\n' > "$home/.config/fnott/fnott.ini"
    printf 'default-timeout=7000\n[app-name=synthetic-app]\ninvisible=1\n' > "$home/.config/mako/config"
    cp "$home/.config/dunst/dunstrc" "$fixture/user-dunstrc"
    cp "$home/.config/mako/config" "$fixture/user-mako"

    plan_notifications "$variant" "$home"
    [[ $(unit_status "$home" swaync) =~ ^(ready|unchanged)$ ]] || fail "$variant: shipped SwayNC region is not managed"
    for unit in mako dunst fnott; do
        [[ $(unit_status "$home" "$unit") == not-adopted ]] || fail "$variant: $unit changed a user file without adoption"
    done

    plan_notifications "$variant" "$home" --adopt
    for unit in swaync mako dunst; do
        [[ $(unit_status "$home" "$unit") =~ ^(ready|unchanged)$ ]] \
            || fail "$variant: $unit is $(unit_status "$home" "$unit"): $(jq -r --arg id "$unit" '.units[] | select(.id == $id) | .reason' "$home/plan.json")"
    done
    # fnott: a user value for a managed key is a conflict on first adoption only if recorded; here it is adopted.
    [[ $(unit_status "$home" fnott) =~ ^(ready|unchanged)$ ]] || fail "$variant: fnott unit is $(unit_status "$home" fnott)"
    if [[ $variant == dark ]]; then
        [[ $(unit_status "$home" swaync) == unchanged ]] || fail "shipped SwayNC region differs from the rendered dark variant"
    fi
    commit_plan "$home"

    generated="$home/.config/hss-theme/generated"
    if [[ $variant == dark ]]; then
        bg='#1e1e2e' red='#f38ba8' other='#eff1f5'
    else
        bg='#eff1f5' red='#d20f39' other='#1e1e2e'
    fi

    style="$home/.config/swaync/style.css"
    grep -Fq "@define-color noti-critical-accent $red;" "$style" || fail "$variant: SwayNC critical accent missing"
    grep -Fq 'font-family: "Noto Sans"' "$style" || fail "$variant: SwayNC font family missing"
    grep -Fq 'box-shadow: inset 0 0 0 2px @noti-focus-ring;' "$style" || fail "$variant: SwayNC focus ring missing"
    if grep -Eq 'rgb\(48, 54, 80\)|#db1a1a|#4aeaff' "$style"; then fail "$variant: legacy SwayNC palette remains"; fi
    if grep -Fq "$other" "$style"; then fail "$variant: SwayNC keeps the other variant's colors"; fi
    grep -Fq 'transition: background 0.15s ease-in-out;' "$style" || fail "$variant: SwayNC motion rules changed"
    cmp -s "$home/.config/swaync/config.json" "$repo_root/dotfiles/.config/swaync/config.json" || fail "$variant: SwayNC config.json changed"

    mako="$generated/mako/theme.conf"
    head -n 3 "$home/.config/mako/config" | grep -Fxq "include=$mako" || fail "$variant: mako include is not at the top"
    [[ $(tail -n +4 "$home/.config/mako/config") == "$(<"$fixture/user-mako")" ]] || fail "$variant: user mako settings changed"
    grep -Fxq "background-color=${bg}e6" "$mako" || fail "$variant: mako background is not the variant color"
    grep -Fxq 'max-history=100' "$mako" || fail "$variant: mako history cap missing"
    python3 - "$mako" <<'PY' || fail "$variant: mako DND sections are wrong"
import sys
lines = [line.strip() for line in open(sys.argv[1]) if line.strip() and not line.startswith("#")]
dnd = lines.index("[mode=do-not-disturb]")
critical = lines.index("[mode=do-not-disturb urgency=critical]")
assert lines[dnd + 1] == "invisible=1" and lines[critical + 1] == "invisible=0" and critical > dnd
assert not any(line.split("=")[0] in ("default-timeout", "ignore-timeout", "on-notify", "on-button-left") for line in lines)
PY

    dunstrc="$home/.config/dunst/dunstrc"
    python3 - "$dunstrc" "$fixture/user-dunstrc" "$bg" <<'PY' || fail "$variant: dunst region is wrong"
import configparser, sys
text = open(sys.argv[1]).read()
start, end = "# >>> hss-theme:dunst >>>", "# <<< hss-theme:dunst <<<"
assert text.startswith(start), "region is not at the top"
region, after = text.split(end + "\n", 1)
assert after == open(sys.argv[2]).read(), "user content changed"
parser = configparser.ConfigParser(interpolation=None)
parser.read_string(region.split("\n", 1)[1])
assert parser["global"]["history_length"] == "100"
assert parser["urgency_critical"]["override_pause_level"] == "100"
assert parser["hss_transient_no_history"]["match_transient"] == "yes"
assert parser["hss_transient_no_history"]["history_ignore"] == "yes"
assert parser["urgency_normal"]["background"] == '"%s"' % sys.argv[3]
for section in parser.sections():
    assert "timeout" not in parser[section], f"{section} sets a timeout"
    assert "script" not in parser[section], f"{section} sets a script"
PY

    fnott="$home/.config/fnott/fnott.ini"
    python3 - "$fnott" "$fnott_allowed" "${bg#\#}" <<'PY' || fail "$variant: fnott keys are wrong"
import sys
allowed = set(sys.argv[2].split())
section, values = "main", {}
for raw in open(sys.argv[1]):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("["):
        section = line[1:-1]
        continue
    key, _, value = line.partition("=")
    values.setdefault(section, {})[key] = value
assert values["main"]["max-width"] == "400", "user key lost"
for section, keys in values.items():
    unknown = set(keys) - allowed - ({"max-width"} if section == "main" else set())
    assert not unknown, (section, unknown)
assert values["main"]["background"] == sys.argv[3] + "ff"
assert values["main"]["title-font"].startswith("Noto Sans")
assert values["critical"]["border-color"] != "000000ff", "critical border not managed"
PY

    plan_notifications "$variant" "$home" --adopt
    for unit in swaync mako dunst fnott; do
        [[ $(unit_status "$home" "$unit") == unchanged ]] || fail "$variant: $unit is not idempotent"
    done
    printf 'ok - %s notification themes render, keep retention/DND/transient settings and user content, and are idempotent\n' "$variant"
done

# A user edit inside the dunst region is preserved as a conflict, not overwritten.
home="$fixture/dark"
python3 "$theme/hss_theme.py" finalize --plan "$home/plan.json" --theme-root "$home/.config/hss-theme" \
    --unchanged swaync,mako,dunst,fnott,theme-core --out-managed "$home/managed.json" --out-state "$home/state.json"
cp "$home/managed.json" "$home/.config/hss-theme/managed.json"
sed -i 's/history_length = 100/history_length = 5/' "$home/.config/dunst/dunstrc"
cp "$home/.config/dunst/dunstrc" "$fixture/edited-dunstrc"
plan_notifications light "$home" --adopt
[[ $(unit_status "$home" dunst) == skipped-conflict ]] || fail "edited dunst region was not reported as a conflict"
cmp -s "$home/.config/dunst/dunstrc" "$fixture/edited-dunstrc" || fail "planning changed the edited dunstrc"
printf 'ok - a user edit inside a managed notification region is a conflict and is preserved\n'

# Switching variants round-trips the shipped SwayNC file.
home="$fixture/switch"
mkdir -p "$home/.config/swaync"
cp "$repo_root/dotfiles/.config/swaync/style.css" "$home/.config/swaync/style.css"
plan_notifications light "$home"
commit_plan "$home"
plan_notifications dark "$home"
commit_plan "$home"
cmp -s "$home/.config/swaync/style.css" "$repo_root/dotfiles/.config/swaync/style.css" || fail "SwayNC light/dark round trip differs from the shipped file"
printf 'ok - SwayNC variant switching rewrites only its region and round-trips to the shipped file\n'
