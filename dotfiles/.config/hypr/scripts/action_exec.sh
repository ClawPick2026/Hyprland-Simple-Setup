#!/usr/bin/env bash
set -euo pipefail

# Semantic action dispatcher. Contract: Documents/runtime-managed-configuration.md.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export HSS_SCRIPTS_DIR=$script_dir
# shellcheck source=dotfiles/.config/hypr/scripts/lib/hss_runtime.sh
source "$script_dir/lib/hss_runtime.sh"

usage() {
    printf 'Usage: action_exec.sh [--json] [--quiet] ACTION_ID [--] [ARG...]\n' >&2
}

# Invalid requests still produce one envelope in --json mode.
usage_exit() {
    local reason=$1
    if [[ ${json:-false} == true ]]; then
        jq -cn --arg action "${action:-}" --arg reason "$reason" \
            '{schema: 1, action: (if $action == "" then null else $action end), provider: null,
              outcome: "usage", reason: $reason, exit_status: 2}'
    else
        printf '%s\n' "$reason" >&2
        usage
    fi
    exit 2
}

json=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) json=true; shift ;;
        --quiet) export HSS_ACTION_NOTIFY=0; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) usage_exit "unknown option $1" ;;
        *) break ;;
    esac
done

action=${1:-}
[[ $action =~ ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$ ]] || usage_exit "invalid action name"
shift
[[ ${1:-} != -- ]] || shift
$json && export HSS_ACTION_NOTIFY=0

domain=${action%%.*}
provider_file="$script_dir/providers/$domain.sh"
handler="hss_action_${action//./_}"
if [[ -r $provider_file ]]; then
    # shellcheck source=/dev/null
    source "$provider_file"
fi
declare -F "$handler" >/dev/null || usage_exit "unknown action: $action"

status=0
# stdout belongs to the dispatcher: one envelope with --json, nothing otherwise.
"$handler" "$@" >&2 || status=$?
if [[ -z $HSS_OUTCOME ]]; then
    HSS_OUTCOME=$(hss_outcome_from_status "$status")
fi
code=$(hss_outcome_code "$HSS_OUTCOME") || code=1

if $json; then
    jq -cn \
        --arg action "$action" \
        --arg provider "$HSS_PROVIDER" \
        --arg outcome "$HSS_OUTCOME" \
        --arg reason "$HSS_REASON" \
        --argjson exit_status "$code" \
        --arg observed "$HSS_OBSERVED" \
        --arg pending "$HSS_PENDING" \
        '{schema: 1, action: $action, provider: (if $provider == "" then null else $provider end),
          outcome: $outcome, reason: $reason, exit_status: $exit_status}
         + (if $observed == "" then {} else {observed: ($observed | fromjson)} end)
         + (if $pending == "" then {} else {pending: $pending} end)'
else
    case "$HSS_OUTCOME" in
        completed|accepted|cancelled|disabled|usage) [[ $HSS_OUTCOME != usage || -z $HSS_REASON ]] || printf '%s: %s\n' "$action" "$HSS_REASON" >&2 ;;
        *)
            [[ -z $HSS_REASON ]] || printf '%s: %s\n' "$action" "$HSS_REASON" >&2
            hss_notify_user "${action}: ${HSS_OUTCOME}" "$HSS_REASON"
            ;;
    esac
fi
exit "$code"
