#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose.
set -euo pipefail
# F04.1: coverage descriptor validation. Merges tests/fixtures/harmonization/coverage/*.json and
# checks schema, unique case IDs, owners, complete option and None coverage against
# packages.json, test-reference lifecycle, result and evidence vocabulary, and (when the F01
# ledger exists) capability foreign keys. Synthetic temporary copies prove that missing
# options, duplicate IDs, unowned None states and stale delivered paths fail.
# Format: tests/fixtures/harmonization/README.md.
# shellcheck source=tests/shell/harmonization_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/harmonization_testlib.sh"
ht_fixture_init

coverage="$HT_REPO_ROOT/tests/fixtures/harmonization/coverage"
validator="$HT_ROOT/validate_coverage.py"
cat > "$validator" <<'PY'
"""validate_coverage.py COVERAGE_DIR PACKAGES_JSON REPO_ROOT [LEDGER_ROOT]"""
import json
import re
import sys
from pathlib import Path

coverage_dir, packages_path, repo_root = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
ledger_root = Path(sys.argv[4]) if len(sys.argv) > 4 else repo_root
errors = []

OWNER = r"(?:F0[1-4]|D0[1-7]|I01)"
OWNER_RE = re.compile(rf"^{OWNER}$")
TASK_RE = re.compile(rf"\b{OWNER}\.[0-9]+\b")
CASE_ID_RE = re.compile(rf"^{OWNER}-[A-Za-z0-9][A-Za-z0-9._-]*$")
CAPABILITY_RE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z0-9_-]+)+$")
EVIDENCE_ID_RE = re.compile(rf"^E-{OWNER}-[0-9]{{3}}$")
RESULTS = ("not-run", "passed", "failed", "blocked", "skipped")
LEVELS = ("documentation", "static", "argv", "modeled-effect", "real-effect", "visual")
FUNCTIONAL_RANK = {"documentation": 0, "static": 1, "argv": 2, "modeled-effect": 3, "real-effect": 4}
REQUIRED = {"id", "option", "capability", "evidence_required", "tests", "vm_check", "result", "limits"}
OPTIONAL = {"owner", "evidence", "selection", "context", "preconditions", "assertions", "notes"}
EXPECTED_NONE = {"dock/none", "agent/none", "tui_file_manager/none", "gui_editor/none"}


def load(path):
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"{path.name}: unreadable JSON: {error}")
        return None


registry = load(packages_path) or {}
roles = registry.get("roles", {})
options = {f"{role}/{option['package']}" for role, spec in roles.items() for option in spec.get("options", [])}
none_states = {f"{role}/none" for role, spec in roles.items() if spec.get("required") is False}
if none_states != EXPECTED_NONE:
    errors.append(f"packages.json optional roles changed: {sorted(none_states)}; update the coverage contract")
generic = set()


def collect(value):
    if isinstance(value, str):
        generic.add(value)
    elif isinstance(value, list):
        for item in value:
            collect(item)
    elif isinstance(value, dict):
        for item in value.values():
            collect(item)


for section in ("hyprland_packages", "aur_packages", "official_packages", "required"):
    collect(registry.get(section, {}))

ledger_files = []
if (ledger_root / "capabilities.json").is_file():
    ledger_files.append(ledger_root / "capabilities.json")
if (ledger_root / "capabilities.d").is_dir():
    ledger_files += sorted((ledger_root / "capabilities.d").glob("*.json"))
capabilities = None
ledger_evidence = {}
ledger_themes = set()
ledger_generic = set()
if ledger_files:
    capabilities = set()
    for path in ledger_files:
        data = load(path)
        if isinstance(data, dict):
            capabilities |= set(data.get("capabilities") or {})
            for option_id, option in (data.get("options") or {}).items():
                if isinstance(option, dict) and option.get("theme"):
                    ledger_themes.add(option_id)
            ledger_generic |= set(data.get("generic_packages") or {})
            for evidence_id, item in (data.get("evidence") or {}).items():
                if isinstance(item, dict):
                    ledger_evidence[evidence_id] = item.get("kind")


def evidence_kinds(evidence, where):
    """Evidence is an ID, an object with a kind, or a list of these."""
    items = evidence if isinstance(evidence, list) else [evidence]
    kinds = []
    for item in items:
        if isinstance(item, dict):
            kind = item.get("kind")
            if kind not in FUNCTIONAL_RANK and kind != "visual":
                errors.append(f"{where}: evidence kind {kind!r} is not an evidence level")
            else:
                kinds.append(kind)
        elif isinstance(item, str) and EVIDENCE_ID_RE.match(item):
            if capabilities is not None:
                if item not in ledger_evidence:
                    errors.append(f"{where}: evidence {item} is not defined in the capability ledger")
                else:
                    kinds.append(ledger_evidence[item])
        elif not (isinstance(item, str) and item.strip()):
            errors.append(f"{where}: evidence entries must be evidence IDs or objects with a kind")
    return kinds


def satisfies(kinds, required):
    if required == "visual":
        return "visual" in kinds
    return any(FUNCTIONAL_RANK.get(kind, -1) >= FUNCTIONAL_RANK[required] for kind in kinds)


fragments = sorted(coverage_dir.glob("*.json"))
if not fragments:
    errors.append(f"no coverage fragments in {coverage_dir}")
seen = {}
covered = set()
case_total = 0
for path in fragments:
    name = path.name
    data = load(path)
    if data is None:
        continue
    if not isinstance(data, dict):
        errors.append(f"{name}: a fragment must be a JSON object")
        continue
    if data.get("schema_version") != 1:
        errors.append(f"{name}: schema_version must be 1, found {data.get('schema_version')!r}")
    owner = data.get("owner")
    owner_ok = isinstance(owner, str) and bool(OWNER_RE.match(owner))
    if not owner_ok:
        errors.append(f"{name}: missing or invalid owner {owner!r}")
    extra = set(data) - {"schema_version", "owner", "description", "cases"}
    if extra:
        errors.append(f"{name}: unknown fragment fields {sorted(extra)}")
    cases = data.get("cases")
    if not isinstance(cases, list) or not cases:
        errors.append(f"{name}: cases must be a non-empty list")
        continue
    for index, case in enumerate(cases):
        where = f"{name} case {index}"
        if not isinstance(case, dict):
            errors.append(f"{where}: a case must be an object")
            continue
        case_total += 1
        case_id = case.get("id")
        if isinstance(case_id, str):
            where = f"{name} {case_id}"
        missing = REQUIRED - set(case)
        if missing:
            errors.append(f"{where}: missing fields {sorted(missing)}")
        unknown = set(case) - REQUIRED - OPTIONAL
        if unknown:
            errors.append(f"{where}: unknown fields {sorted(unknown)}")
        case_owner = case.get("owner", owner)
        case_owner_ok = isinstance(case_owner, str) and bool(OWNER_RE.match(case_owner))
        if "owner" in case and not case_owner_ok:
            errors.append(f"{where}: invalid case owner {case_owner!r}")
        if not isinstance(case_id, str) or not CASE_ID_RE.match(case_id):
            errors.append(f"{where}: invalid case id {case_id!r}")
        else:
            if case_owner_ok and not case_id.startswith(case_owner + "-"):
                errors.append(f"{where}: case id must start with its owner {case_owner}-")
            if case_id in seen:
                errors.append(f"{where}: duplicate case id {case_id} (first defined in {seen[case_id]})")
            else:
                seen[case_id] = name

        limits = case.get("limits", "")
        notes = case.get("notes", "")
        if not isinstance(limits, str):
            errors.append(f"{where}: limits must be text")
            limits = ""
        if not isinstance(case.get("vm_check", ""), str):
            errors.append(f"{where}: vm_check must be text")

        tests = case.get("tests")
        delivered = 0
        planned = 0
        vm_check = case.get("vm_check") if isinstance(case.get("vm_check"), str) else ""
        manual_only = False
        if not isinstance(tests, list):
            errors.append(f"{where}: tests must be a list")
            tests = []
        elif not tests:
            # Manual-only cases (a VM check) and documented limitations need no test program.
            if vm_check.strip():
                manual_only = True
            elif not (case.get("evidence_required") == "documentation" and limits.strip()):
                errors.append(f"{where}: tests is empty without a vm_check or a documented limitation")
        for test in tests:
            if not isinstance(test, dict) or not {"path", "state"} <= set(test) or set(test) - {"path", "state", "case"}:
                errors.append(f"{where}: each test needs exactly path, state and an optional case name")
                continue
            test_path, state = test["path"], test["state"]
            if not isinstance(test_path, str) or not test_path or test_path.startswith(("/", "~")) \
                    or ".." in Path(test_path).parts or "\\" in test_path:
                errors.append(f"{where}: unsafe test path {test_path!r}")
                continue
            if state == "delivered":
                delivered += 1
                if not (repo_root / test_path).is_file():
                    errors.append(f"{where}: delivered test {test_path} does not exist")
            elif state == "planned":
                planned += 1
                if not TASK_RE.search(limits):
                    errors.append(f"{where}: planned test {test_path} needs its owner and task (for example D03.6) in limits")
            else:
                errors.append(f"{where}: test state must be delivered or planned, found {state!r}")
        placeholder = delivered == 0

        option = case.get("option")
        if option is None:
            pass
        elif not isinstance(option, str):
            errors.append(f"{where}: option must be text or null")
        elif option in options or option in none_states:
            if case_owner_ok:
                covered.add(option)
        elif option.endswith("/none") and option[: -len("/none")] in roles:
            errors.append(f"{where}: {option} is a required role and cannot be None")
        elif option.startswith(("package/", "generic/")) and option.split("/", 1)[1] in generic | ledger_generic:
            pass
        else:
            errors.append(f"{where}: unknown option {option!r}")

        capability = case.get("capability")
        if capability is None:
            if option is not None and not placeholder:
                errors.append(f"{where}: an option case with delivered tests needs a capability")
        elif capability == "theme":
            # Reserved: the option's theme entry in the ledger (options.<option>.theme).
            if capabilities is not None and option in options and option not in ledger_themes:
                errors.append(f"{where}: option {option} has no theme entry in the capability ledger")
        elif not isinstance(capability, str) or not CAPABILITY_RE.match(capability):
            errors.append(f"{where}: invalid capability id {capability!r}")
        elif capabilities is not None and capability not in capabilities:
            errors.append(f"{where}: capability {capability} is not defined in the capability ledger")

        required = case.get("evidence_required")
        if required not in LEVELS:
            errors.append(f"{where}: evidence_required must be one of {', '.join(LEVELS)}, found {required!r}")
        result = case.get("result")
        if result not in RESULTS:
            errors.append(f"{where}: result must be one of {', '.join(RESULTS)}, found {result!r}")
        evidence = case.get("evidence")
        kinds = evidence_kinds(evidence, where) if evidence not in (None, "", []) else []
        if result == "passed":
            if evidence in (None, "", [], {}):
                errors.append(f"{where}: result passed requires an evidence field")
            elif delivered == 0 and not manual_only:
                errors.append(f"{where}: result passed requires a delivered test or a manual vm_check")
            elif kinds and required in LEVELS and not satisfies(kinds, required):
                errors.append(f"{where}: evidence {sorted(set(kinds))} does not satisfy required {required} evidence")
        if result in ("failed", "blocked", "skipped") and not (limits.strip() or (isinstance(notes, str) and notes.strip())):
            errors.append(f"{where}: result {result} needs a reason in limits or notes")

for option in sorted(options - covered):
    errors.append(f"{option} has no coverage case from an owned fragment")
for option in sorted(none_states - covered):
    errors.append(f"{option} (None state) has no coverage case from an owned fragment")

if errors:
    for message in errors:
        print(f"not ok - coverage: {message}", file=sys.stderr)
    sys.exit(1)
ledger_note = "capabilities checked against the ledger" if capabilities is not None else "ledger absent, capability keys unchecked"
print(f"coverage: {len(fragments)} fragments, {case_total} cases, {len(options)} options and "
      f"{len(none_states)} None states covered; {ledger_note}")
PY

validate() {
    ht_run python3 -B "$validator" "$1" "$HT_REPO_ROOT/packages.json" "$HT_REPO_ROOT" "${2:-$HT_REPO_ROOT}"
}
copy_coverage() {
    local dir
    dir=$(mktemp -d "$HT_ROOT/coverage.XXXXXX")
    cp -- "$coverage"/*.json "$dir/"
    printf '%s\n' "$dir"
}
# drop_option DIR OPTION: remove every case for OPTION from every fragment.
drop_option() {
    local file
    for file in "$1"/*.json; do
        jq_edit "$file" --arg option "$2" 'del(.cases[] | select(.option == $option))'
    done
}
jq_edit() {
    local file=$1
    shift
    jq "$@" "$file" > "$file.tmp"
    mv -f -- "$file.tmp" "$file"
}
# expect_invalid LABEL MESSAGE DIR [LEDGER_ROOT]
expect_invalid() {
    validate "$3" "${4:-}"
    [[ $HT_STATUS -ne 0 ]] || ht_fail "$1: the validator accepted it"
    assert_contains "$(cat -- "$HT_STDERR")" "$2" "$1 message"
}

# ---------------------------------------------------------------------------
# Repository fragments

validate "$coverage"
[[ $HT_STATUS -eq 0 ]] || { cat -- "$HT_STDERR" >&2; ht_fail "repository coverage fragments are invalid"; }
cat -- "$HT_STDOUT"
for fragment in d01-panels d02-launchers d03-notifications d04-devices d05-terminal-workspace d06-applications \
    d07-session-auxiliary f-foundation; do
    [[ -f $coverage/$fragment.json ]] || ht_fail "coverage fragment $fragment.json is missing"
done
ht_ok "coverage fragments cover every catalog option and the four None states with valid owners, tests and results"

dir=$(copy_coverage)
validate "$dir"
assert_status 0 "an unmodified copy"
ht_ok "an unmodified copy validates (control for the negative fixtures)"

# ---------------------------------------------------------------------------
# Required negative fixtures

dir=$(copy_coverage)
drop_option "$dir" launcher/tofi
expect_invalid "missing option" "launcher/tofi has no coverage case" "$dir"

dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases += [.cases[0]]'
expect_invalid "duplicate case id" "duplicate case id F04-runner-isolation" "$dir"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0].id = "F04-shared" | .cases[1].id = "F04-shared"'
expect_invalid "duplicate case id within a fragment" "duplicate case id F04-shared" "$dir"

dir=$(copy_coverage)
for file in "$dir"/*.json; do
    if jq -e 'any(.cases[]; .option == "dock/none")' "$file" >/dev/null; then
        jq_edit "$file" 'del(.owner)'
    fi
done
expect_invalid "unowned None (owner removed)" "dock/none (None state) has no coverage case from an owned fragment" "$dir"
assert_contains "$(cat -- "$HT_STDERR")" ".json: missing or invalid owner" "missing owner message"
dir=$(copy_coverage)
drop_option "$dir" agent/none
expect_invalid "unowned None (case removed)" "agent/none (None state) has no coverage case" "$dir"

dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0].tests[0].path = "tests/shell/removed_suite.sh"'
expect_invalid "stale delivered path" "delivered test tests/shell/removed_suite.sh does not exist" "$dir"
ht_ok "missing options, duplicate IDs, unowned None states and stale delivered paths fail validation"

# ---------------------------------------------------------------------------
# Vocabulary and lifecycle

dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0].result = "passed"'
expect_invalid "passed without evidence" "result passed requires an evidence field" "$dir"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0] |= (.tests = [{"path": "tests/shell/future_suite.sh", "state": "planned"}]
    | .limits = "Delivered by F04.6" | .result = "passed" | .evidence = {"kind": "real-effect"})'
expect_invalid "passed with only planned tests" "result passed requires a delivered test or a manual vm_check" "$dir"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '(.cases[] | select(.id == "F04-managed-configuration")) |= (.result = "passed" | .evidence = {"kind": "argv"})'
expect_invalid "argv evidence for a modeled-effect requirement" "does not satisfy required modeled-effect evidence" "$dir"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '(.cases[] | select(.id == "F04-theme-visual-review")) |= (.result = "passed" | .evidence = [{"kind": "real-effect"}])'
expect_invalid "functional evidence for a visual requirement" "does not satisfy required visual evidence" "$dir"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '(.cases[] | select(.id == "F04-managed-configuration")) |= (.result = "passed"
    | .evidence = {"kind": "modeled-effect", "date": "2026-10-20", "command": "tests/run.sh tests/shell/managed_configuration.sh"})'
validate "$dir"
assert_status 0 "passed with sufficient evidence"
mutations=(
    '.cases[0].result = "green"|result must be one of'
    '.cases[0].evidence_required = "screenshot"|evidence_required must be one of'
    '.cases[0].tests[0].state = "done"|test state must be delivered or planned'
    '.cases[0].tests = []|tests is empty without a vm_check or a documented limitation'
    '.cases[0].tests[0].path = "../outside.sh"|unsafe test path'
    '.cases[0].tests[0].path = "/etc/passwd"|unsafe test path'
    '.schema_version = 2|schema_version must be 1'
    '.cases[0].colour = "blue"|unknown fields'
    '.cases[0].id = "X99-bad"|invalid case id'
    '.cases[0].id = "D01-dock-none"|case id must start with its owner F04-'
    'del(.cases[0].vm_check)|missing fields'
    '.cases[0].capability = "Not A Capability"|invalid capability id'
)
for entry in "${mutations[@]}"; do
    dir=$(copy_coverage)
    jq_edit "$dir/f-foundation.json" "${entry%%|*}"
    expect_invalid "mutation [${entry%%|*}]" "${entry#*|}" "$dir"
done
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0].tests += [{"path": "tests/shell/future_suite.sh", "state": "planned"}]
    | .cases[0].limits = "placeholder without a task"'
expect_invalid "planned test without an owner task" "needs its owner and task" "$dir"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0].result = "skipped" | .cases[0].limits = ""'
expect_invalid "unexplained skip" "result skipped needs a reason" "$dir"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0].option = "launcher/notreal"'
expect_invalid "unknown option" "unknown option 'launcher/notreal'" "$dir"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0].option = "launcher/none"'
expect_invalid "None for a required role" "launcher/none is a required role and cannot be None" "$dir"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0].option = "generic/not-in-the-catalog"'
expect_invalid "unknown generic package" "unknown option 'generic/not-in-the-catalog'" "$dir"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0].option = "launcher/wofi"'
expect_invalid "delivered option case without a capability" "needs a capability" "$dir"
ht_ok "result, evidence, test-state, path, schema and option vocabularies are enforced"

# ---------------------------------------------------------------------------
# Capability ledger foreign keys

# The synthetic ledger is a copy of the repository ledger plus one fixture fragment, so the
# domain fragments keep resolving while the fixture cases exercise the foreign keys.
ledger=$(mktemp -d "$HT_ROOT/ledger.XXXXXX")
mkdir -p -- "$ledger/capabilities.d"
[[ ! -f $HT_REPO_ROOT/capabilities.json ]] || cp -- "$HT_REPO_ROOT/capabilities.json" "$ledger/"
if [[ -d $HT_REPO_ROOT/capabilities.d ]]; then
    cp -- "$HT_REPO_ROOT"/capabilities.d/*.json "$ledger/capabilities.d/" 2>/dev/null || true
fi
cat > "$ledger/capabilities.d/zz-f04-fixture.json" <<'JSON'
{"schema_version": 1, "owner": "F04",
 "capabilities": {"fixture.check": {"domain": "fixture", "requirement": "required"}},
 "options": {}, "none_states": {}, "generic_packages": {"f04-fixture-tool": {"class": "backend-dependency", "owner": "F04", "reason": "fixture"}},
 "evidence": {"E-F04-901": {"kind": "argv", "source": "fixture"}}}
JSON
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0].capability = "fixture.check" | .cases[1].option = "generic/f04-fixture-tool" | .cases[1].capability = "fixture.check"'
validate "$dir" "$ledger"
[[ $HT_STATUS -eq 0 ]] || { cat -- "$HT_STDERR" >&2; ht_fail "a capability and generic package defined in the ledger"; }
assert_contains "$(cat -- "$HT_STDOUT")" "capabilities checked against the ledger" "ledger summary"
jq_edit "$dir/f-foundation.json" '.cases[2].capability = "fixture.unknown"'
expect_invalid "unknown capability" "capability fixture.unknown is not defined in the capability ledger" "$dir" "$ledger"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '(.cases[] | select(.id == "F04-managed-configuration")) |= (.capability = "fixture.check"
    | .result = "passed" | .evidence = ["E-F04-901"])'
expect_invalid "ledger evidence below the required level" "does not satisfy required modeled-effect evidence" "$dir" "$ledger"
jq_edit "$dir/f-foundation.json" '(.cases[] | select(.id == "F04-managed-configuration")) |= (.evidence = ["E-F04-999"])'
expect_invalid "unknown ledger evidence" "evidence E-F04-999 is not defined in the capability ledger" "$dir" "$ledger"
dir=$(copy_coverage)
jq_edit "$dir/f-foundation.json" '.cases[0].option = "launcher/wofi" | .cases[0].capability = "theme"'
validate "$dir" "$ledger"
if jq -es 'any(.[]; .options["launcher/wofi"].theme // false)' "$ledger"/capabilities.d/*.json >/dev/null 2>&1; then
    assert_status 0 "reserved theme capability for an option with a ledger theme entry"
else
    [[ $HT_STATUS -ne 0 ]] || ht_fail "the reserved theme capability was accepted without a ledger theme entry"
    assert_contains "$(cat -- "$HT_STDERR")" "launcher/wofi has no theme entry" "reserved theme capability"
fi
ht_ok "when the ledger exists every case capability and evidence ID must be defined there"
