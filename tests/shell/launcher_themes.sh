#!/usr/bin/env bash
set -euo pipefail

# D02.4: launcher theme units render deterministically for both variants, consume only shared
# tokens, keep user content outside their regions, leave the Wi-Fi menu file alone, and the
# shipped wofi menu.css region is exactly the rendered dark variant. Native syntax was checked
# with the real applications (fuzzel --check-config, rofi -dump-theme, wofi/bemenu/fuzzel
# screenshots); see capabilities.d/d02-launchers.json.

unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
theme="$repo_root/dotfiles/.config/hypr/theme"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

python3 "$theme/hss_theme.py" check >/dev/null || fail "theme registry check failed"
jq -e '[.units[] | select(.owner != "D02")] | length == 0' "$theme/units.d/20-d02-launchers.json" >/dev/null \
    || fail "launcher fragment declares units owned by another plan"
if jq -r '.units[].outputs[].target' "$theme/units.d/20-d02-launchers.json" | grep -Eq '^config:wofi/(menu|config)$'; then
    fail "a launcher unit targets the Wi-Fi menu file or the wofi behavior config"
fi
if jq -r '.units[].outputs[] | select(.class == "managed-region") | .content // empty' "$theme/units.d/20-d02-launchers.json" | grep -Fq '../'; then
    fail "an include uses a relative path"
fi
printf 'ok - launcher units pass the registry check and stay within D02 ownership\n'

roles="$fixture/roles.json"
jq '{schema_version: 2, roles: {}, selected: {launcher: [.roles.launcher.options[] | {package}]}}' "$repo_root/packages.json" > "$roles"

# plan_launchers VARIANT HOME [--adopt]: writes $HOME/plan.json and commits staged outputs.
plan_launchers() {
    local variant=$1 home=$2
    shift 2
    python3 "$theme/hss_theme.py" plan --variant "$variant" --roles "$roles" --home "$home" \
        --config-home "$home/.config" --data-home "$home/.local/share" --theme-root "$home/.config/hss-theme" \
        --staging "$home/stage-$variant" --units theme-core,wofi,rofi,fuzzel,tofi,bemenu --out "$home/plan.json" "$@"
}

commit_plan() {
    local home=$1 target staged
    while IFS=$'\t' read -r target staged; do
        mkdir -p -- "$(dirname -- "$target")"
        cp -- "$staged" "$target"
    done < <(jq -r '.units[].outputs[] | select(.staged != null) | [.target, .staged] | @tsv' "$home/plan.json")
}

unit_status() {
    jq -r --arg id "$2" '.units[] | select(.id == $id) | .status' "$1/plan.json"
}

for variant in dark light; do
    home="$fixture/$variant"
    mkdir -p "$home/.config/wofi" "$home/.config/fuzzel"
    cp "$repo_root/dotfiles/.config/wofi/menu.css" "$repo_root/dotfiles/.config/wofi/menu" \
        "$repo_root/dotfiles/.config/wofi/config" "$home/.config/wofi/"
    printf '[main]\nterminal=foot -e\n\n[colors]\nbackground=ff0000ff\n' > "$home/.config/fuzzel/fuzzel.ini"
    cp "$home/.config/fuzzel/fuzzel.ini" "$fixture/user-fuzzel.ini"

    # Without adoption only the shipped wofi region is managed; absent user files are not created.
    plan_launchers "$variant" "$home"
    [[ $(unit_status "$home" wofi) =~ ^(ready|unchanged)$ ]] || fail "$variant: shipped wofi region is not managed without adoption"
    for unit in rofi fuzzel tofi; do
        [[ $(unit_status "$home" "$unit") == not-adopted ]] || fail "$variant: $unit changed user files without adoption"
    done

    plan_launchers "$variant" "$home" --adopt
    for unit in wofi rofi fuzzel tofi bemenu; do
        [[ $(unit_status "$home" "$unit") =~ ^(ready|unchanged)$ ]] \
            || fail "$variant: unit $unit is $(unit_status "$home" "$unit"): $(jq -r --arg id "$unit" '.units[] | select(.id == $id) | .reason' "$home/plan.json")"
    done
    if [[ $variant == dark ]]; then
        [[ $(unit_status "$home" wofi) == unchanged ]] || fail "shipped wofi menu.css region differs from the rendered dark variant"
    fi
    commit_plan "$home"

    generated="$home/.config/hss-theme/generated"
    if [[ $variant == dark ]]; then bg='#1e1e2e' other='#eff1f5'; else bg='#eff1f5' other='#1e1e2e'; fi
    grep -Fq "@define-color hss_menu_bg $bg;" "$home/.config/wofi/menu.css" || fail "$variant: wofi region lacks the variant background"
    grep -Fq '/* Personal wofi styling' "$home/.config/wofi/menu.css" || fail "$variant: content outside the wofi region was lost"
    grep -Fq 'font-family: "Noto Sans"' "$home/.config/wofi/menu.css" || fail "$variant: wofi lacks Noto Sans"
    grep -Fq '#input:focus' "$home/.config/wofi/menu.css" || fail "$variant: wofi focus state is not styled"
    if grep -Fq "$other" "$home/.config/wofi/menu.css"; then fail "$variant: wofi keeps the other variant's colors"; fi
    cmp -s "$home/.config/wofi/menu" "$repo_root/dotfiles/.config/wofi/menu" || fail "$variant: Wi-Fi menu file changed"
    cmp -s "$home/.config/wofi/config" "$repo_root/dotfiles/.config/wofi/config" || fail "$variant: wofi behavior config changed"

    grep -Fq "hss-bg: $bg;" "$generated/rofi/theme.rasi" || fail "$variant: rofi theme lacks the variant background"
    grep -Fxq "@theme \"$generated/rofi/theme.rasi\"" "$home/.config/rofi/config.rasi" || fail "$variant: rofi config does not load the theme by absolute path"
    python3 - "$generated/fuzzel/theme.ini" "$bg" <<'PY' || fail "$variant: fuzzel theme is not valid native configuration"
import configparser, sys
parser = configparser.ConfigParser(interpolation=None)
parser.read(sys.argv[1])
allowed = {
    "main": {"font"},
    "colors": {"background", "text", "prompt", "placeholder", "input", "match", "selection",
               "selection-text", "selection-match", "counter", "border"},
    "border": {"width", "radius", "selection-radius"},
}
assert set(parser.sections()) == set(allowed), parser.sections()
for section, keys in allowed.items():
    assert set(parser[section]) <= keys, (section, set(parser[section]) - keys)
for key, value in parser["colors"].items():
    assert len(value) == 8 and int(value, 16) >= 0, (key, value)
assert parser["colors"]["background"] == sys.argv[2][1:] + "ff"
assert parser["main"]["font"].startswith("Noto Sans")
PY
    head -n 3 "$home/.config/fuzzel/fuzzel.ini" | grep -Fxq "include=$generated/fuzzel/theme.ini" || fail "$variant: fuzzel include is not at the top"
    [[ $(tail -n +4 "$home/.config/fuzzel/fuzzel.ini") == "$(<"$fixture/user-fuzzel.ini")" ]] || fail "$variant: user fuzzel settings changed"
    grep -Fxq "background-color = $bg" "$generated/tofi/theme.conf" || fail "$variant: tofi theme lacks the variant background"
    grep -Fxq "include = $generated/tofi/theme.conf" "$home/.config/tofi/config" || fail "$variant: tofi config does not include the theme"
    if grep -Eq '^\s*font-size' "$generated/tofi/theme.conf"; then fail "$variant: tofi theme overrides the font size"; fi

    opts="$generated/bemenu/bemenu.opts"
    [[ $(wc -l < "$opts") == 1 ]] || fail "$variant: bemenu options are not one line"
    IFS= read -r line < "$opts"
    [[ $line == "--fn 'Noto Sans 10' "* ]] || fail "$variant: bemenu font option missing"
    [[ $line == *"--nb '$bg'"* && $line == *"--bdr '#"* ]] || fail "$variant: bemenu colors missing"
    [[ $line != *'$'* && $line != *'`'* && $line != *"\\"* ]] || fail "$variant: bemenu options contain shell syntax"

    # Rendering is idempotent: a second plan changes nothing.
    plan_launchers "$variant" "$home" --adopt
    for unit in wofi rofi fuzzel tofi bemenu; do
        [[ $(unit_status "$home" "$unit") == unchanged ]] || fail "$variant: $unit is not idempotent"
    done
    printf 'ok - %s launcher themes render, validate, preserve user content and are idempotent\n' "$variant"
done

# Switching variants touches only the managed region of the shipped wofi file.
home="$fixture/switch"
mkdir -p "$home/.config/wofi"
cp "$repo_root/dotfiles/.config/wofi/menu.css" "$home/.config/wofi/menu.css"
printf '#entry { padding: 9px; }\n' >> "$home/.config/wofi/menu.css"
plan_launchers light "$home"
commit_plan "$home"
tail -n 1 "$home/.config/wofi/menu.css" | grep -Fxq '#entry { padding: 9px; }' || fail "user wofi rule after the region was lost"
plan_launchers dark "$home"
commit_plan "$home"
head -n "$(grep -n '<<< hss-theme:wofi <<<' "$home/.config/wofi/menu.css" | cut -d: -f1)" "$home/.config/wofi/menu.css" > "$fixture/region"
head -n "$(grep -n '<<< hss-theme:wofi <<<' "$repo_root/dotfiles/.config/wofi/menu.css" | cut -d: -f1)" "$repo_root/dotfiles/.config/wofi/menu.css" > "$fixture/shipped-region"
cmp -s "$fixture/region" "$fixture/shipped-region" || fail "dark region after a light round trip differs from the shipped region"
printf 'ok - switching variants rewrites only the wofi region and round-trips to the shipped file\n'
