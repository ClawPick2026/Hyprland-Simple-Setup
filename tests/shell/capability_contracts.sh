#!/usr/bin/env bash
set -euo pipefail

# Capability ledger contract (plan F01): capabilities.json plus capabilities.d/*.json
# form one ledger that covers every role option, None state and generic catalog
# package exactly once, uses the documented vocabulary and cites real evidence.
# The Rust reader (src/capabilities.rs) enforces the same rules for the installer.

unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

for command in python3 jq grep; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

# Validates ROOT/capabilities.json and ROOT/capabilities.d/*.json against
# ROOT/packages.json. On success prints counts on the first line and then one
# action ID per line; on failure prints every error to stderr and exits 1.
read -r -d '' ledger_validator <<'PY' || true
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
errors = []

VOCABULARY = {
    "option_support": {"full", "limited", "unverified"},
    "capability_support": {"supported", "partial", "unsupported", "unverified", "not-applicable"},
    "mechanism": {"native-cli", "native-config", "native-api", "native-ui", "none"},
    "family": {"gtk3", "gtk4", "libadwaita", "qt5", "qt6", "kde", "electron", "custom", "tui", "cli"},
    "startup": {"on-demand", "daemon", "dbus-activated", "session-service", "terminal"},
    "evidence_kind": {"documentation", "static", "argv", "modeled-effect", "real-effect", "visual"},
    "requirement": {"required", "optional"},
    "failure_state": {"failed", "usage", "cancelled", "disabled", "unsupported",
                      "missing-dependency", "unavailable", "timeout", "denied", "conflict"},
    "generic_class": {"themed-interface", "integrated-action", "backend-dependency",
                      "outside-visual-scope"},
}
DOTTED = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")
SEGMENT = re.compile(r"^[a-z][a-z0-9_]*$")
OWNER = re.compile(r"^[A-Z][0-9]{2}$")
DATE = re.compile(r"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$")
UNIT = re.compile(r"^[a-z0-9._-]+$")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


class DuplicateKey(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKey(f"duplicate key {key!r}")
        result[key] = value
    return result


def load(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except FileNotFoundError:
        errors.append(f"{path.relative_to(root)} is missing")
    except (ValueError, UnicodeDecodeError) as error:
        errors.append(f"{path.relative_to(root)}: {error}")
    return None


def text(where, value, required=True):
    if not isinstance(value, str):
        errors.append(f"{where} must be a string")
    elif required and not value.strip():
        errors.append(f"{where} must not be empty")
    elif CONTROL.search(value):
        errors.append(f"{where} must not contain control characters")


def keys(where, value, required, optional=()):
    if not isinstance(value, dict):
        errors.append(f"{where} must be an object")
        return False
    missing = sorted(set(required) - set(value))
    unknown = sorted(set(value) - set(required) - set(optional))
    if missing:
        errors.append(f"{where} is missing field(s): {', '.join(missing)}")
    if unknown:
        errors.append(f"{where} has unknown field(s): {', '.join(unknown)}")
    return not missing


def vocab(where, kind, value):
    if value not in VOCABULARY[kind]:
        errors.append(f"{where}: unknown {kind} {value!r}")


def string_list(where, value):
    if not isinstance(value, list):
        errors.append(f"{where} must be a list")
        return []
    for index, item in enumerate(value):
        text(f"{where}[{index}]", item)
    return [item for item in value if isinstance(item, str)]


catalog = load(root / "packages.json")
base = load(root / "capabilities.json")
if catalog is None or base is None:
    sys.exit("\n".join(errors))

if keys("capabilities.json", base, ["schema_version", "description", "vocabulary", "identifiers", "fragments"]):
    if base["schema_version"] != 1:
        errors.append(f"capabilities.json schema_version {base['schema_version']!r} is not supported")
    if base["fragments"] != "capabilities.d/*.json":
        errors.append("capabilities.json fragments must be 'capabilities.d/*.json'")
    text("capabilities.json description", base["description"])
    if keys("capabilities.json vocabulary", base["vocabulary"], list(VOCABULARY)):
        for kind, expected in VOCABULARY.items():
            documented = base["vocabulary"][kind]
            if not isinstance(documented, dict) or set(documented) != expected:
                errors.append(f"capabilities.json vocabulary.{kind} must document exactly: {', '.join(sorted(expected))}")
                continue
            for value, doc in documented.items():
                text(f"capabilities.json vocabulary.{kind}.{value}", doc)
    if isinstance(base["identifiers"], dict):
        for name, doc in base["identifiers"].items():
            text(f"capabilities.json identifiers.{name}", doc)
    else:
        errors.append("capabilities.json identifiers must be an object")

merged = {kind: {} for kind in ("capabilities", "options", "none_states", "generic_packages", "evidence")}
origin = {}
owners = {}
fragment_dir = root / "capabilities.d"
fragment_paths = sorted(
    path for path in (fragment_dir.iterdir() if fragment_dir.is_dir() else [])
    if path.name.endswith(".json") and not path.name.startswith(".")
)
for path in fragment_paths:
    name = f"capabilities.d/{path.name}"
    fragment = load(path)
    if fragment is None:
        continue
    if not keys(name, fragment, ["schema_version", "owner"], list(merged)):
        continue
    if fragment["schema_version"] != 1:
        errors.append(f"{name}: schema_version {fragment['schema_version']!r} is not supported")
    owner = fragment["owner"]
    if not isinstance(owner, str) or not OWNER.match(owner):
        errors.append(f"{name}: owner {owner!r} must look like D03 or F01")
        continue
    if owner in owners:
        errors.append(f"fragment owner {owner} is defined in both {owners[owner]} and {name}")
    owners[owner] = name
    for kind in merged:
        section = fragment.get(kind, {})
        if not isinstance(section, dict):
            errors.append(f"{name}: {kind} must be an object")
            continue
        for key, value in section.items():
            if key in merged[kind]:
                errors.append(f"{kind} {key} is defined in both {origin[(kind, key)]} and {name}")
                continue
            merged[kind][key] = value
            origin[(kind, key)] = name
            where = f"{name}: {kind}.{key}"
            if kind == "evidence":
                match = re.fullmatch(r"E-([A-Z][0-9]{2})-([0-9]{3})", key)
                if not match or match.group(1) != owner:
                    errors.append(f"{where}: evidence IDs in this fragment must look like E-{owner}-001")
                if keys(where, value, ["kind", "source", "date", "result"], ["environment", "command"]):
                    vocab(where, "evidence_kind", value["kind"])
                    for field in ("source", "result"):
                        text(f"{where}.{field}", value[field])
                    for field in ("environment", "command"):
                        text(f"{where}.{field}", value.get(field, ""), required=False)
                    if not isinstance(value["date"], str) or not DATE.match(value["date"]):
                        errors.append(f"{where}: date {value['date']!r} must be YYYY-MM-DD")
                    if value["kind"] in ("real-effect", "visual") and not str(value.get("environment", "")).strip():
                        errors.append(f"{where}: {value['kind']} evidence must record its environment")
                    if value["kind"] in ("real-effect", "argv", "modeled-effect") and not str(value.get("command", "")).strip():
                        errors.append(f"{where}: {value['kind']} evidence must record its command")
            elif kind == "capabilities":
                if not DOTTED.match(key):
                    errors.append(f"{where}: capability IDs must match <domain>.<name> in lowercase")
                if keys(where, value, ["domain", "requirement", "outcome", "failure_states"], ["actions"]):
                    domain = value["domain"]
                    if not isinstance(domain, str) or not SEGMENT.match(domain) or not key.startswith(domain + "."):
                        errors.append(f"{where}: domain {domain!r} must be the first segment of the capability ID")
                    vocab(where, "requirement", value["requirement"])
                    text(f"{where}.outcome", value["outcome"])
                    states = value["failure_states"]
                    if not isinstance(states, list) or not states:
                        errors.append(f"{where}: failure_states must list at least one outcome")
                    else:
                        for state in states:
                            vocab(where, "failure_state", state)
                        if len(states) != len(set(map(str, states))):
                            errors.append(f"{where}: failure_states contains duplicates")
                    actions = value.get("actions", [])
                    if not isinstance(actions, list):
                        errors.append(f"{where}: actions must be a list")
                    else:
                        for action in actions:
                            if not isinstance(action, str) or not DOTTED.match(action):
                                errors.append(f"{where}: action {action!r} must match ^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$")
                        if len(actions) != len(set(map(str, actions))):
                            errors.append(f"{where}: actions contains duplicates")
            elif kind == "options":
                if keys(where, value, ["support", "summary", "family", "startup", "data_boundary"],
                        ["limitations", "capabilities", "theme"]):
                    vocab(where, "option_support", value["support"])
                    vocab(where, "family", value["family"])
                    vocab(where, "startup", value["startup"])
                    text(f"{where}.summary", value["summary"])
                    if isinstance(value["summary"], str) and len(value["summary"]) > 160:
                        errors.append(f"{where}: summary is longer than 160 characters")
                    text(f"{where}.data_boundary", value["data_boundary"])
                    string_list(f"{where}.limitations", value.get("limitations", []))
                    caps = value.get("capabilities", {})
                    if not isinstance(caps, dict):
                        errors.append(f"{where}: capabilities must be an object")
                    else:
                        for cap_id, record in caps.items():
                            cap_where = f"{where}.capabilities.{cap_id}"
                            if not keys(cap_where, record, ["support", "mechanism"], ["evidence", "note"]):
                                continue
                            vocab(cap_where, "capability_support", record["support"])
                            vocab(cap_where, "mechanism", record["mechanism"])
                            string_list(f"{cap_where}.evidence", record.get("evidence", []))
                            text(f"{cap_where}.note", record.get("note", ""), required=False)
                            if record["support"] in ("supported", "partial"):
                                if not record.get("evidence"):
                                    errors.append(f"{cap_where}: marked {record['support']} without evidence")
                                if record["mechanism"] == "none":
                                    errors.append(f"{cap_where}: marked {record['support']} without a native mechanism")
                            if record["support"] in ("partial", "unsupported") and not str(record.get("note", "")).strip():
                                errors.append(f"{cap_where}: marked {record['support']} without an explanatory note")
                    theme = value.get("theme")
                    if theme is not None and keys(f"{where}.theme", theme, ["support"], ["units", "note"]):
                        vocab(f"{where}.theme", "capability_support", theme["support"])
                        text(f"{where}.theme.note", theme.get("note", ""), required=False)
                        for unit in string_list(f"{where}.theme.units", theme.get("units", [])):
                            if not UNIT.match(unit):
                                errors.append(f"{where}: theme unit {unit!r} is not a valid unit ID")
            elif kind == "none_states":
                if keys(where, value, ["behavior", "theme"]):
                    text(f"{where}.behavior", value["behavior"])
                    text(f"{where}.theme", value["theme"])
            elif kind == "generic_packages":
                if keys(where, value, ["class", "owner", "reason"], ["theme"]):
                    vocab(where, "generic_class", value["class"])
                    if not isinstance(value["owner"], str) or not OWNER.match(value["owner"]):
                        errors.append(f"{where}: owner {value['owner']!r} must look like D07")
                    text(f"{where}.reason", value["reason"])
                    theme = value.get("theme")
                    if theme is not None and value["class"] != "themed-interface":
                        errors.append(f"{where}: theme is only valid for themed-interface packages")
                    if theme is not None and keys(f"{where}.theme", theme, ["support"], ["units", "note"]):
                        vocab(f"{where}.theme", "capability_support", theme["support"])
                        text(f"{where}.theme.note", theme.get("note", ""), required=False)
                        for unit in string_list(f"{where}.theme.units", theme.get("units", [])):
                            if not UNIT.match(unit):
                                errors.append(f"{where}: theme unit {unit!r} is not a valid unit ID")

# References and support-label consistency.
for option_id, option in merged["options"].items():
    if not isinstance(option, dict) or not isinstance(option.get("capabilities", {}), dict):
        continue
    where = f"{origin[('options', option_id)]}: option {option_id}"
    caps = option.get("capabilities", {})
    theme = option.get("theme") if isinstance(option.get("theme"), dict) else {}
    gap = theme.get("support") in ("unsupported", "partial")
    for cap_id, record in caps.items():
        if not isinstance(record, dict):
            continue
        definition = merged["capabilities"].get(cap_id)
        if not isinstance(definition, dict):
            errors.append(f"{where}: capability {cap_id} is not defined by any fragment")
            continue
        for evidence_id in record.get("evidence", []) if isinstance(record.get("evidence", []), list) else []:
            if evidence_id not in merged["evidence"]:
                errors.append(f"{where}: capability {cap_id} cites undefined evidence {evidence_id}")
        if definition.get("requirement") != "required":
            continue
        if option.get("support") == "full" and record.get("support") not in ("supported", "not-applicable"):
            errors.append(f"{where}: full support conflicts with required capability {cap_id} marked {record.get('support')}")
        if record.get("support") in ("unsupported", "partial"):
            gap = True
    if option.get("support") == "full":
        if not caps:
            errors.append(f"{where}: full support needs at least one capability record")
        elif theme.get("support") in ("unsupported", "partial"):
            errors.append(f"{where}: full support conflicts with an unsupported or partial theme")
    if option.get("support") == "limited":
        if not gap:
            errors.append(f"{where}: limited support needs a required capability or the theme marked unsupported or partial")
        elif not option.get("limitations"):
            errors.append(f"{where}: limited support needs at least one user-facing limitation")

# Exact coverage of the catalog.
roles = catalog["roles"]
expected_options = {f"{role}/{option['package']}" for role, definition in roles.items() for option in definition["options"]}
expected_none = {role for role, definition in roles.items() if not definition["required"]}
controlled = {package for definition in roles.values() for option in definition["options"]
              for package in [option["package"], *option.get("extra_packages", [])]}
expected_generic = {package for source in ("hyprland_packages", "aur_packages", "official_packages")
                    for packages in catalog[source].values() for package in packages if package not in controlled}
for kind, label, expected in (("options", "role options", expected_options),
                              ("none_states", "None states", expected_none),
                              ("generic_packages", "generic packages", expected_generic)):
    actual = set(merged[kind])
    if expected - actual:
        errors.append(f"capability ledger is missing {label}: {', '.join(sorted(expected - actual))}")
    if actual - expected:
        errors.append(f"capability ledger defines unknown {label}: {', '.join(sorted(actual - expected))}")

if errors:
    sys.exit("\n".join(errors))
print(f"{len(merged['options'])} {len(merged['none_states'])} {len(merged['generic_packages'])} "
      f"{len(merged['capabilities'])} {len(merged['evidence'])}")
for definition in merged["capabilities"].values():
    for action in definition.get("actions", []):
        print(action)
PY

# validate_ledger ROOT: runs the validator, then checks that every action handled by
# an existing provider file defines its hss_action_* function. Output goes to
# $fixture/last.out and $fixture/last.err.
validate_ledger() {
  local root=$1 action domain provider handler counts
  local -a actions=()
  if ! python3 -I -c "$ledger_validator" "$root" >"$fixture/last.out" 2>"$fixture/last.err"; then
    return 1
  fi
  mapfile -t actions < <(tail -n +2 "$fixture/last.out")
  counts=$(head -n 1 "$fixture/last.out")
  for action in "${actions[@]}"; do
    domain=${action%%.*}
    provider="$root/dotfiles/.config/hypr/scripts/providers/$domain.sh"
    handler="hss_action_${action//./_}"
    [[ -f $provider ]] || continue
    if ! grep -Eq "^[[:space:]]*(function[[:space:]]+)?${handler}[[:space:]]*(\(\)|\{|$)" "$provider"; then
      printf 'action %s has no %s in providers/%s.sh\n' "$action" "$handler" "$domain" >"$fixture/last.err"
      return 1
    fi
  done
  printf '%s\n' "$counts" >"$fixture/last.counts"
}

# Shipped ledger.
validate_ledger "$repo_root" || {
  cat -- "$fixture/last.err" >&2
  fail 'shipped capability ledger is valid'
}
read -r option_count none_count generic_count _ <"$fixture/last.counts"
expected_generic=$(jq '
  [.roles[].options[] | .package, (.extra_packages[]?)] as $controlled
  | [(.hyprland_packages, .aur_packages, .official_packages)[][]
     | select(. as $package | $controlled | index($package) | not)] | unique | length
' "$repo_root/packages.json")
[[ $option_count == 73 && $none_count == 4 && $generic_count == "$expected_generic" ]] ||
  fail "ledger covers 73 role options, 4 None states and $expected_generic generic packages (got $option_count/$none_count/$generic_count)"
printf 'ok - shipped ledger covers 73 role options, 4 None states and %s generic packages exactly once\n' "$generic_count"

for package in noto-fonts rose-pine-cursor qalculate-gtk ffmpeg; do
  jq -e --arg package "$package" '.generic_packages[$package].class' \
    "$repo_root/capabilities.d/d07-session-auxiliary.json" >/dev/null ||
    fail "catalog addition $package is classified"
done
printf 'ok - approved catalog additions are classified as generic packages\n'

# Negative and positive fixtures operate on private copies.
make_copy() {
  local copy=$fixture/$1
  rm -rf -- "$copy"
  mkdir -p -- "$copy/dotfiles/.config/hypr/scripts/providers"
  cp -- "$repo_root/packages.json" "$repo_root/capabilities.json" "$copy/"
  cp -R -- "$repo_root/capabilities.d" "$copy/capabilities.d"
  cp -- "$repo_root/dotfiles/.config/hypr/scripts/providers/theme.sh" \
    "$copy/dotfiles/.config/hypr/scripts/providers/theme.sh"
  printf '%s\n' "$copy"
}

# edit_json FILE JQ_FILTER [JQ_ARGS...]
edit_json() {
  local file=$1 filter=$2
  shift 2
  jq "$@" "$filter" "$file" >"$file.tmp"
  mv -- "$file.tmp" "$file"
}

expect_rejected() {
  local name=$1 pattern=$2 root=$3
  if validate_ledger "$root"; then
    fail "$name is rejected"
  fi
  if ! grep -Fq -- "$pattern" "$fixture/last.err"; then
    cat -- "$fixture/last.err" >&2
    fail "$name is rejected with: $pattern"
  fi
  printf 'ok - %s is rejected\n' "$name"
}

copy=$(make_copy duplicate-option)
fnott=$(jq -c '.options["notifications/fnott"]' "$copy/capabilities.d/d03-notifications.json")
# shellcheck disable=SC2016 # $record is a jq variable.
edit_json "$copy/capabilities.d/d07-session-auxiliary.json" '.options["notifications/fnott"] = $record' --argjson record "$fnott"
expect_rejected 'option defined in two fragments' \
  'options notifications/fnott is defined in both capabilities.d/d03-notifications.json and capabilities.d/d07-session-auxiliary.json' "$copy"

copy=$(make_copy duplicate-key)
python3 -I - "$copy/capabilities.d/d03-notifications.json" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace('"options": {', '"options": {\n    "notifications/fnott": {},', 1)
open(path, "w", encoding="utf-8").write(text)
PY
expect_rejected 'duplicate key inside one fragment' "duplicate key 'notifications/fnott'" "$copy"

copy=$(make_copy duplicate-generic)
edit_json "$copy/capabilities.d/d01-panels.json" '.generic_packages.ffmpeg = {"class": "backend-dependency", "owner": "D07", "reason": "Duplicate"}'
expect_rejected 'generic package defined in two fragments' 'generic_packages ffmpeg is defined in both' "$copy"

copy=$(make_copy duplicate-owner)
edit_json "$copy/capabilities.d/d02-launchers.json" '.owner = "D01"'
expect_rejected 'two fragments with one owner' 'fragment owner D01 is defined in both' "$copy"

copy=$(make_copy unknown-option)
edit_json "$copy/capabilities.d/d06-applications.json" '.options["browser/netscape"] = .options["browser/firefox"]'
expect_rejected 'unknown role option' 'defines unknown role options: browser/netscape' "$copy"

copy=$(make_copy shared-package-confusion)
edit_json "$copy/capabilities.d/d01-panels.json" '.options["launcher/nwg-panel"] = .options["bar/nwg-panel"]'
expect_rejected 'package under the wrong role' 'defines unknown role options: launcher/nwg-panel' "$copy"

copy=$(make_copy missing-option)
edit_json "$copy/capabilities.d/d06-applications.json" 'del(.options["browser/firefox"])'
expect_rejected 'missing role option' 'is missing role options: browser/firefox' "$copy"

copy=$(make_copy missing-none)
edit_json "$copy/capabilities.d/d05-terminal-workspace.json" 'del(.none_states.agent)'
expect_rejected 'missing None state' 'is missing None states: agent' "$copy"

copy=$(make_copy unknown-none)
edit_json "$copy/capabilities.d/d01-panels.json" '.none_states.bar = {"behavior": "No bar", "theme": "no member units"}'
expect_rejected 'None state for a required role' 'defines unknown None states: bar' "$copy"

copy=$(make_copy missing-generic)
edit_json "$copy/capabilities.d/d07-session-auxiliary.json" 'del(.generic_packages["noto-fonts"])'
expect_rejected 'missing generic package' 'is missing generic packages: noto-fonts' "$copy"

copy=$(make_copy role-as-generic)
edit_json "$copy/capabilities.d/d07-session-auxiliary.json" '.generic_packages.zenity = {"class": "themed-interface", "owner": "D07", "reason": "Waybar extra"}'
expect_rejected 'role extra classified as generic' 'defines unknown generic packages: zenity' "$copy"

copy=$(make_copy generic-theme-class)
edit_json "$copy/capabilities.d/d07-session-auxiliary.json" '.generic_packages["noto-fonts"].theme = {"support": "supported"}'
expect_rejected 'theme on a generic package that is not a themed interface' \
  'theme is only valid for themed-interface packages' "$copy"

copy=$(make_copy missing-fragments)
rm -rf -- "$copy/capabilities.d"
expect_rejected 'ledger without fragments' 'is missing role options:' "$copy"

copy=$(make_copy bad-vocabulary)
edit_json "$copy/capabilities.d/d03-notifications.json" '.options["notifications/mako"].support = "great"'
expect_rejected 'unknown support value' "unknown option_support 'great'" "$copy"

copy=$(make_copy vocabulary-drift)
edit_json "$copy/capabilities.json" 'del(.vocabulary.family.motif) | .vocabulary.family.motif = "Motif toolkit"'
expect_rejected 'undocumented vocabulary change' 'vocabulary.family must document exactly' "$copy"

copy=$(make_copy unknown-field)
edit_json "$copy/capabilities.d/d03-notifications.json" '.options["notifications/mako"].colour = "blue"'
expect_rejected 'unknown option field' 'has unknown field(s): colour' "$copy"

# A valid, evidence-backed record exercises references, labels and provider actions.
add_fnott_capability() {
  local file=$1/capabilities.d/d03-notifications.json support=$2 action_list=$3 evidence=$4
  # shellcheck disable=SC2016 # $support, $actions and $evidence are jq variables.
  edit_json "$file" '
    .capabilities["notifications.dnd"] = {
      domain: "notifications", requirement: "required",
      outcome: "Ordinary popups are suppressed and DND reads back as enabled",
      failure_states: ["unsupported", "unavailable", "failed"], actions: $actions}
    | .evidence["E-D03-001"] = {kind: "documentation", source: "fnott(1), fnott 1.8",
      date: "2026-10-20", result: "No do-not-disturb control is documented"}
    | .options["notifications/fnott"] += {support: $support,
      limitations: ["Fnott has no native do-not-disturb control."],
      capabilities: {"notifications.dnd": {support: "unsupported", mechanism: "none",
        evidence: $evidence, note: "No native DND"}}}
  ' --arg support "$support" --argjson actions "$action_list" --argjson evidence "$evidence"
}

copy=$(make_copy valid-record)
add_fnott_capability "$copy" limited '["notifications.dnd.set", "theme.set"]' '["E-D03-001"]'
validate_ledger "$copy" || {
  cat -- "$fixture/last.err" >&2
  fail 'evidence-backed limited record with provider actions is accepted'
}
printf 'ok - evidence-backed limited record with provider actions is accepted\n'

copy=$(make_copy missing-handler)
add_fnott_capability "$copy" limited '["theme.no_such_operation"]' '["E-D03-001"]'
expect_rejected 'action without a provider handler' \
  'action theme.no_such_operation has no hss_action_theme_no_such_operation in providers/theme.sh' "$copy"

copy=$(make_copy bad-action)
add_fnott_capability "$copy" limited '["Notifications.DND"]' '["E-D03-001"]'
expect_rejected 'malformed action ID' "action 'Notifications.DND' must match" "$copy"

copy=$(make_copy undefined-evidence)
add_fnott_capability "$copy" limited '[]' '["E-D03-404"]'
expect_rejected 'undefined evidence reference' 'cites undefined evidence E-D03-404' "$copy"

copy=$(make_copy duplicate-evidence)
add_fnott_capability "$copy" limited '[]' '["E-D03-001"]'
python3 -I - "$copy/capabilities.d/d03-notifications.json" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
record = '"E-D03-001": {"kind": "static", "source": "x", "date": "2026-10-20", "result": "y"},'
text = text.replace('"evidence": {', '"evidence": {\n    ' + record, 1)
open(path, "w", encoding="utf-8").write(text)
PY
expect_rejected 'duplicate evidence ID' "duplicate key 'E-D03-001'" "$copy"

copy=$(make_copy foreign-evidence)
add_fnott_capability "$copy" limited '[]' '["E-D04-001"]'
edit_json "$copy/capabilities.d/d03-notifications.json" '.evidence["E-D04-001"] = .evidence["E-D03-001"]'
expect_rejected 'evidence ID with a foreign owner' 'evidence IDs in this fragment must look like E-D03-001' "$copy"

copy=$(make_copy dishonest-full)
add_fnott_capability "$copy" full '[]' '["E-D03-001"]'
expect_rejected 'full label with an unsupported required capability' \
  'full support conflicts with required capability notifications.dnd marked unsupported' "$copy"

copy=$(make_copy unexplained-limited)
add_fnott_capability "$copy" limited '[]' '["E-D03-001"]'
edit_json "$copy/capabilities.d/d03-notifications.json" '.options["notifications/fnott"].limitations = []'
expect_rejected 'limited label without a limitation' 'limited support needs at least one user-facing limitation' "$copy"
