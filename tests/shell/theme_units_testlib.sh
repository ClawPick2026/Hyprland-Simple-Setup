#!/usr/bin/env bash
# Source-only helpers for the D05/D06 theme unit suites. They drive the pure renderer
# (hss_theme.py plan) against fixture homes; nothing here starts an application.

theme_repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
theme_py="$theme_repo_root/dotfiles/.config/hypr/theme/hss_theme.py"

# make_member_roles OUT ROLE=PKG[,PKG...] ...
# Writes a schema-2 roles.json from the catalog. The first package is the primary;
# ROLE= (empty) selects None.
make_member_roles() {
  local out=$1
  shift
  python3 - "$theme_repo_root/packages.json" "$out" "$@" <<'PY'
import json
import sys

registry = json.load(open(sys.argv[1], encoding="utf-8"))
out = sys.argv[2]
roles, selected = {}, {}
for spec in sys.argv[3:]:
    role, _, packages = spec.partition("=")
    names = [name for name in packages.split(",") if name]
    options = {option["package"]: option for option in registry["roles"][role]["options"]}
    members = [options[name] for name in names]
    selected[role] = members
    roles[role] = members[0] if members else None
json.dump({"schema_version": 2, "roles": roles, "selected": selected, "agent_executables": {}},
          open(out, "w", encoding="utf-8"), indent=2)
PY
}

# new_theme_home DIR: a home with the shipped dotfiles copied in (not linked).
new_theme_home() {
  local home=$1
  mkdir -p "$home"
  cp -a "$theme_repo_root/dotfiles/." "$home/"
}

# theme_plan VARIANT ROLES HOME OUTDIR [--adopt]: writes OUTDIR/plan.json.
theme_plan() {
  local variant=$1 roles=$2 home=$3 out=$4
  shift 4
  rm -rf -- "$out"
  mkdir -p "$out"
  python3 "$theme_py" plan --variant "$variant" --roles "$roles" --home "$home" \
    --config-home "$home/.config" --data-home "$home/.local/share" \
    --theme-root "$home/.config/hss-theme" --staging "$out/stage" --out "$out/plan.json" "$@"
}

theme_unit_status() {
  jq -r --arg id "$2" '.units[] | select(.id == $id) | .status' "$1/plan.json"
}

# theme_candidate OUTDIR UNIT TARGET_SUFFIX: path of the staged candidate, or of the
# unchanged target, for the output of UNIT whose target ends with TARGET_SUFFIX.
theme_candidate() {
  jq -er --arg id "$2" --arg suffix "$3" '
    [.units[] | select(.id == $id) | .outputs[] | select(.target | endswith($suffix))][0]
    | if .staged then .staged else .target end' "$1/plan.json"
}

# theme_commit OUTDIR: copy staged candidates to their targets (test-only stand-in for
# providers/theme.sh, which commits through the reliability library).
theme_commit() {
  local target staged
  while IFS=$'\t' read -r target staged; do
    mkdir -p -- "$(dirname -- "$target")"
    cp -- "$staged" "$target"
  done < <(jq -r '.units[] | select(.status == "ready") | .outputs[] | select(.staged) | [.target, .staged] | @tsv' "$1/plan.json")
}
