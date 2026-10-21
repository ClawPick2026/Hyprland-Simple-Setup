#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs and bash -c scripts are single-quoted on purpose.
set -euo pipefail
# F03 renderer assertions (plan F03.6, consuming the F04.2 fixture library): registry and
# token validation, deterministic output, both variants, units.d ordering, selected-member
# coverage, managed-key editing and managed regions. hss_theme.py is pure, so every case runs
# its plan command against temporary copies of the theme directory. Evidence level: static.
# shellcheck source=tests/shell/harmonization_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/harmonization_testlib.sh"
ht_fixture_init

repo_theme="$HT_REPO_ROOT/dotfiles/.config/hypr/theme"

fresh_theme() {
    local dir
    dir=$(mktemp -d "$HT_ROOT/theme.XXXXXX")
    ht_copy_theme "$dir"
    # Core registry only; each case adds the fragments it needs (domain units have their own suites).
    rm -rf -- "$dir/units.d"
    printf '%s\n' "$dir"
}
# jq_edit FILE [JQ_ARG...] FILTER
jq_edit() {
    local file=$1
    shift
    jq "$@" "$file" > "$file.tmp"
    mv -f -- "$file.tmp" "$file"
}
# plan_into THEME HOME STAGING OUT VARIANT [ARG...]
plan_into() {
    local theme=$1 home=$2 staging=$3 out=$4 variant=$5
    shift 5
    python3 -B "$theme/hss_theme.py" plan --variant "$variant" --home "$home" \
        --config-home "$home/.config" --data-home "$home/.local/share" \
        --theme-root "$home/.config/hss-theme" --staging "$staging" --out "$out" "$@"
}
# staged PLAN UNIT TARGET_SUFFIX: path of the staged candidate
staged() {
    jq -er --arg id "$2" --arg suffix "$3" \
        '.units[] | select(.id == $id) | .outputs[] | select(.target | endswith($suffix)) | .staged' "$1"
}
expect_check_failure() {
    local label=$1 message=$2 theme=$3
    ht_run python3 -B "$theme/hss_theme.py" check
    [[ $HT_STATUS -ne 0 ]] || ht_fail "$label: check accepted invalid input"
    assert_contains "$(cat -- "$HT_STDERR")" "$message" "$label error message"
}

# ---------------------------------------------------------------------------
# Repository registry

# Other suites may leave bytecode behind; this suite's own runs must not add or change any.
bytecode_before=$(ht_tree_listing "$repo_theme/__pycache__")
ht_run python3 "$repo_theme/hss_theme.py" check
assert_status 0 "hss_theme.py check"
assert_contains "$(cat -- "$HT_STDOUT")" ", 2 variants" "check summary"
assert_eq "$bytecode_before" "$(ht_tree_listing "$repo_theme/__pycache__")" "bytecode in the theme directory"
ht_ok "hss_theme.py check accepts the repository tokens, registry and templates for both variants"

# ---------------------------------------------------------------------------
# Determinism and variants

theme=$(fresh_theme)
roles="$HT_ROOT/roles.json"
ht_write_roles "$roles"
render_home="$HT_ROOT/render-home"
mkdir -p -- "$render_home/.config"
plan_into "$theme" "$render_home" "$HT_ROOT/stage" "$HT_ROOT/plan-1.json" dark --roles "$roles" --adopt
first=$(ht_tree_listing "$HT_ROOT/stage")
rm -rf -- "$HT_ROOT/stage"
plan_into "$theme" "$render_home" "$HT_ROOT/stage" "$HT_ROOT/plan-2.json" dark --roles "$roles" --adopt
cmp -s -- "$HT_ROOT/plan-1.json" "$HT_ROOT/plan-2.json" || ht_fail "plans differ between identical runs"
assert_eq "$first" "$(ht_tree_listing "$HT_ROOT/stage")" "staged candidates of identical runs"
plan_into "$theme" "$render_home" "$HT_ROOT/stage-elsewhere" "$HT_ROOT/plan-3.json" dark --roles "$roles" --adopt
assert_eq "$first" "$(ht_tree_listing "$HT_ROOT/stage-elsewhere")" "candidates rendered into another staging directory"
if grep -rlF -- "$HT_ROOT/stage" "$HT_ROOT/stage-elsewhere" >/dev/null; then
    ht_fail "a candidate contains a staging path"
fi
[[ -n $first && $first != missing ]] || ht_fail "nothing was rendered"
ht_ok "identical inputs render byte-identical plans and candidates without staging paths"

for variant in dark light; do
    plan_into "$theme" "$render_home" "$HT_ROOT/stage-$variant" "$HT_ROOT/plan-$variant.json" "$variant" --roles "$roles" --adopt
    assert_json "$HT_ROOT/plan-$variant.json" '[.units[] | select(.status != "ready")] == [] and .summary.batch == "complete"' \
        "$variant plan"
    palette=$(staged "$HT_ROOT/plan-$variant.json" theme-core palette.json)
    jq -e . "$palette" >/dev/null || ht_fail "$variant palette.json is not JSON"
    css=$(staged "$HT_ROOT/plan-$variant.json" theme-core palette.css)
    sh_palette=$(staged "$HT_ROOT/plan-$variant.json" theme-core palette.sh)
    bash -n "$sh_palette" || ht_fail "$variant palette.sh is not valid shell"
    gtk3=$(staged "$HT_ROOT/plan-$variant.json" gtk3 settings.ini)
    if [[ $variant == dark ]]; then
        assert_json "$palette" '.variant == "dark" and .is_dark == true and .color.bg == "#1e1e2e" and .color.accent == "#89b4fa"'
        grep -Fq '@define-color hss_bg #1e1e2e;' "$css" || ht_fail "dark palette.css"
        grep -qx 'gtk-application-prefer-dark-theme=1' "$gtk3" || ht_fail "dark GTK preference"
    else
        assert_json "$palette" '.variant == "light" and .is_dark == false and .color.bg == "#eff1f5" and .color.accent == "#1e66f5"'
        grep -Fq '@define-color hss_bg #eff1f5;' "$css" || ht_fail "light palette.css"
        grep -qx 'gtk-application-prefer-dark-theme=0' "$gtk3" || ht_fail "light GTK preference"
    fi
    grep -qx 'gtk-cursor-theme-name=BreezeX-RosePine-Linux' "$gtk3" || ht_fail "$variant cursor theme"
done
ht_ok "dark renders Catppuccin Mocha and light renders Catppuccin Latte with valid core outputs"

# ---------------------------------------------------------------------------
# Rejected tokens, templates and registries

theme=$(fresh_theme)
printf '{{ color.nonexistent }}\n' >> "$theme/templates/core/palette.sh.tmpl"
expect_check_failure "unknown token" "unknown token 'color.nonexistent'" "$theme"
theme=$(fresh_theme)
printf '{{ color.bg | sparkle }}\n' >> "$theme/templates/core/palette.sh.tmpl"
expect_check_failure "unknown filter" "unknown filter 'sparkle'" "$theme"
theme=$(fresh_theme)
printf '{{ color.bg \n' >> "$theme/templates/core/palette.sh.tmpl"
expect_check_failure "unclosed placeholder" "unbalanced template braces" "$theme"
theme=$(fresh_theme)
printf 'color.bg }}\n' >> "$theme/templates/core/palette.css.tmpl"
expect_check_failure "stray closing braces" "unbalanced template braces" "$theme"
for color in '#1e1e2' blue '#1e1e2eff' ''; do
    theme=$(fresh_theme)
    jq_edit "$theme/tokens.json" --arg c "$color" '.palettes.mocha.base = $c'
    expect_check_failure "bad color [$color]" "invalid color" "$theme"
done
theme=$(fresh_theme)
jq_edit "$theme/tokens.json" 'del(.variants.light.assets.btop_theme)'
expect_check_failure "mismatched variant keys" "same token keys" "$theme"
theme=$(fresh_theme)
jq_edit "$theme/tokens.json" '.variants.light.color.accent = "@nonexistent"'
expect_check_failure "unknown palette reference" "unknown palette reference" "$theme"
ht_ok "unknown tokens and filters, unbalanced braces, bad colors and mismatched variants are rejected"

for target in 'theme:../escape.conf' 'config:gtk-3.0/../../escape' 'config:/etc/passwd' 'config:~/x' 'home:~user/x' \
    '/etc/passwd' 'gtk-3.0/settings.ini' 'config:' 'state:x'; do
    theme=$(fresh_theme)
    jq_edit "$theme/units.json" --arg t "$target" '.units[0].outputs[0].target = $t'
    expect_check_failure "unsafe target [$target]" "target" "$theme"
    grep -Eq 'unsafe target|target must start with' "$HT_STDERR" || ht_fail "unsafe target [$target] message"
done
theme=$(fresh_theme)
jq_edit "$theme/units.json" '.units += [{"id": "dup", "owner": "F04", "applies": {"always": true},
    "outputs": [{"target": "theme:generated/palette.json", "class": "generated", "template": "core/palette.json.tmpl"}]}]'
expect_check_failure "duplicate whole-file target" "is also owned by theme-core" "$theme"
theme=$(fresh_theme)
jq_edit "$theme/units.json" '.units += [{"id": "dup", "owner": "F04", "applies": {"always": true},
    "outputs": [{"target": "config:gtk-3.0/gtk.css", "class": "generated", "template": "core/palette.css.tmpl"}]}]'
expect_check_failure "generated file over a managed region" "config:gtk-3.0/gtk.css" "$theme"
theme=$(fresh_theme)
jq_edit "$theme/units.json" '(.units[] | select(.id == "theme-core") | .depends) = ["qt5ct"]'
expect_check_failure "dependency cycle" "dependency cycle" "$theme"
theme=$(fresh_theme)
jq_edit "$theme/units.json" '(.units[] | select(.id == "gtk3") | .depends) = ["theme-core", "nope"]'
expect_check_failure "unknown dependency" "depends on unknown unit nope" "$theme"
theme=$(fresh_theme)
jq_edit "$theme/units.json" '.units[1].id = "theme-core"'
expect_check_failure "duplicate unit id" "duplicate unit id" "$theme"
theme=$(fresh_theme)
jq_edit "$theme/units.json" '.units[0].activation = [{"kind": "signal", "process": "kitty -9", "signal": "USR1"}]'
expect_check_failure "inexact signal process" "exact process name" "$theme"
theme=$(fresh_theme)
jq_edit "$theme/units.json" '.units[0].activation = [{"kind": "exec", "argv": ["sh", "-c", "x"]}]'
expect_check_failure "unknown activation kind" "unknown activation kind" "$theme"
theme=$(fresh_theme)
mkdir -p -- "$theme/units.d"
printf '{"schema_version": 2, "units": []}\n' > "$theme/units.d/50-future.json"
expect_check_failure "future fragment schema" "unsupported registry schema 2 in 50-future.json" "$theme"
ht_ok "unsafe, duplicate and colliding targets, cycles, unknown dependencies and unsafe activations are rejected"

# ---------------------------------------------------------------------------
# units.d fragments and selected members

theme=$(fresh_theme)
mkdir -p -- "$theme/units.d" "$theme/templates/fx"
printf 'member {{variant}}\n' > "$theme/templates/fx/member.tmpl"
member_unit() {
    jq -cn --arg id "$1" --argjson members "$2" --argjson depends "${3:-[\"theme-core\"]}" \
        '{id: $id, owner: "F04", description: "fixture", applies: {members: $members}, depends: $depends,
          outputs: [{target: ("theme:generated/fx/" + $id + ".conf"), class: "generated", template: "fx/member.tmpl"}],
          activation: []}'
}
# Written in reverse name order to show that loading follows names, not creation order.
jq -n --argjson a "$(member_unit fx-alpha '["terminal/kitty"]' '["fx-zulu"]')" \
    --argjson b "$(member_unit fx-foot '["terminal/foot"]')" \
    --argjson c "$(member_unit fx-alacritty '["terminal/alacritty"]')" \
    '{schema_version: 1, units: [$a, $b, $c]}' > "$theme/units.d/20-later.json"
jq -n --argjson a "$(member_unit fx-zulu '["terminal/kitty", "terminal/foot"]')" \
    --argjson b "$(member_unit fx-agent '["agent/pi", "agent/opencode", "agent/claude-code"]')" \
    --argjson c "$(member_unit fx-dock '["dock/nwg-dock-hyprland", "dock/nwg-panel"]')" \
    --argjson d "$(member_unit fx-tui-fm '["tui_file_manager/yazi", "tui_file_manager/lf"]')" \
    --argjson e "$(member_unit fx-gui-editor '["gui_editor/kate", "gui_editor/zed"]')" \
    '{schema_version: 1, units: [$a, $b, $c, $d, $e]}' > "$theme/units.d/10-earlier.json"
python3 -B "$theme/hss_theme.py" check >/dev/null || ht_fail "fixture fragments were rejected"
ht_write_roles "$HT_ROOT/members.json" terminal=kitty,foot agent= dock= tui_file_manager= gui_editor=
plan_into "$theme" "$render_home" "$HT_ROOT/stage-members" "$HT_ROOT/plan-members.json" dark \
    --roles "$HT_ROOT/members.json" --adopt
core_ids=$(jq -c '[.units[].id]' "$theme/units.json")
assert_json "$HT_ROOT/plan-members.json" "[.units[].id] == ($core_ids + [\"fx-zulu\",\"fx-agent\",\"fx-dock\",\"fx-tui-fm\",\"fx-gui-editor\",\"fx-alpha\",\"fx-foot\",\"fx-alacritty\"])" \
    "units.json then units.d fragments in name order"
assert_json "$HT_ROOT/plan-members.json" '[.units[] | select(.id | startswith("fx-")) | {(.id): .status}] | add == {
    "fx-zulu": "ready", "fx-alpha": "ready", "fx-foot": "ready", "fx-alacritty": "not-selected",
    "fx-agent": "not-selected", "fx-dock": "not-selected", "fx-tui-fm": "not-selected", "fx-gui-editor": "not-selected"}' \
    "member unit statuses"
assert_json "$HT_ROOT/plan-members.json" '[.units[] | select(.status == "not-selected") | .outputs | length] | all(. == 0)' \
    "not-selected units render nothing"
ht_write_roles "$HT_ROOT/members-2.json" terminal=foot agent=opencode dock=nwg-panel tui_file_manager=lf gui_editor=zed,kate
plan_into "$theme" "$render_home" "$HT_ROOT/stage-members-2" "$HT_ROOT/plan-members-2.json" dark \
    --roles "$HT_ROOT/members-2.json" --adopt
assert_json "$HT_ROOT/plan-members-2.json" '[.units[] | select(.id | startswith("fx-")) | {(.id): .status}] | add == {
    "fx-zulu": "ready", "fx-alpha": "not-selected", "fx-foot": "ready", "fx-alacritty": "not-selected",
    "fx-agent": "ready", "fx-dock": "ready", "fx-tui-fm": "ready", "fx-gui-editor": "ready"}' \
    "member unit statuses after switching selections"
ht_ok "units.d fragments load in name order; member units follow every selected member and None selects none"

# Without roles data no member unit applies; global units still do.
plan_into "$theme" "$render_home" "$HT_ROOT/stage-no-roles" "$HT_ROOT/plan-no-roles.json" dark --adopt
assert_json "$HT_ROOT/plan-no-roles.json" '[.units[] | select(.id | startswith("fx-")) | .status] | all(. == "not-selected")'
assert_json "$HT_ROOT/plan-no-roles.json" '[.units[] | select(.id == "theme-core") | .status] == ["ready"]'
ht_ok "missing roles data selects no member units"

# ---------------------------------------------------------------------------
# Dependency skips propagate through chains in any registry order

theme=$(fresh_theme)
mkdir -p -- "$theme/units.d" "$theme/templates/fx"
printf 'chain {{variant}}\n' > "$theme/templates/fx/chain.tmpl"
chain_unit() {
    jq -cn --arg id "$1" --argjson depends "$2" \
        '{id: $id, owner: "F04", description: "fixture", applies: {always: true}, depends: $depends,
          outputs: [{target: ("config:fx/" + $id + ".conf"), class: "generated", template: "fx/chain.tmpl"}],
          activation: []}'
}
# fx-top -> fx-middle -> fx-base, listed dependents first; fx-base will conflict.
jq -n --argjson a "$(chain_unit fx-top '["fx-middle"]')" --argjson b "$(chain_unit fx-middle '["fx-base"]')" \
    --argjson c "$(chain_unit fx-base '["theme-core"]')" --argjson d "$(chain_unit fx-independent '["theme-core"]')" \
    '{schema_version: 1, units: [$a, $b, $c, $d]}' > "$theme/units.d/10-chain.json"
chain_home="$HT_ROOT/chain-home"
mkdir -p -- "$chain_home/.config/fx"
printf 'user-owned file\n' > "$chain_home/.config/fx/fx-base.conf"
plan_into "$theme" "$chain_home" "$HT_ROOT/stage-chain" "$HT_ROOT/plan-chain.json" dark
assert_json "$HT_ROOT/plan-chain.json" '[.units[] | select(.id | startswith("fx-")) | {(.id): .status}] | add == {
    "fx-top": "skipped-dependency", "fx-middle": "skipped-dependency", "fx-base": "skipped-conflict",
    "fx-independent": "ready"}' "transitive dependency skips"
assert_json "$HT_ROOT/plan-chain.json" '. as $plan | [range(0; .units | length) as $i | .units[$i] as $unit
    | $unit.depends[] as $dep | ([range(0; $i) as $j | $plan.units[$j].id] | index($dep))] | all(. != null)' \
    "every unit is planned after its dependencies"
ht_ok "a conflict skips every transitive dependent, even when dependents are registered first"

# ---------------------------------------------------------------------------
# Managed keys: comments, order, unrelated keys and bracketed section names

theme=$(fresh_theme)
mkdir -p -- "$theme/units.d" "$theme/templates/fx"
cat > "$theme/templates/fx/kde-keys.ini.tmpl" <<'TEMPLATE'
# Managed KConfig keys; nested groups use the [Group][Subgroup] header form.
[Colors:Header][Inactive]
DecorationFocus={{color.focus | kde_rgb}}
TEMPLATE
cat > "$theme/units.d/10-keys.json" <<'JSON'
{
  "schema_version": 1,
  "units": [
    {"id": "fx-ini", "owner": "F04", "description": "fixture", "applies": {"always": true}, "depends": ["theme-core"],
     "outputs": [{"target": "config:fx/app.ini", "class": "managed-keys", "format": "ini", "validator": "ini",
       "keys_template": "fx/kde-keys.ini.tmpl",
       "keys": [
         {"section": "General", "key": "theme", "value": "{{variant}}"},
         {"section": "General", "key": "newkey", "value": "added"},
         {"section": "Colors:Header", "key": "BackgroundNormal", "value": "{{color.bg | kde_rgb}}"},
         {"section": "Colors:Header][Inactive", "key": "BackgroundNormal", "value": "9,9,9"},
         {"section": "Colors:Header[Inactive]", "key": "BackgroundNormal", "value": "8,8,8"},
         {"section": "NewSection", "key": "key", "value": "value"}
       ]}],
     "activation": []},
    {"id": "fx-kv", "owner": "F04", "description": "fixture", "applies": {"always": true}, "depends": ["theme-core"],
     "outputs": [{"target": "config:fx/app.conf", "class": "managed-keys", "format": "kv",
       "keys": [{"key": "color", "value": "{{color.accent}}"}, {"key": "added", "value": "yes"}]}],
     "activation": []},
    {"id": "fx-toml", "owner": "F04", "description": "fixture", "applies": {"always": true}, "depends": ["theme-core"],
     "outputs": [{"target": "config:fx/app.toml", "class": "managed-keys", "format": "toml", "validator": "toml",
       "keys": [{"key": "theme", "value": "{{variant | toml}}"}, {"key": "font", "value": "{{font.mono_family | toml}}"}]}],
     "activation": []}
  ]
}
JSON
keys_home="$HT_ROOT/keys-home"
mkdir -p -- "$keys_home/.config/fx"
cat > "$keys_home/.config/fx/app.ini" <<'INI'
; leading comment
[General]
# keep this comment
unrelated=1
theme=Old
other = spaced value

[Colors:Header]
BackgroundNormal=1,1,1
Keep=yes

[Colors:Header][Inactive]
BackgroundNormal=2,2,2
DecorationFocus=0,0,0

[Colors:Header[Inactive]]
BackgroundNormal=3,3,3

[Tail]
last=1
INI
cat > "$keys_home/.config/fx/app.conf" <<'KV'
# kv comment
alpha=1
color=old
beta = 2
KV
cat > "$keys_home/.config/fx/app.toml" <<'TOML'
# toml comment
title = "x"
theme = "old"

[table]
theme = "inside a table stays untouched"
TOML
plan_into "$theme" "$keys_home" "$HT_ROOT/stage-keys" "$HT_ROOT/plan-keys.json" dark --adopt
assert_json "$HT_ROOT/plan-keys.json" '[.units[] | select(.id | startswith("fx-")) | .status] | all(. == "ready")' "managed-key plan"
cat > "$HT_ROOT/expected.ini" <<'INI'
; leading comment
[General]
# keep this comment
unrelated=1
theme=dark
other = spaced value
newkey=added

[Colors:Header]
BackgroundNormal=30,30,46
Keep=yes

[Colors:Header][Inactive]
BackgroundNormal=9,9,9
DecorationFocus=137,180,250

[Colors:Header[Inactive]]
BackgroundNormal=8,8,8

[Tail]
last=1

[NewSection]
key=value
INI
diff -u -- "$HT_ROOT/expected.ini" "$(staged "$HT_ROOT/plan-keys.json" fx-ini app.ini)" >&2 || ht_fail "INI managed keys"
cat > "$HT_ROOT/expected.conf" <<'KV'
# kv comment
alpha=1
color=#89b4fa
beta = 2
added=yes
KV
diff -u -- "$HT_ROOT/expected.conf" "$(staged "$HT_ROOT/plan-keys.json" fx-kv app.conf)" >&2 || ht_fail "kv managed keys"
cat > "$HT_ROOT/expected.toml" <<'TOML'
# toml comment
title = "x"
theme = "dark"

font = "JetBrainsMono Nerd Font"

[table]
theme = "inside a table stays untouched"
TOML
diff -u -- "$HT_ROOT/expected.toml" "$(staged "$HT_ROOT/plan-keys.json" fx-toml app.toml)" >&2 || ht_fail "TOML managed keys"
ht_ok "managed keys change only listed keys and keep comments, order, unrelated keys, tables and bracketed sections"

# ---------------------------------------------------------------------------
# Managed regions for every comment style

theme=$(fresh_theme)
mkdir -p -- "$theme/units.d"
styles=('#' '//' '--' ';' '"' '/* */' '<!-- -->')
styles_json=$(printf '%s\n' "${styles[@]}" | jq -R . | jq -cs .)
jq -n --argjson styles "$styles_json" '{schema_version: 1, units: ([range(0; $styles | length) as $i
    | {id: "fx-region-\($i)", owner: "F04", description: "fixture", applies: {always: true}, depends: ["theme-core"],
       outputs: [{target: "config:fx/region-\($i).txt", class: "managed-region", comment: $styles[$i],
                  position: "append", content: "body {{variant}}\nsecond {{color.bg}}"}], activation: []}]
    + [{id: "fx-prepend", owner: "F04", description: "fixture", applies: {always: true}, depends: ["theme-core"],
        outputs: [{target: "config:fx/prepend.txt", class: "managed-region", comment: "#", position: "prepend",
                   content: "first {{variant}}"}], activation: []}])}' > "$theme/units.d/10-regions.json"
assert_json "$theme/units.d/10-regions.json" "[.units[].outputs[0].comment] == ($styles_json + [\"#\"])" "region fixture styles"
python3 -B "$theme/hss_theme.py" check >/dev/null || ht_fail "region fixture registry was rejected"
markers() {
    local open=$1 close="" unit=$2
    case "$open" in
        '/* */') open='/*'; close=' */' ;;
        '<!-- -->') open='<!--'; close=' -->' ;;
    esac
    printf '%s >>> hss-theme:%s >>>%s\n%s <<< hss-theme:%s <<<%s\n' "$open" "$unit" "$close" "$open" "$unit" "$close"
}
append_home="$HT_ROOT/append-home"
replace_home="$HT_ROOT/replace-home"
mkdir -p -- "$append_home/.config/fx" "$replace_home/.config/fx"
for i in "${!styles[@]}"; do
    mapfile -t marker < <(markers "${styles[$i]}" "fx-region-$i")
    printf 'user line 1\nuser line 2\n' > "$append_home/.config/fx/region-$i.txt"
    printf 'before region\n%s\nold body\n%s\nafter region\n' "${marker[0]}" "${marker[1]}" > "$replace_home/.config/fx/region-$i.txt"
done
printf 'user first\n' > "$append_home/.config/fx/prepend.txt"
printf 'user first\n' > "$replace_home/.config/fx/prepend.txt"
plan_into "$theme" "$append_home" "$HT_ROOT/stage-append" "$HT_ROOT/plan-append.json" dark --adopt
plan_into "$theme" "$replace_home" "$HT_ROOT/stage-replace" "$HT_ROOT/plan-replace.json" light
for i in "${!styles[@]}"; do
    mapfile -t marker < <(markers "${styles[$i]}" "fx-region-$i")
    printf 'user line 1\nuser line 2\n\n%s\nbody dark\nsecond #1e1e2e\n%s\n' "${marker[0]}" "${marker[1]}" > "$HT_ROOT/expected-region"
    diff -u -- "$HT_ROOT/expected-region" "$(staged "$HT_ROOT/plan-append.json" "fx-region-$i" "region-$i.txt")" >&2 \
        || ht_fail "region insertion with comment style [${styles[$i]}]"
    printf 'before region\n%s\nbody light\nsecond #eff1f5\n%s\nafter region\n' "${marker[0]}" "${marker[1]}" > "$HT_ROOT/expected-region"
    diff -u -- "$HT_ROOT/expected-region" "$(staged "$HT_ROOT/plan-replace.json" "fx-region-$i" "region-$i.txt")" >&2 \
        || ht_fail "region replacement with comment style [${styles[$i]}]"
done
printf '# >>> hss-theme:fx-prepend >>>\nfirst dark\n# <<< hss-theme:fx-prepend <<<\nuser first\n' > "$HT_ROOT/expected-region"
diff -u -- "$HT_ROOT/expected-region" "$(staged "$HT_ROOT/plan-append.json" fx-prepend prepend.txt)" >&2 \
    || ht_fail "prepended region"
assert_json "$HT_ROOT/plan-replace.json" '[.units[] | select(.id == "fx-prepend") | .status] == ["not-adopted"]' \
    "region insertion without adoption"
ht_ok "managed regions are appended, prepended and replaced in place for all seven comment styles"
