#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs and bash -c scripts are single-quoted on purpose.
set -euo pipefail
# F03 activation assertions (plan F03.5/F03.6 with F04 doubles): declared signal, reload,
# gsettings and deferred steps run only against modeled running processes and available
# settings, pass argv literally, never launch absent applications and report deferred work as
# pending. Evidence level: argv and modeled-effect; no real application is signalled.
# shellcheck source=tests/shell/harmonization_testlib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/harmonization_testlib.sh"
ht_fixture_init

runtime="$HT_ROOT/hypr"
ht_copy_runtime "$runtime"
scripts="$runtime/scripts"
# Foundation suite: only the core theme registry plus this suite's fixture fragment.
rm -rf -- "$runtime/theme/units.d"
uid=$(id -u)

# step UNIT STEP_JSON: run hss_theme_activate_step; its notes land in $HT_STDOUT.
step() {
    ht_run "$BASH" -c 'source "$1/lib/hss_runtime.sh"; source "$1/providers/theme.sh"; hss_theme_activate_step "$2" "$3"' \
        _ "$scripts" "$1" "$2"
}
gsettings_sets() {
    local count index
    count=$(ht_calls gsettings)
    for ((index = 1; index <= count; index++)); do
        [[ $(head -c4 "$HT_STATE/calls/gsettings.$index" | tr '\0' ' ') == 'set ' ]] \
            && tr '\0' ' ' < "$HT_STATE/calls/gsettings.$index" && printf '\n'
    done
    return 0
}

# ---------------------------------------------------------------------------
# signal

step fx '{"kind":"signal","process":"kitty","signal":"USR1"}'
assert_status 0
assert_eq "" "$(cat "$HT_STDOUT")" "notes for an absent signal target"
assert_argv pgrep 1 -u "$uid" -x -- kitty
assert_calls pkill 0 "pkill calls for an absent process"
ht_proc_start kitty-helper
step fx '{"kind":"signal","process":"kitty","signal":"USR1"}'
assert_calls pkill 0 "pkill calls when only a similarly named process runs"
ht_proc_start kitty
step fx '{"kind":"signal","process":"kitty","signal":"USR1"}'
assert_eq "" "$(cat "$HT_STDOUT")" "notes for a delivered signal"
assert_argv pkill 1 -u "$uid" -x -USR1 -- kitty
assert_eq 'kitty USR1' "$(ht_signals)" "signals delivered"
ht_double_exit pkill 3
step fx '{"kind":"signal","process":"kitty","signal":"HUP"}'
assert_eq 'fx: could not signal kitty' "$(cat "$HT_STDOUT")" "note for a failed signal"
assert_eq 'kitty USR1' "$(ht_signals)" "signals after a failed delivery"
rm -f -- "$HT_STATE/exit/pkill"
ht_ok "signals go only to an exactly named running process of this user and failures are reported"

# ---------------------------------------------------------------------------
# reload

ht_double fake-reload
ht_double fake-app
reload_step='{"kind":"reload","argv":["fake-reload","--config","a b","$(touch '"$HT_ROOT"'/pwned)",""],"process":"fake-app"}'
step fx "$reload_step"
assert_eq "" "$(cat "$HT_STDOUT")" "notes for a reload of an absent application"
assert_calls fake-reload 0 "reload calls while the application is absent"
ht_proc_start fake-app
step fx "$reload_step"
assert_eq "" "$(cat "$HT_STDOUT")" "notes for a successful reload"
assert_argv fake-reload 1 --config 'a b' "\$(touch $HT_ROOT/pwned)" ''
[[ ! -e $HT_ROOT/pwned ]] || ht_fail "a reload argument was evaluated"
step fx '{"kind":"reload","argv":["fake-reload","--always"]}'
assert_argv fake-reload 2 --always
ht_double_exit fake-reload 1
step fx '{"kind":"reload","argv":["fake-reload"],"process":"fake-app"}'
assert_eq 'fx: reload command fake-reload failed; restart it to apply the theme' "$(cat "$HT_STDOUT")" "failed reload note"
rm -f -- "$HT_STATE/exit/fake-reload"
step fx '{"kind":"reload","argv":["fake-missing","--reload"],"process":"fake-app"}'
assert_eq 'fx: fake-missing is not installed' "$(cat "$HT_STDOUT")" "missing reload command note"
ht__write_double fake-hang <<'BODY'
exec sleep 30
BODY
start=$SECONDS
step fx '{"kind":"reload","argv":["fake-hang"]}'
((SECONDS - start <= 9)) || ht_fail "a hanging reload command was not bounded"
assert_eq 'fx: reload command fake-hang failed; restart it to apply the theme' "$(cat "$HT_STDOUT")" "hanging reload note"
assert_calls fake-app 0 "launches of the application itself"
ht_ok "reload argv is passed literally once, skipped while its process is absent, bounded and reported on failure"

# ---------------------------------------------------------------------------
# gsettings

gtk_step='{"kind":"gsettings","schema":"org.gnome.desktop.interface","key":"gtk-theme","value":"Breeze-Dark"}'
step fx "$gtk_step"
assert_eq 'fx: org.gnome.desktop.interface gtk-theme is unavailable, so it applies after login' "$(cat "$HT_STDOUT")" \
    "note for an unknown schema"
ht_gsettings_seed org.gnome.desktop.interface gtk-theme "'Adwaita'" readonly
step fx "$gtk_step"
assert_eq 'fx: org.gnome.desktop.interface gtk-theme is unavailable, so it applies after login' "$(cat "$HT_STDOUT")" \
    "note for a key locked by the administrator"
assert_eq "" "$(gsettings_sets)" "set calls for unavailable keys"
rm -f -- "$HT_STATE/gsettings/org.gnome.desktop.interface/gtk-theme.readonly"
ht_gsettings_seed org.gnome.desktop.interface icon-theme "'breeze-dark'"
step fx '{"kind":"gsettings","schema":"org.gnome.desktop.interface","key":"icon-theme","value":"breeze-dark"}'
assert_eq "" "$(cat "$HT_STDOUT")" "notes for an unchanged key"
assert_eq "" "$(gsettings_sets)" "set calls for an unchanged key"
step fx "$gtk_step"
assert_eq "" "$(cat "$HT_STDOUT")" "notes for a changed key"
assert_eq 'set org.gnome.desktop.interface gtk-theme Breeze-Dark ' "$(gsettings_sets)" "set calls"
assert_eq "'Breeze-Dark'" "$(ht_gsettings_value org.gnome.desktop.interface gtk-theme)" "gtk-theme read back"
ht_gsettings_seed org.gnome.desktop.interface cursor-size 24
step fx '{"kind":"gsettings","schema":"org.gnome.desktop.interface","key":"cursor-size","value":"24"}'
assert_eq 1 "$(gsettings_sets | wc -l)" "set calls for an equal integer"
gsettings_path=$(ht_restricted_path timeout id jq dirname)
ht_run env PATH="${gsettings_path#"$HT_BIN:"}" "$BASH" -c 'source "$1/lib/hss_runtime.sh"; source "$1/providers/theme.sh"; hss_theme_activate_step fx "$2"' \
    _ "$scripts" "$gtk_step"
assert_eq 'fx: org.gnome.desktop.interface gtk-theme is unavailable, so it applies after login' "$(cat "$HT_STDOUT")" \
    "note without gsettings"
ht_ok "gsettings is set only when available, writable and different, and reports pending otherwise"

# A double that claims success without changing state must be caught by the read-back oracle.
cp -- "$HT_BIN/gsettings" "$HT_ROOT/gsettings.honest"
ht__write_double gsettings <<'BODY'
case ${1-} in
    writable) printf 'true\n' ;;
    get) printf "'Adwaita'\n" ;;
esac
exit 0
BODY
ht_gsettings_seed org.gnome.desktop.interface gtk-theme "'Adwaita'"
step fx "$gtk_step"
assert_eq 0 "$HT_STATUS" "activation with a lying double"
ht_expect_failure assert_eq "'Breeze-Dark'" "$(ht_gsettings_value org.gnome.desktop.interface gtk-theme)" "gtk-theme read back"
cp -- "$HT_ROOT/gsettings.honest" "$HT_BIN/gsettings"
ht_ok "a double that reports success without changing state fails the read-back assertion"

# ---------------------------------------------------------------------------
# Deferred steps

step fx '{"kind":"next-launch"}'
assert_eq 'fx: applies the next time the application starts' "$(cat "$HT_STDOUT")" "next-launch note"
step fx '{"kind":"relogin"}'
assert_eq 'fx: applies after the next login' "$(cat "$HT_STDOUT")" "relogin note"
ht_ok "next-launch and relogin steps are reported as deferred work"

# ---------------------------------------------------------------------------
# End to end through the provider

theme="$runtime/theme"
mkdir -p -- "$theme/units.d" "$theme/templates/fx"
printf 'variant {{variant}}\n' > "$theme/templates/fx/app.conf.tmpl"
cat > "$theme/units.d/90-activation.json" <<'JSON'
{
  "schema_version": 1,
  "units": [
    {"id": "fx-app", "owner": "F04", "description": "fixture", "applies": {"always": true}, "depends": ["theme-core"],
     "outputs": [{"target": "theme:generated/fx/app.conf", "class": "generated", "template": "fx/app.conf.tmpl"}],
     "activation": [
       {"kind": "reload", "argv": ["fake-reload", "--variant", "{{variant}}"], "process": "fake-app"},
       {"kind": "signal", "process": "fake-app", "signal": "HUP"},
       {"kind": "next-launch"}
     ]},
    {"id": "fx-absent", "owner": "F04", "description": "fixture", "applies": {"always": true}, "depends": ["theme-core"],
     "outputs": [{"target": "theme:generated/fx/absent.conf", "class": "generated", "template": "fx/app.conf.tmpl"}],
     "activation": [
       {"kind": "reload", "argv": ["absent-app", "--reload"], "process": "absent-app"},
       {"kind": "signal", "process": "absent-app", "signal": "USR1"}
     ]}
  ]
}
JSON
python3 -B "$theme/hss_theme.py" check >/dev/null || ht_fail "activation fixture registry was rejected"
ht_double absent-app
rm -f -- "$HT_STATE"/calls/fake-reload.* "$HT_STATE"/calls/gsettings.* "$HT_STATE"/calls/pkill.*
: > "$HT_STATE/signals"
ht_gsettings_seed org.gnome.desktop.interface gtk-theme "'Adwaita'"
ht_gsettings_seed org.gnome.desktop.interface color-scheme "'default'"
ht_proc_stop kitty

ht_theme_apply "$scripts" dark --adopt
assert_status 0 "first apply"
assert_json "$HT_STDOUT" '.outcome == "completed" and .reason == "theme dark applied"'
report=$(jq -r .report "$HT_STDOUT")
assert_argv fake-reload 1 --variant dark
assert_eq 'fake-app HUP' "$(ht_signals)" "signals after the first apply"
assert_eq $'set org.gnome.desktop.interface gtk-theme Breeze-Dark \nset org.gnome.desktop.interface color-scheme prefer-dark ' \
    "$(gsettings_sets)" "gsettings changes"
assert_json "$report" '(.pending | index("fx-app: applies the next time the application starts")) != null
    and (.pending | index("desktop-fonts-cursor: applies after the next login")) != null
    and (.pending | index("gtk4: org.gnome.desktop.interface accent-color is unavailable, so it applies after login")) != null' \
    "pending work"
# Every pending entry must name its unit; notes never contain the "; " separator.
orphans=$(jq -r '.pending[] | select(test("^[a-z0-9-]+: ") | not)' "$report")
[[ -z $orphans ]] || ht_fail "pending entries without a unit: $orphans"
assert_json "$HT_STDOUT" '.pending | contains("fx-app: applies the next time the application starts")'
assert_calls absent-app 0 "launches of an absent application"
assert_calls fake-app 0 "launches of a running application"

gsettings_before=$(ht_calls gsettings)
ht_theme_apply "$scripts" dark
assert_status 0 "unchanged apply"
(($(ht_calls gsettings) > gsettings_before)) || ht_fail "an unchanged apply did not re-read the gsettings steps"
assert_calls fake-reload 1 "reloads after an unchanged apply"
assert_eq 'fake-app HUP' "$(ht_signals)" "signals after an unchanged apply"
assert_eq 2 "$(gsettings_sets | wc -l)" "gsettings changes after an unchanged apply"

ht_proc_stop fake-app
ht_theme_apply "$scripts" light
assert_status 0 "apply while the application is closed"
assert_calls fake-reload 1 "reloads while the application is closed"
assert_eq 'fake-app HUP' "$(ht_signals)" "signals while the application is closed"
assert_json "$(jq -r .report "$HT_STDOUT")" '(.pending | index("fx-app: applies the next time the application starts")) != null'
assert_calls absent-app 0 "launches of an absent application"
assert_calls fake-app 0 "launches of a closed application"
ht_ok "the provider activates running applications once per change, reapplies only settings and never launches absent apps"
