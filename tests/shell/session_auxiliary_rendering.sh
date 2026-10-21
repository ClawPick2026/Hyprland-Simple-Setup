#!/usr/bin/env bash
# shellcheck disable=SC2016 # hyprlang $variables are matched literally
set -euo pipefail

# D07 appearance units: Hyprland, Hyprlock, Wlogout, btop and cava render for Mocha and Latte,
# keep user content, load safely at runtime, and the Tk keybinding viewer falls back when no
# palette exists. Also checks the generic-package classification against the catalog.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
theme_dir="$repo_root/dotfiles/.config/hypr/theme"
dotfiles="$repo_root/dotfiles/.config"
base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$*"; }

lua_bin=$(command -v lua || command -v lua5.4) || fail 'lua is required'
luac_bin=$(command -v luac || command -v luac5.4) || fail 'luac is required'

fresh_home() {
    local home=$1
    mkdir -p "$home/.config/hypr/sources" "$home/.config/wlogout" "$home/.config/btop" "$home/.config/cava"
    cp "$dotfiles/hypr/sources_example/look_and_feel.lua" "$home/.config/hypr/sources/"
    cp "$dotfiles/wlogout/style.css" "$dotfiles/wlogout/layout" "$home/.config/wlogout/"
    cp "$dotfiles/btop/btop.conf" "$home/.config/btop/"
    cp "$dotfiles/cava/config" "$home/.config/cava/"
}

UNITS=hyprland,hyprlock,wlogout,btop,cava
plan() {
    local home=$1 variant=$2
    shift 2
    rm -rf "$home/stage-$variant"
    python3 "$theme_dir/hss_theme.py" plan --variant "$variant" --home "$home" --config-home "$home/.config" \
        --data-home "$home/.local/share" --theme-root "$home/.config/hss-theme" --staging "$home/stage-$variant" \
        --out "$home/plan-$variant.json" --units "$UNITS" "$@"
}
status_of() { jq -r --arg id "$2" '.units[] | select(.id == $id) | .status' "$1"; }
staged() {
    jq -r --arg id "$2" --arg target "$3" '.units[] | select(.id == $id) | .outputs[] | select(.target | endswith($target)) | .staged // empty' "$1"
}
action_of() {
    jq -r --arg id "$2" --arg target "$3" '.units[] | select(.id == $id) | .outputs[] | select(.target | endswith($target)) | .action' "$1"
}

python3 "$theme_dir/hss_theme.py" check >/dev/null || fail 'registry check'
ok 'registry with the D07 fragment passes hss_theme.py check'

home="$base/fresh"
fresh_home "$home"
for variant in dark light; do
    plan "$home" "$variant" --adopt
    for unit in hyprland hyprlock wlogout btop cava; do
        [[ $(status_of "$home/plan-$variant.json" "$unit") =~ ^(ready|unchanged)$ ]] || fail "$unit not ready ($variant)"
    done
    [[ $(action_of "$home/plan-$variant.json" hyprland look_and_feel.lua) == unchanged ]] \
        || fail "shipped look_and_feel.lua region differs from the renderer ($variant)"
done
[[ $(action_of "$home/plan-dark.json" cava cava/config) == unchanged ]] || fail 'shipped cava gradient differs from Mocha'
[[ $(action_of "$home/plan-dark.json" btop btop.conf) == unchanged ]] || fail 'shipped btop color_theme differs'
ok 'fresh configuration: shipped Hyprland region, Mocha cava gradient and btop theme name match the renderer'

# --------------------------------------------------------------- Hyprland
for variant in dark light; do
    plan "$home" "$variant" --adopt
    theme_lua=$(staged "$home/plan-$variant.json" hyprland hyprland/theme.lua)
    "$luac_bin" -p "$theme_lua" || fail "generated theme.lua does not compile ($variant)"
    accent=$(jq -r --arg v "$variant" '.variants[$v].color.accent' "$theme_dir/tokens.json")
    palette=$(jq -r --arg v "$variant" '.variants[$v].palette' "$theme_dir/tokens.json")
    accent=$(jq -r --arg p "$palette" --arg name "${accent#@}" '.palettes[$p][$name]' "$theme_dir/tokens.json")
    "$lua_bin" - "$theme_lua" "${accent#\#}" "$variant" <<'LUA' || fail "generated table ($variant)"
local theme = dofile(arg[1])
assert(theme.variant == arg[3], "variant")
local c = theme.config
assert(c.general.col.active_border.colors[1] == "rgba(" .. arg[2] .. "ff)", "accent border")
assert(c.decoration.active_opacity == 1.0 and c.decoration.inactive_opacity == 1.0, "applications stay opaque")
assert(type(c.general.border_size) == "number" and type(c.decoration.rounding) == "number", "metrics")
assert(c.group.groupbar.text_color and c.group.groupbar.text_color_inactive, "groupbar text")
LUA
    mkdir -p "$home/.config/hss-theme/generated/hyprland"
    cp "$theme_lua" "$home/.config/hss-theme/generated/hyprland/theme-$variant.lua"
done
ok 'generated Hyprland table compiles, uses the variant accent and keeps applications opaque'

# Evaluate look_and_feel.lua with a recording hl table to prove the runtime include and fallback.
run_look() {
    env -u XDG_CONFIG_HOME HOME="$1" ${2:+XDG_CONFIG_HOME="$2"} "$lua_bin" - "$dotfiles/hypr/sources_example/look_and_feel.lua" <<'LUA'
local calls = {}
hl = setmetatable({config = function(t) calls[#calls + 1] = t end}, {__index = function() return function() end end})
dofile(arg[1])
local last = calls[#calls]
local border = last.general and last.general.col and last.general.col.active_border
print(#calls, type(border) == "table" and border.colors[1] or tostring(border))
LUA
}
generated="$home/.config/hss-theme/generated/hyprland/theme.lua"
cp "$home/.config/hss-theme/generated/hyprland/theme-light.lua" "$generated"
[[ $(run_look "$home") == $'2\trgba(1e66f5ff)' ]] || fail "region did not apply the generated table: $(run_look "$home")"
[[ $(run_look "$base/elsewhere" "$home/.config") == $'2\trgba(1e66f5ff)' ]] || fail 'XDG_CONFIG_HOME is not honored'
printf 'return {{{ broken\n' > "$generated"
[[ $(run_look "$home") == $'1\trgba(a591ffdd)' ]] || fail "broken generated file is not ignored: $(run_look "$home")"
rm -f "$generated"
[[ $(run_look "$home") == $'1\trgba(a591ffdd)' ]] || fail 'missing generated file is not ignored'
ok 'look_and_feel.lua applies the generated table and keeps its literal values when the file is missing or broken'

existing="$base/existing"
fresh_home "$existing"
sed -i '/>>> hss-theme:hyprland >>>/,$d' "$existing/.config/hypr/sources/look_and_feel.lua"
printf '%s\n' '-- user tweak' 'hl.config({ general = { gaps_in = 9 } })' >> "$existing/.config/hypr/sources/look_and_feel.lua"
cp "$existing/.config/hypr/sources/look_and_feel.lua" "$base/look-before.lua"
plan "$existing" dark
[[ $(status_of "$existing/plan-dark.json" hyprland) == not-adopted ]] || fail 'existing look_and_feel.lua adopted without consent'
plan "$existing" dark --adopt
adopted=$(staged "$existing/plan-dark.json" hyprland look_and_feel.lua)
cmp -s <(head -c "$(stat -c %s "$base/look-before.lua")" "$adopted") "$base/look-before.lua" || fail 'user content changed during adoption'
"$luac_bin" -p "$adopted" || fail 'adopted look_and_feel.lua does not compile'
grep -q '^-- >>> hss-theme:hyprland >>>$' "$adopted" || fail 'region not appended'
ok 'existing look_and_feel.lua: adoption needs consent, appends only the region and keeps user lines'

# --------------------------------------------------------------- Hyprlock
plan "$home" light --adopt
colors=$(staged "$home/plan-light.json" hyprlock hyprlock/colors.conf)
used=$(grep -o '\$hss_[a-z_]*' "$dotfiles/hypr/hyprlock.conf" | sort -u)
for name in $used; do
    grep -q "^\\$name = " "$colors" || fail "generated hyprlock colors miss $name"
    grep -q "^\\$name = " "$dotfiles/hypr/hyprlock/catppuccin.conf" || fail "hyprlock fallback misses $name"
done
grep -q '^\$hss_bg = rgba(eff1f5ff)$' "$colors" || fail 'Latte background'
mapfile -t sources < <(grep -n '^source = \|^# hyprlang noerror' "$dotfiles/hypr/hyprlock.conf")
[[ ${sources[0]} == *'source = ~/.config/hypr/hyprlock/catppuccin.conf' && ${sources[1]} == *'# hyprlang noerror true' \
    && ${sources[2]} == *'source = ~/.config/hss-theme/generated/hyprlock/colors.conf' && ${sources[3]} == *'# hyprlang noerror false' ]] \
    || fail "hyprlock source order: ${sources[*]}"
for key in 'path = screenshot' 'blur_passes = 2' 'check_color = $hss_warning' 'fail_color = $hss_error' \
    'capslock_color = $hss_warning' 'outer_color = $hss_focus' 'fail_text = <b>$PAMFAIL</b>'; do
    grep -Fq "$key" "$dotfiles/hypr/hyprlock.conf" || fail "hyprlock.conf misses $key"
done
ok 'hyprlock: fallback then generated palette (noerror), screenshot blur kept, input/check/fail/caps states themed'

# --------------------------------------------------------------- Wlogout
css=$(staged "$home/plan-light.json" wlogout style.css)
cmp -s <(head -c "$(stat -c %s "$dotfiles/wlogout/style.css")" "$css") "$dotfiles/wlogout/style.css" || fail 'style.css content changed'
tail -n 3 "$css" | grep -Fxq "@import url(\"file://$home/.config/hss-theme/generated/palette.css\");" || fail 'palette import missing'
grep -Fq 'background-image: url("../../.cache/wlogout/current-wallpaper");' "$css" || fail 'wallpaper background lost'
palette_css="$home/stage-light/theme-core/01-palette.css"
[[ -s $palette_css ]] || palette_css=$(staged "$home/plan-light.json" theme-core palette.css)
while IFS= read -r name; do
    grep -q "^@define-color ${name#@} " "$dotfiles/wlogout/style.css" || fail "style.css fallback misses $name"
    grep -q "^@define-color ${name#@} " "$palette_css" || fail "generated palette misses $name"
done < <(grep -Eo '@hss_[a-z0-9_]+' "$dotfiles/wlogout/style.css" | sort -u)
for button in lock logout suspend hibernate shutdown reboot; do
    grep -A1 "^#$button {" "$css" | grep -q -- '-gtk-icontheme("system-' || fail "$button icon"
done
ok 'wlogout: Mocha fallback, appended absolute palette import, every @hss color defined in both, Breeze icons'

# --------------------------------------------------------------- btop and cava
plan "$home" light --adopt
btop_theme=$(staged "$home/plan-light.json" btop btop/themes/hss.theme)
for key in main_bg main_fg title hi_fg selected_bg selected_fg inactive_fg graph_text meter_bg proc_misc cpu_box mem_box \
    net_box proc_box div_line temp_start temp_mid temp_end cpu_start cpu_mid cpu_end free_start free_mid free_end \
    cached_start cached_mid cached_end available_start available_mid available_end used_start used_mid used_end \
    download_start download_mid download_end upload_start upload_mid upload_end process_start process_mid process_end; do
    grep -Eq "^theme\[$key\]=\"#[0-9a-f]{6}\"$" "$btop_theme" || fail "btop theme key $key"
done
grep -q '^theme\[main_bg\]="#eff1f5"$' "$btop_theme" || fail 'btop Latte background'
grep -q '^color_theme = "hss"$' "$dotfiles/btop/btop.conf" || fail 'btop does not select the generated theme'
cava_config=$(staged "$home/plan-light.json" cava cava/config)
grep -q "^gradient_color_4='#1e66f5'$" "$cava_config" || fail 'cava Latte gradient'
diff <(sed '/^\[color\]/,/^\[smoothing\]/d' "$dotfiles/cava/config") <(sed '/^\[color\]/,/^\[smoothing\]/d' "$cava_config") >/dev/null \
    || fail 'cava settings outside [color] changed'
ok 'btop theme defines every key in btop themes directory; cava changes only gradient keys'

# --------------------------------------------------------------- Tk keybinding viewer
python3 - "$dotfiles/waybar/scripts/keybinds.py" "$base" <<'PY'
import json, os, runpy, sys
from pathlib import Path
from types import ModuleType
from unittest.mock import patch
tk = ModuleType("tkinter"); tk.Event = object; tk.ttk = ModuleType("tkinter.ttk")
config = Path(sys.argv[2]) / "xdg"
generated = config / "hss-theme" / "generated"
generated.mkdir(parents=True)
os.environ["XDG_CONFIG_HOME"] = str(config)
with patch.dict("sys.modules", {"tkinter": tk, "tkinter.ttk": tk.ttk}):
    viewer = runpy.run_path(sys.argv[1])
fallback = viewer["FALLBACK_THEME"]
assert viewer["KeybindsConfig"].BG_COLOR == fallback["bg"] == "#1e1e2e"
load = viewer["load_theme"]
assert load() == fallback
(generated / "palette.json").write_text(json.dumps({"color": {"bg": "#eff1f5", "fg": "#4c4f69", "accent": "#1e66f5",
    "surface0": "#ccd0da", "selection_bg": "#bcc0cc", "selection_fg": "#4c4f69"}, "font": {"ui_family": "Noto Sans", "mono_family": "JetBrainsMono Nerd Font"}}))
light = load()
assert light["bg"] == "#eff1f5" and light["accent"] == "#1e66f5" and light["mono_family"] == "JetBrainsMono Nerd Font"
(generated / "palette.json").write_text('{"color": {"bg": "red; rm -rf", "fg": "#4c4f69"}, "font": {"ui_family": "Bad\\nFont"}}')
partial = load()
assert partial["bg"] == fallback["bg"] and partial["fg"] == "#4c4f69" and partial["ui_family"] == fallback["ui_family"]
(generated / "palette.json").write_text("not json")
assert load() == fallback
with patch.dict("sys.modules", {"tkinter": tk, "tkinter.ttk": tk.ttk}):
    (generated / "palette.json").write_text(json.dumps({"color": {"bg": "#eff1f5"}}))
    reloaded = runpy.run_path(sys.argv[1])
assert reloaded["KeybindsConfig"].BG_COLOR == "#eff1f5"
PY
ok 'keybinding viewer reads the generated palette and falls back per key without one'

# --------------------------------------------------------------- generic package classification
python3 - "$repo_root/capabilities.d/d07-session-auxiliary.json" "$repo_root/packages.json" \
    "$repo_root/tests/fixtures/harmonization/coverage/d07-session-auxiliary.json" "$theme_dir" <<'PY'
import json, re, sys
from pathlib import Path
ledger = json.loads(Path(sys.argv[1]).read_text())
catalog = json.loads(Path(sys.argv[2]).read_text())
coverage = json.loads(Path(sys.argv[3]).read_text())
theme_dir = Path(sys.argv[4])
units = {u["id"] for f in [theme_dir / "units.json", *sorted((theme_dir / "units.d").glob("*.json"))]
         for u in json.loads(f.read_text())["units"]}
def controlled(source):
    out = set()
    for role in catalog["roles"].values():
        for option in role["options"]:
            if option["source"] == source:
                out.add(option["package"])
            extras_source = "pacman" if option["source"] == "official" else option["source"]
            if extras_source == source:
                out.update(option.get("extra_packages", []))
    return out
residual = set()
for key, source in (("hyprland_packages", "pacman"), ("aur_packages", "aur"), ("official_packages", "official")):
    blocked = controlled(source)
    for packages in catalog[key].values():
        residual.update(p for p in packages if p not in blocked)
pending = {"noto-fonts", "rose-pine-cursor", "qalculate-gtk", "ffmpeg"}
# D07 classifies every residual package; a package another domain owns (starship: D05) may
# keep its record in that domain's fragment instead.
others = set()
for fragment in sorted(Path(sys.argv[1]).parent.glob("*.json")):
    if fragment.name != Path(sys.argv[1]).name:
        others.update(json.loads(fragment.read_text()).get("generic_packages", {}))
classified = set(ledger["generic_packages"]) | others
missing = (residual | pending) - classified
extra = classified - residual - pending
assert not missing and not extra, (sorted(missing), sorted(extra))
classes = {"themed-interface", "integrated-action", "backend-dependency", "outside-visual-scope"}
for name, entry in ledger["generic_packages"].items():
    assert entry["class"] in classes and entry["owner"] == "D07" and entry["reason"], name
    for unit in entry.get("theme", {}).get("units", []):
        assert unit in units, (name, unit)
assert ledger["generic_packages"]["sddm"]["theme"]["support"] == "unsupported"
assert all(re.fullmatch(r"E-D07-\d{3}", key) for key in ledger["evidence"])
for name, cap in ledger["capabilities"].items():
    assert cap["domain"] and cap["outcome"] and isinstance(cap["failure_states"], list), name
assert coverage["owner"] == "D07" and all(case["result"] == "not-run" for case in coverage["cases"])
print(f"classified {len(classified)} packages ({len(residual)} catalog residual + {len(pending & classified)} pending additions)")
PY
ok 'every generic catalog package (and the four pending additions) has exactly one D07 classification'
