#!/usr/bin/env bash
set -euo pipefail

# D04 appearance: nmtui (libnewt) and Alsamixer units render valid native color syntax for
# both variants, apply only to selected members, preserve user content and detect edits.
# GTK/Qt device apps use the global F03 units; the capability ledger must say so.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
theme_dir="$repo_root/dotfiles/.config/hypr/theme"
base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$*"; }

python3 "$theme_dir/hss_theme.py" check >/dev/null || fail 'theme registry check'
ok 'registry with the D04 fragment passes hss_theme.py check'

roles_for() {
    local file=$1 network=$2 audio=$3
    jq --arg network "$network" --arg audio "$audio" '
        . as $c | {schema_version: 2,
          roles: {network: ($c.roles.network.options[] | select(.package == $network)),
                  audio: ($c.roles.audio.options[] | select(.package == $audio))},
          selected: {network: [$c.roles.network.options[] | select(.package == $network)],
                     audio: [$c.roles.audio.options[] | select(.package == $audio)]}}
    ' "$repo_root/packages.json" > "$file"
}

# plan HOME VARIANT ROLES [extra args]: render into HOME/stage-VARIANT, plan in HOME/plan-VARIANT.json
plan() {
    local home=$1 variant=$2 roles=$3
    shift 3
    rm -rf "$home/stage-$variant"
    python3 "$theme_dir/hss_theme.py" plan --variant "$variant" --roles "$roles" --home "$home" \
        --config-home "$home/.config" --data-home "$home/.local/share" --theme-root "$home/.config/hss-theme" \
        --staging "$home/stage-$variant" --out "$home/plan-$variant.json" --units nmtui,alsamixer "$@"
}

unit_status() {
    jq -r --arg id "$2" '.units[] | select(.id == $id) | .status' "$1"
}

staged() {
    jq -r --arg id "$2" --arg target "$3" '.units[] | select(.id == $id) | .outputs[] | select(.target | endswith($target)) | .staged // empty' "$1"
}

home="$base/home"
mkdir -p "$home/.config"
roles_for "$base/roles-tui.json" networkmanager alsa-utils
roles_for "$base/roles-gui.json" plasma-nm pavucontrol-qt

newt_elements='root border window shadow title button actbutton checkbox actcheckbox entry label listbox actlistbox textbox acttextbox helpline roottext emptyscale fullscale disentry compactbutton actsellistbox sellistbox'
declare -A dark_root=()
for variant in dark light; do
    plan "$home" "$variant" "$base/roles-tui.json" --adopt
    [[ $(unit_status "$home/plan-$variant.json" nmtui) == ready ]] || fail "nmtui unit not ready ($variant)"
    colors=$(staged "$home/plan-$variant.json" nmtui newt/colors)
    [[ -s $colors ]] || fail "no newt colors ($variant)"
    mapfile -t lines < "$colors"
    ((${#lines[@]} == 23)) || fail "expected 23 newt elements, got ${#lines[@]}"
    for line in "${lines[@]}"; do
        [[ $line =~ ^([a-z]+)=#[0-9a-f]{6},#[0-9a-f]{6}$ ]] || fail "invalid newt color line: $line"
        [[ " $newt_elements " == *" ${BASH_REMATCH[1]} "* ]] || fail "unknown newt element ${BASH_REMATCH[1]}"
    done
    dark_root[$variant]=$(grep '^root=' "$colors")
done
[[ ${dark_root[dark]} == 'root=#cdd6f4,#11111b' && ${dark_root[light]} == 'root=#4c4f69,#dce0e8' ]] \
    || fail "variant colors: ${dark_root[*]}"
ok 'nmtui: 23 known libnewt elements with #rrggbb pairs (NEWT_COLORS_FILE syntax), Mocha and Latte differ'

alsa_elements='mixer_frame mixer_text mixer_active ctl_frame ctl_mute ctl_nomute ctl_capture ctl_nocapture ctl_label ctl_label_focus ctl_mark_focus ctl_bar_lo ctl_bar_mi ctl_bar_hi ctl_inactive ctl_label_inactive errormsg infomsg textbox textfield menu menu_selected'
alsa_colors='red green yellow blue magenta cyan white black none default'
alsa_attrs='bold normal reverse underline dim italic blink'
plan "$home" dark "$base/roles-tui.json" --adopt
rc=$(staged "$home/plan-dark.json" alsamixer alsamixer.rc)
[[ -s $rc ]] || fail 'alsamixer.rc not created'
[[ $(sed -n 1p "$rc") == '# >>> hss-theme:alsamixer >>>' && $(tail -n 1 "$rc") == '# <<< hss-theme:alsamixer <<<' ]] \
    || fail 'created alsamixer.rc must contain only the managed region'
count=0
while read -r keyword element fg bg attrs; do
    [[ $keyword == color ]] || continue
    count=$((count + 1))
    [[ " $alsa_elements " == *" $element "* ]] || fail "unknown alsamixer element $element"
    [[ " $alsa_colors " == *" $fg "* && " $alsa_colors " == *" $bg "* ]] || fail "invalid alsamixer colors: $element $fg $bg"
    for attr in $attrs; do [[ " $alsa_attrs " == *" $attr "* ]] || fail "invalid attribute $attr"; done
done < "$rc"
((count == 22)) || fail "expected 22 alsamixer elements, got $count"
ok 'alsamixer.rc: every theme element from alsamixer(1) with valid color names and attributes'

# Existing user file: content outside the region is preserved; edits to the region conflict.
printf '# my settings\nset mouse_wheel_step 2\ncolor menu red default\n' > "$home/.config/alsamixer.rc"
plan "$home" dark "$base/roles-tui.json"
[[ $(unit_status "$home/plan-dark.json" alsamixer) == not-adopted ]] || fail 'existing rc adopted without consent'
plan "$home" dark "$base/roles-tui.json" --adopt
rc=$(staged "$home/plan-dark.json" alsamixer alsamixer.rc)
[[ $(head -n 3 "$rc") == $'# my settings\nset mouse_wheel_step 2\ncolor menu red default' ]] || fail 'user lines were changed'
cp "$rc" "$home/.config/alsamixer.rc"
python3 "$theme_dir/hss_theme.py" finalize --plan "$home/plan-dark.json" --theme-root "$home/.config/hss-theme" \
    --applied alsamixer --out-managed "$base/managed.json" --out-state "$base/state.json"
mkdir -p "$home/.config/hss-theme"
cp "$base/managed.json" "$home/.config/hss-theme/managed.json"
plan "$home" light "$base/roles-tui.json"
[[ $(unit_status "$home/plan-light.json" alsamixer) =~ ^(ready|unchanged)$ ]] || fail 'recorded region not reusable'
sed -i 's/^color menu_selected .*/color menu_selected red red/' "$home/.config/alsamixer.rc"
plan "$home" light "$base/roles-tui.json"
[[ $(unit_status "$home/plan-light.json" alsamixer) == skipped-conflict ]] || fail 'edited region was not detected'
ok 'alsamixer: user lines kept, adoption required for existing files, edited region is a conflict'

plan "$home" dark "$base/roles-gui.json" --adopt
[[ $(unit_status "$home/plan-dark.json" nmtui) == not-selected && $(unit_status "$home/plan-dark.json" alsamixer) == not-selected ]] \
    || fail 'TUI device units applied to unselected members'
ok 'device units apply only to selected members'

ledger="$repo_root/capabilities.d/d04-devices.json"
coverage="$repo_root/tests/fixtures/harmonization/coverage/d04-devices.json"
python3 - "$ledger" "$coverage" "$repo_root/packages.json" "$theme_dir" <<'PY'
import json, re, sys
from pathlib import Path
ledger = json.loads(Path(sys.argv[1]).read_text())
coverage = json.loads(Path(sys.argv[2]).read_text())
catalog = json.loads(Path(sys.argv[3]).read_text())
theme_dir = Path(sys.argv[4])
units = {u["id"] for f in [theme_dir / "units.json", *sorted((theme_dir / "units.d").glob("*.json"))]
         for u in json.loads(f.read_text())["units"]}
assert ledger["schema_version"] == 1 and ledger["owner"] == "D04"
expected = {f"{role}/{o['package']}" for role in ("network", "bluetooth", "audio") for o in catalog["roles"][role]["options"]}
assert set(ledger["options"]) == expected, set(ledger["options"]) ^ expected
evidence = ledger["evidence"]
assert all(re.fullmatch(r"E-D04-\d{3}", key) for key in evidence), "evidence id format"
for key, item in evidence.items():
    assert item["kind"] in {"documentation", "static", "argv", "modeled-effect", "real-effect", "visual"}, key
    for field in ("source", "date", "environment", "command", "result"):
        assert isinstance(item.get(field), str) and item[field], (key, field)
caps = ledger["capabilities"]
for name, option in ledger["options"].items():
    assert option["support"] in {"full", "limited", "unverified"}, name
    assert option["family"] in {"gtk3", "gtk4", "libadwaita", "qt5", "qt6", "kde", "electron", "custom", "tui", "cli"}, name
    assert option["startup"] in {"on-demand", "daemon", "dbus-activated", "session-service", "terminal"}, name
    unsupported = False
    for cap, entry in option["capabilities"].items():
        assert cap in caps, (name, cap)
        assert entry["support"] in {"supported", "partial", "unsupported", "unverified", "not-applicable"}, (name, cap)
        assert entry["mechanism"] in {"native-cli", "native-config", "native-api", "native-ui", "none"}, (name, cap)
        for ref in entry["evidence"]:
            assert ref in evidence, (name, cap, ref)
        if caps[cap]["requirement"] == "required" and entry["support"] == "unsupported":
            unsupported = True
    if unsupported:
        assert option["support"] == "limited", f"{name} has an unsupported required capability"
    if option["support"] == "limited":
        assert option["limitations"], name
    for unit in option["theme"]["units"]:
        assert unit in units, (name, unit)
for alsa in ("audio/qastools", "audio/alsa-utils"):
    assert ledger["options"][alsa]["support"] == "limited"
    assert ledger["options"][alsa]["capabilities"]["audio.streams"]["support"] == "unsupported"
for gui in ("network/network-manager-applet", "network/nm-connection-editor", "bluetooth/blueman"):
    assert "gtk3" in ledger["options"][gui]["theme"]["units"], gui
assert "gtk4" in ledger["options"]["audio/pavucontrol"]["theme"]["units"]
for qt in ("audio/pavucontrol-qt", "audio/qastools"):
    assert "qt6ct" in ledger["options"][qt]["theme"]["units"], qt
assert coverage["owner"] == "D04"
covered = {case["option"] for case in coverage["cases"]}
assert expected <= covered, expected - covered
for case in coverage["cases"]:
    assert case["result"] == "not-run"
    for test in case["tests"]:
        assert test["state"] in {"delivered", "planned"}
        if test["state"] == "delivered":
            assert (Path(sys.argv[1]).parents[1] / test["path"]).is_file(), test["path"]
PY
ok 'D04 ledger: 13 options, valid vocabulary and evidence, ALSA-only mixers limited, global GTK/Qt mappings declared; coverage complete'
