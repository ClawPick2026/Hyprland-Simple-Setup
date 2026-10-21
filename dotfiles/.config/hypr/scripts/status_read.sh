#!/usr/bin/env bash
set -euo pipefail

# Typed status observations. Contract: Documents/runtime-managed-configuration.md.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export HSS_SCRIPTS_DIR=$script_dir
# shellcheck source=dotfiles/.config/hypr/scripts/lib/hss_runtime.sh
source "$script_dir/lib/hss_runtime.sh"

domain=${1:-}
[[ $domain =~ ^[a-z][a-z0-9_]*$ ]] || { printf 'Usage: status_read.sh DOMAIN\n' >&2; exit 2; }
provider_file="$script_dir/providers/$domain.sh"
handler="hss_status_$domain"
if [[ -r $provider_file ]]; then
    # shellcheck source=/dev/null
    source "$provider_file"
fi
declare -F "$handler" >/dev/null || { printf 'Unknown status domain: %s\n' "$domain" >&2; exit 2; }

if ! output=$("$handler" 2>/dev/null) || ! jq -e 'type == "object" and .schema == 1' <<<"$output" >/dev/null 2>&1; then
    output=$(hss_status_emit "$domain" "" error null null "status provider failed")
fi
printf '%s\n' "$output"
