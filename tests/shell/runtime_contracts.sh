#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs and bash -c scripts are single-quoted on purpose.
set -euo pipefail
# F04.3: executable contracts for action_exec.sh and status_read.sh
# (Documents/runtime-managed-configuration.md sections 2, 3 and 5). A throwaway provider in a
# fixture copy of the scripts directory exercises the dispatcher; the theme provider is the
# representative real provider. Evidence level: argv and modeled-effect.
# shellcheck source=tests/shell/harmonization_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/harmonization_testlib.sh"
ht_fixture_init

runtime="$HT_ROOT/hypr"
ht_copy_runtime "$runtime"
scripts="$runtime/scripts"
# Foundation suite: only the core theme registry; domain units.d fragments have their own suites.
rm -rf -- "$runtime/theme/units.d"
action="$scripts/action_exec.sh"
status="$scripts/status_read.sh"
export HT_PROBE_DIR="$HT_ROOT/probe"
mkdir -p -- "$HT_PROBE_DIR"

cat > "$scripts/providers/fixture.sh" <<'PROVIDER'
#!/usr/bin/env bash
# Throwaway provider used only by tests/shell/runtime_contracts.sh.
hss_action_fixture_outcome() {
    HSS_PROVIDER=fixture-provider
    printf 'x' >> "$HT_PROBE_DIR/outcome.calls"
    hss_set_outcome "$1" "fixture reason for $1"
}
hss_action_fixture_argv() {
    HSS_PROVIDER=fixture-provider
    printf 'x' >> "$HT_PROBE_DIR/argv.calls"
    if (($#)); then printf '%s\0' "$@"; fi > "$HT_PROBE_DIR/argv"
    hss_set_outcome completed "arguments recorded"
}
hss_action_fixture_status() {
    return "$1"
}
hss_action_fixture_noisy() {
    printf 'provider chatter on stdout\n'
    hss_set_outcome completed "noisy provider"
}
hss_action_fixture_observed() {
    HSS_OBSERVED='{"dnd":true,"count":null}'
    HSS_PENDING='restart pending'
    hss_set_outcome completed "observed state read back"
}
hss_status_fixture() {
    case "${HT_STATUS_MODE:-ok}" in
        ok) hss_status_emit fixture fixture-provider available '{"running":true,"count":null,"dnd":null}' '{"dnd":"supported"}' ;;
        fail) printf 'partial output' ; return 1 ;;
        garbage) printf 'not json\n' ;;
        schema) printf '{"schema":2,"domain":"fixture"}\n' ;;
        unavailable) hss_status_emit fixture "" unavailable null null "no session" ;;
    esac
}
PROVIDER

declare -A codes=(
    [completed]=0 [accepted]=0 [failed]=1 [usage]=2 [cancelled]=3 [disabled]=4
    [unsupported]=5 [missing-dependency]=6 [unavailable]=7 [timeout]=8 [denied]=9 [conflict]=10
)
outcomes=(completed accepted failed usage cancelled disabled unsupported missing-dependency unavailable timeout denied conflict)
assert_eq 12 "${#outcomes[@]}" "frozen outcome count"

# ---------------------------------------------------------------------------
# Outcomes, exit status and the JSON envelope

for outcome in "${outcomes[@]}"; do
    code=${codes[$outcome]}
    ht_run "$action" --json fixture.outcome "$outcome"
    assert_status "$code" "exit status for $outcome"
    assert_eq 1 "$(wc -l < "$HT_STDOUT")" "--json stdout lines for $outcome"
    assert_json "$HT_STDOUT" "keys == [\"action\",\"exit_status\",\"outcome\",\"provider\",\"reason\",\"schema\"]
        and .schema == 1 and .action == \"fixture.outcome\" and .provider == \"fixture-provider\"
        and .outcome == \"$outcome\" and .exit_status == $code and .reason == \"fixture reason for $outcome\"" \
        "envelope for $outcome"
done
assert_calls notify-send 0 "notifications in --json mode"
assert_eq 12 "$(wc -c < "$HT_PROBE_DIR/outcome.calls")" "one provider invocation per request"
ht_ok "all 12 outcomes map to their frozen exit status and a one-line JSON envelope"

ht_run "$action" --json fixture.observed
assert_status 0
assert_json "$HT_STDOUT" '.observed == {"dnd": true, "count": null} and .pending == "restart pending" and .provider == null'
ht_ok "optional observed and pending keys carry typed state and keep unknown values null"

for raw in 0:completed:0 5:unsupported:5 10:conflict:10 42:failed:1 124:failed:1; do
    IFS=: read -r returned outcome code <<<"$raw"
    ht_run "$action" --json fixture.status "$returned"
    assert_status "$code" "exit for provider status $returned"
    assert_json "$HT_STDOUT" ".outcome == \"$outcome\" and .exit_status == $code" "outcome for provider status $returned"
done
ht_ok "a provider return status without an explicit outcome maps to its outcome, unknown codes to failed"

# ---------------------------------------------------------------------------
# Non-JSON mode: silent stdout, notifications only for negative outcomes

notified_outcomes=" failed unsupported missing-dependency unavailable timeout denied conflict "
for outcome in "${outcomes[@]}"; do
    before=$(ht_calls notify-send)
    ht_run "$action" fixture.outcome "$outcome"
    assert_status "${codes[$outcome]}" "non-JSON exit status for $outcome"
    assert_eq 0 "$(wc -c < "$HT_STDOUT")" "non-JSON stdout bytes for $outcome"
    after=$(ht_calls notify-send)
    if [[ $notified_outcomes == *" $outcome "* ]]; then
        assert_eq $((before + 1)) "$after" "notification for $outcome"
        assert_argv notify-send "$after" -a 'Hyprland Simple Setup' -u normal -- \
            "fixture.outcome: $outcome" "fixture reason for $outcome"
    else
        assert_eq "$before" "$after" "no notification for $outcome"
    fi
done
ht_ok "non-JSON mode keeps stdout empty and notifies only failed, unsupported, missing-dependency, unavailable, timeout, denied and conflict"

before=$(ht_calls notify-send)
ht_run "$action" --quiet fixture.outcome failed
assert_status 1
assert_eq 0 "$(wc -c < "$HT_STDOUT")" "--quiet stdout bytes"
assert_calls notify-send "$before" "notifications with --quiet"
ht_double_exit notify-send 1
ht_run "$action" fixture.outcome unavailable
assert_status 7 "exit status when notify-send fails"
rm -f -- "$HT_STATE/exit/notify-send"
ht_remove_double notify-send
ht_run env PATH="$(ht_restricted_path dirname jq date timeout)" "$BASH" "$action" fixture.outcome denied
assert_status 9 "exit status without notify-send"
ht_double notify-send
ht_ok "--quiet suppresses notifications and a failing or missing notify-send never changes the outcome"

ht_run "$action" --json fixture.noisy
assert_status 0
assert_eq 1 "$(wc -l < "$HT_STDOUT")" "--json stdout lines with a chatty provider"
assert_json "$HT_STDOUT" '.outcome == "completed" and .reason == "noisy provider"'
ht_run "$action" fixture.noisy
assert_eq 0 "$(wc -c < "$HT_STDOUT")" "non-JSON stdout bytes with a chatty provider"
ht_ok "provider stdout never reaches the dispatcher's stdout"

# ---------------------------------------------------------------------------
# Usage errors

before=$(ht_calls notify-send)
provider_calls_before=$(wc -c < "$HT_PROBE_DIR/outcome.calls")
for name in fixture.nonexistent nodomain.action; do
    ht_run "$action" --json "$name"
    assert_status 2 "exit status for unknown action $name"
    if [[ -s $HT_STDOUT ]]; then
        assert_eq 1 "$(wc -l < "$HT_STDOUT")" "stdout lines for unknown action $name"
        assert_json "$HT_STDOUT" '.outcome == "usage" and .exit_status == 2' "unknown action envelope"
    fi
done
invalid_names=(
    '' theme Theme.set theme. .theme theme..set 'theme.set;touch x' "theme.set\$(touch $HT_PROBE_DIR/pwned)"
    ../providers/fixture.outcome theme/set 'theme.set ' 1theme.set theme.Set fixture.outcome-x fixture.outcome.
    $'fixture.outcome\nfixture.argv'
)
for name in "${invalid_names[@]}"; do
    ht_run "$action" "$name"
    assert_status 2 "exit status for invalid action name [$name]"
    assert_eq 0 "$(wc -c < "$HT_STDOUT")" "stdout bytes for invalid action name [$name]"
done
ht_run "$action" --bogus fixture.outcome completed
assert_status 2 "exit status for an unknown option"
[[ ! -e $HT_PROBE_DIR/pwned && ! -e $HT_PROBE_DIR/argv.calls ]] || ht_fail "an invalid action name ran provider code"
assert_eq "$provider_calls_before" "$(wc -c < "$HT_PROBE_DIR/outcome.calls")" "provider invocations after usage errors"
assert_calls notify-send "$before" "notifications for usage errors"
ht_ok "unknown actions, invalid action names and unknown options exit 2 without running a provider"

# ---------------------------------------------------------------------------
# Literal argv

# shellcheck disable=SC1003  # a lone backslash is one of the literal arguments.
args=(
    'two words' "it's" '"double quoted"' "\$(touch $HT_PROBE_DIR/pwned)" "\`touch $HT_PROBE_DIR/pwned\`"
    $'line one\nline two' '' '*' '--' '-x' '\' '$HOME' ';' '|' '--json' $'tab\there'
)
ht_run "$action" fixture.argv -- "${args[@]}"
assert_status 0
printf '%s\0' "${args[@]}" > "$HT_ROOT/expected-args"
cmp -s -- "$HT_ROOT/expected-args" "$HT_PROBE_DIR/argv" || ht_fail "arguments were not passed literally"
[[ ! -e $HT_PROBE_DIR/pwned ]] || ht_fail "an argument was evaluated"
assert_eq 1 "$(wc -c < "$HT_PROBE_DIR/argv.calls")" "provider invocations for one request"

ht_run "$action" fixture.argv
assert_eq 0 "$(wc -c < "$HT_PROBE_DIR/argv")" "argv bytes without arguments"
ht_run "$action" fixture.argv ''
printf '\0' > "$HT_ROOT/expected-args"
cmp -s -- "$HT_ROOT/expected-args" "$HT_PROBE_DIR/argv" || ht_fail "one empty argument was not preserved"
ht_run "$action" fixture.argv --json -- value
assert_eq 0 "$(wc -c < "$HT_STDOUT")" "options after the action are arguments, not dispatcher options"
printf '%s\0' --json -- value > "$HT_ROOT/expected-args"
cmp -s -- "$HT_ROOT/expected-args" "$HT_PROBE_DIR/argv" || ht_fail "arguments after the action were reinterpreted"
assert_eq 4 "$(wc -c < "$HT_PROBE_DIR/argv.calls")" "exactly one invocation per request"
ht_ok "arguments with spaces, quotes, substitutions, newlines and empty strings arrive literally once"

# ---------------------------------------------------------------------------
# Shared runtime helpers

ht_run "$BASH" -c 'source "$1"; start=$SECONDS; hss_run_bounded 1 sleep 20; status=$?; printf "%s %s\n" "$status" "$((SECONDS - start))"' _ "$scripts/lib/hss_runtime.sh"
read -r bounded_status bounded_seconds < "$HT_STDOUT"
assert_eq 124 "$bounded_status" "hss_run_bounded timeout status"
((bounded_seconds <= 4)) || ht_fail "hss_run_bounded waited ${bounded_seconds}s"
ht_run "$BASH" -c 'source "$1"; hss_set_outcome bogus "why"; printf "%s|%s|%s\n" "$?" "$HSS_OUTCOME" "$HSS_REASON"' _ "$scripts/lib/hss_runtime.sh"
assert_eq "1|failed|invalid outcome 'bogus'" "$(cat "$HT_STDOUT")" "invalid outcome handling"
ht_ok "bounded commands return 124 on timeout and invalid outcomes become failed"

# ---------------------------------------------------------------------------
# Status observations

notified_before_status=$(ht_calls notify-send)
iso='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
status_keys='["availability","capabilities","domain","error","observed_at","provider","schema","state"]'
ht_run "$status" fixture
assert_status 0
assert_eq 1 "$(wc -l < "$HT_STDOUT")" "status stdout lines"
assert_json "$HT_STDOUT" "keys == $status_keys and .schema == 1 and .domain == \"fixture\"
    and .provider == \"fixture-provider\" and .availability == \"available\"
    and (.observed_at | test(\"$iso\")) and .state.running == true
    and (.state | has(\"count\")) and .state.count == null and .state.dnd == null
    and .capabilities == {\"dnd\": \"supported\"} and .error == null" "status shape"
for mode in fail garbage schema; do
    HT_STATUS_MODE=$mode ht_run "$status" fixture
    assert_status 0 "status exit for a $mode provider"
    assert_eq 1 "$(wc -l < "$HT_STDOUT")" "status stdout lines for a $mode provider"
    assert_json "$HT_STDOUT" "keys == $status_keys and .schema == 1 and .domain == \"fixture\"
        and .availability == \"error\" and .state == null and (.error | type == \"string\" and length > 0)
        and (.observed_at | test(\"$iso\"))" "status for a $mode provider"
done
HT_STATUS_MODE=unavailable ht_run "$status" fixture
assert_json "$HT_STDOUT" '.availability == "unavailable" and .provider == null and .state == null and .error == "no session"'
for domain in nosuch Fixture ../fixture '' fixture.x 'fixture;x'; do
    ht_run "$status" "$domain"
    assert_status 2 "status exit for domain [$domain]"
    assert_eq 0 "$(wc -c < "$HT_STDOUT")" "status stdout bytes for domain [$domain]"
done
assert_calls notify-send "$notified_before_status" "status notifications"
ht_ok "status prints one typed JSON object, keeps unknown values null, reports provider failures as error and rejects bad domains"

# ---------------------------------------------------------------------------
# Representative provider: theme status before and after an apply

notified_before_theme=$(ht_calls notify-send)
ht_run "$status" theme
assert_status 0
assert_json "$HT_STDOUT" "keys == $status_keys and .domain == \"theme\" and .provider == \"hss-theme\"
    and .availability == \"unavailable\" and .state.variant == null and .state.default_variant == \"dark\"
    and (.error | type == \"string\")" "theme status before apply"
[[ ! -e $XDG_CONFIG_HOME/hss-theme ]] || ht_fail "status created theme state"

ht_run "$action" --json theme.set purple
assert_status 2 "invalid theme variant"
assert_json "$HT_STDOUT" '.outcome == "usage" and .exit_status == 2 and .action == "theme.set"'

# Contract section 8: runtime switching requires an installation that setup adopted.
ht_snapshot_tree "$XDG_CONFIG_HOME"
ht_run "$action" --json theme.set light
assert_status 7 "theme.set before adoption"
assert_json "$HT_STDOUT" '.outcome == "unavailable" and .exit_status == 7'
assert_tree_unchanged "$XDG_CONFIG_HOME" "configuration after theme.set before adoption"
assert_calls gsettings 0 "gsettings calls before adoption"
ht_theme_apply "$scripts" dark --adopt
assert_status 0 "adoption by the installer path"

ht_run "$action" --json theme.set light
assert_status 0 "theme.set light"
assert_eq 1 "$(wc -l < "$HT_STDOUT")" "theme.set --json stdout lines"
assert_json "$HT_STDOUT" '.outcome == "completed" and .provider == "hss-theme" and .observed.variant == "light"'
ht_snapshot_tree "$XDG_CONFIG_HOME"
ht_run "$status" theme
assert_json "$HT_STDOUT" '.availability == "available" and .state.variant == "light"
    and .capabilities.switch == "supported" and .error == null and (.state.batch | IN("complete", "partial"))' \
    "theme status after apply"
assert_tree_unchanged "$XDG_CONFIG_HOME" "configuration after a status query"

ht_run "$action" --json theme.toggle
assert_status 0 "theme.toggle"
ht_run "$status" theme
assert_json "$HT_STDOUT" '.state.variant == "dark"' "theme status after toggle"
assert_calls notify-send "$notified_before_theme" "theme notifications in --json mode"
ht_ok "theme status is unavailable before the first apply and reports the applied and toggled variant"
