#!/usr/bin/env bash
# Source-only helpers for the D04/D07 suites: an isolated installed layout and stateful
# command doubles. Doubles keep state in "$DT_STATE" and record argv NUL-separated, so a
# double that answers without changing state makes the contract tests fail.

dt_repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

dt_fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

dt_ok() {
    printf 'ok - %s\n' "$*"
}

# dt_setup ROOT: fresh HOME with the installed hypr/waybar scripts and an empty double bin.
dt_setup() {
    local root=$1
    unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY XDG_SESSION_ID
    export HOME="$root/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_STATE_HOME="$root/state"
    export XDG_RUNTIME_DIR="$root/runtime"
    export DT_STATE="$root/dt-state"
    export DT_BIN="$root/dt-bin"
    export STUB_LOG="$root/stub.log"
    mkdir -p "$XDG_CONFIG_HOME/hypr" "$XDG_CONFIG_HOME/waybar" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" \
        "$DT_STATE/proc" "$DT_STATE/last" "$DT_STATE/count" "$DT_STATE/units" "$DT_BIN"
    chmod 700 "$XDG_RUNTIME_DIR"
    : > "$STUB_LOG"
    cp -a "$dt_repo_root/dotfiles/.config/hypr/scripts" "$XDG_CONFIG_HOME/hypr/scripts"
    cp -a "$dt_repo_root/dotfiles/.config/waybar/scripts" "$XDG_CONFIG_HOME/waybar/scripts"
    export PATH="$DT_BIN:$PATH"
    dt_install_doubles
}

# dt_roles ROLE=PACKAGE...: schema-2 roles.json built from the catalog ({HOME} expanded).
dt_roles() {
    local pairs='{}' item
    for item in terminal=kitty "$@"; do
        pairs=$(jq -c --arg role "${item%%=*}" --arg package "${item#*=}" '. + {($role): $package}' <<<"$pairs")
    done
    jq --argjson pairs "$pairs" --arg home "$HOME" '
        def expand: walk(if type == "string" and startswith("{HOME}/") then $home + ltrimstr("{HOME}") else . end);
        . as $catalog
        | {schema_version: 2,
           roles: ($pairs | with_entries(.key as $role | .value as $package
                | .value = ($catalog.roles[$role].options[] | select(.package == $package) | expand))),
           selected: ($pairs | with_entries(.key as $role | .value as $package
                | .value = [$catalog.roles[$role].options[] | select(.package == $package) | expand])),
           agent_executables: {}}
    ' "$dt_repo_root/packages.json" > "$XDG_CONFIG_HOME/hypr/roles.json"
    jq -e --argjson pairs "$pairs" '[.roles[]] | length == ($pairs | length)' "$XDG_CONFIG_HOME/hypr/roles.json" >/dev/null \
        || dt_fail "unknown role package in: $*"
}

dt_state() {
    printf '%s\n' "$2" > "$DT_STATE/$1"
}

dt_read_state() {
    cat -- "$DT_STATE/$1" 2>/dev/null || printf '%s\n' "${2:-}"
}

dt_calls() {
    if [[ -e $DT_STATE/count/$1 ]]; then
        wc -l < "$DT_STATE/count/$1" | tr -d '[:space:]'
        printf '\n'
    else
        printf '0\n'
    fi
}

dt_reset_calls() {
    rm -f -- "$DT_STATE"/last/* "$DT_STATE"/count/*
}

# dt_wait_for NAME: wait until a detached double has recorded a call.
dt_wait_for() {
    local name=$1 attempt
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -s $DT_STATE/last/$name ]] && return 0
        sleep 0.05
    done
    dt_fail "$name was not started"
}

# dt_assert_argv NAME DESCRIPTION EXPECTED...: compare the last recorded argv of NAME.
dt_assert_argv() {
    local name=$1 description=$2 index=0 expected
    shift 2
    local -a actual=()
    [[ -e $DT_STATE/last/$name ]] || dt_fail "$description: $name was never called"
    mapfile -d '' actual < "$DT_STATE/last/$name"
    ((${#actual[@]} == $#)) || dt_fail "$description: expected $# argv fields, got ${#actual[@]}: ${actual[*]}"
    for expected in "$@"; do
        [[ ${actual[$index]} == "$expected" ]] || dt_fail "$description: argv[$index] expected '$expected', got '${actual[$index]}'"
        index=$((index + 1))
    done
}

# dt_action ACTION [ARG...]: run the installed dispatcher with --json; sets DT_OUT, DT_STATUS.
dt_action() {
    DT_STATUS=0
    DT_OUT=$("$XDG_CONFIG_HOME/hypr/scripts/action_exec.sh" --json "$@" 2>"$DT_STATE/action.err") || DT_STATUS=$?
}

# dt_expect STATUS OUTCOME DESCRIPTION: check the last dt_action result.
dt_expect() {
    local status=$1 outcome=$2 description=$3
    [[ $DT_STATUS == "$status" ]] || dt_fail "$description: exit $DT_STATUS, expected $status: $DT_OUT"
    jq -e --arg outcome "$outcome" --argjson status "$status" \
        '.schema == 1 and .outcome == $outcome and .exit_status == $status' <<<"$DT_OUT" >/dev/null \
        || dt_fail "$description: unexpected envelope $DT_OUT"
}

dt_status() {
    DT_OUT=$("$XDG_CONFIG_HOME/hypr/scripts/status_read.sh" "$1") || dt_fail "status_read.sh $1 failed"
    jq -e --arg domain "$1" '.schema == 1 and .domain == $domain' <<<"$DT_OUT" >/dev/null || dt_fail "bad status envelope: $DT_OUT"
}

# Generic recorder: last argv (NUL-separated) and a call counter per command name.
dt_recorder() {
    local name=$1 extra=${2:-}
    cat > "$DT_BIN/$name" <<EOF
#!/usr/bin/env bash
name=\${0##*/}
{ printf '%s\0' "\$name"; for arg in "\$@"; do printf '%s\0' "\$arg"; done; } > "\$DT_STATE/last/\$name.tmp"
mv -f -- "\$DT_STATE/last/\$name.tmp" "\$DT_STATE/last/\$name"
printf 'x\n' >> "\$DT_STATE/count/\$name"
$extra
exit 0
EOF
    chmod +x "$DT_BIN/$name"
}

dt_install_doubles() {
    local name
    for name in kitty nm-applet nm-connection-editor plasmawindowed kcmshell6 blueman-manager bluetui bluetuith \
        nmtui pavucontrol pavucontrol-qt qasmixer alsamixer ncpamixer notify-send pkill loginctl wlogout; do
        dt_recorder "$name"
    done
    # hyprlock: becomes a "running" process unless told to fail.
    # shellcheck disable=SC2016 # expanded inside the generated double
    dt_recorder hyprlock '[[ $(cat "$DT_STATE/hyprlock_mode" 2>/dev/null) == fail ]] || touch "$DT_STATE/proc/hyprlock"'

    cat > "$DT_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
# pgrep double: -x NAME checks $DT_STATE/proc/NAME; -f REGEX matches $DT_STATE/proc/*.cmdline.
mode=exact list=false
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) shift ;;
    -x) mode=exact ;;
    -f) mode=full ;;
    -a) list=true ;;
    --) shift; args+=("$@"); break ;;
    *) args+=("$1") ;;
  esac
  shift
done
pattern=${args[0]:-}
if [[ $mode == exact ]]; then
  [[ -e $DT_STATE/proc/$pattern ]]
  exit
fi
found=1
for file in "$DT_STATE"/proc/*.cmdline; do
  [[ -e $file ]] || continue
  line=$(<"$file")
  if grep -Eq -- "$pattern" <<<"$line"; then
    found=0
    if $list; then printf '4242 %s\n' "$line"; else printf '4242\n'; fi
  fi
done
exit "$found"
EOF

    cat > "$DT_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
{ printf 'systemctl\0'; for arg in "$@"; do printf '%s\0' "$arg"; done; } > "$DT_STATE/last/systemctl"
printf '%s\n' "$*" >> "$DT_STATE/systemctl.log"
[[ ${1:-} == --user ]] && shift
case "${1:-}" in
  is-active)
    unit=${!#}
    [[ $(cat "$DT_STATE/units/$unit" 2>/dev/null) == active ]] ;;
  show)
    unit=${!#}
    if [[ -e $DT_STATE/user_manager_down ]]; then echo "Failed to connect to bus" >&2; exit 1; fi
    if [[ -e $DT_STATE/units/$unit.missing ]]; then echo not-found; else echo loaded; fi ;;
  start)
    unit=$2
    case "$(cat "$DT_STATE/start_mode" 2>/dev/null)" in
      fail) exit 1 ;;
      dies) exit 0 ;;
      *) echo active > "$DT_STATE/units/$unit"; exit 0 ;;
    esac ;;
  poweroff|reboot|suspend|hibernate)
    printf '%s\n' "$1" >> "$DT_STATE/power.log"
    if [[ $(cat "$DT_STATE/power_mode" 2>/dev/null) == denied ]]; then
      echo "Failed to $1 system via logind: Access denied" >&2; exit 1
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF

    cat > "$DT_BIN/busctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DT_STATE/busctl.log"
case "$*" in
  *NameHasOwner*org.bluez*)
    case "$(cat "$DT_STATE/bluez_owner" 2>/dev/null || echo true)" in
      true) echo "b true" ;; false) echo "b false" ;; *) exit 1 ;;
    esac ;;
  *CanHibernate*)
    value=$(cat "$DT_STATE/can_hibernate" 2>/dev/null || echo na)
    [[ $value == fail ]] && exit 1
    printf 's "%s"\n' "$value" ;;
  *) exit 1 ;;
esac
EOF

    cat > "$DT_BIN/hyprctl" <<'EOF'
#!/usr/bin/env bash
{ printf 'hyprctl\0'; for arg in "$@"; do printf '%s\0' "$arg"; done; } > "$DT_STATE/last/hyprctl"
printf '%s\n' "$*" >> "$DT_STATE/hyprctl.log"
case "${1:-}" in
  dispatch)
    case "$(cat "$DT_STATE/hyprctl_mode" 2>/dev/null || echo lua)" in
      lua) [[ $2 == 'hl.dsp.exit()' ]] && echo ok || echo "Invalid dispatcher" ;;
      legacy) [[ $2 == exit ]] && echo ok || echo "Invalid dispatcher, requested \"$2\"" ;;
      broken) echo "error: no instance" ; exit 1 ;;
    esac ;;
  clients) echo '[]' ;;
  monitors) echo '[{"focused":true,"width":1920,"height":1080}]' ;;
  *) echo ok ;;
esac
EOF

    cat > "$DT_BIN/nmcli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DT_STATE/nmcli.log"
nm=$(cat "$DT_STATE/nm_running" 2>/dev/null || echo running)
if [[ $nm != running ]]; then echo "Error: NetworkManager is not running." >&2; exit 8; fi
radio=$(cat "$DT_STATE/nm_wifi" 2>/dev/null || echo enabled)
case "$*" in
  "radio wifi") echo "$radio" ;;
  "radio wifi on"|"radio wifi off")
    [[ -e $DT_STATE/nm_denied ]] && { echo "Error: Not authorized to enable/disable Wi-Fi." >&2; exit 1; }
    [[ -e $DT_STATE/nm_lies ]] && exit 0
    [[ $3 == on ]] && echo enabled > "$DT_STATE/nm_wifi" || echo disabled > "$DT_STATE/nm_wifi" ;;
  "-t -f WIFI-HW general") cat "$DT_STATE/nm_wifi_hw" 2>/dev/null || echo enabled ;;
  "-t -f RUNNING,STATE,CONNECTIVITY,WIFI-HW,WIFI general")
    printf 'running:%s:%s:%s:%s\n' "$(cat "$DT_STATE/nm_state" 2>/dev/null || echo connected)" \
      "$(cat "$DT_STATE/nm_connectivity" 2>/dev/null || echo full)" "$(cat "$DT_STATE/nm_wifi_hw" 2>/dev/null || echo enabled)" "$radio" ;;
  "-t -f TYPE,STATE device") cat "$DT_STATE/nm_devices" 2>/dev/null || printf 'wifi:connected\nethernet:unavailable\nloopback:connected (externally)\n' ;;
  "-t -f IN-USE,SIGNAL device wifi list --rescan no") printf ' :41\n*:72\n' ;;
  *) echo "unexpected nmcli call: $*" >&2; exit 2 ;;
esac
EOF

    cat > "$DT_BIN/bluetoothctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DT_STATE/bluetoothctl.log"
mode=$(cat "$DT_STATE/bt_mode" 2>/dev/null || echo ok)
case "$mode" in
  hang) sleep 30 ;;
  abort) echo 'dbus[1]: assertion "connection != NULL" failed' >&2; exit 134 ;;
esac
controller=$(cat "$DT_STATE/bt_controller" 2>/dev/null || echo present)
powered=$(cat "$DT_STATE/bt_powered" 2>/dev/null || echo yes)
blocked=$(cat "$DT_STATE/bt_blocked" 2>/dev/null || echo no)
case "$*" in
  list) [[ $controller == present ]] && echo "Controller 00:11:22:33:44:55 Private Laptop Name [default]"; exit 0 ;;
  show)
    [[ $controller == present ]] || { echo "No default controller available"; exit 1; }
    state=off; [[ $powered == yes ]] && state=on; [[ $blocked == yes ]] && state=off-blocked
    printf 'Controller 00:11:22:33:44:55 (public)\n\tName: Private Laptop Name\n\tPowered: %s\n\tPowerState: %s\n\tDiscoverable: no\n' "$powered" "$state" ;;
  "power on"|"power off")
    [[ $controller == present ]] || { echo "No default controller available"; exit 1; }
    [[ -e $DT_STATE/bt_lies ]] && { echo "Changing power ${2} succeeded"; exit 0; }
    [[ $2 == on ]] && echo yes > "$DT_STATE/bt_powered" || echo no > "$DT_STATE/bt_powered"
    echo "Changing power ${2} succeeded" ;;
  "devices Connected")
    for ((i = 0; i < $(cat "$DT_STATE/bt_connected" 2>/dev/null || echo 0); i++)); do
      printf 'Device AA:BB:CC:DD:EE:0%s Secret Headphones %s\n' "$i" "$i"
    done ;;
  *) echo "unexpected bluetoothctl call: $*" >&2; exit 2 ;;
esac
EOF

    cat > "$DT_BIN/wpctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DT_STATE/wpctl.log"
[[ $(cat "$DT_STATE/pw_server" 2>/dev/null || echo up) == up ]] || { echo "Could not connect to PipeWire" >&2; exit 1; }
case "$*" in
  status) echo "PipeWire 'pipewire-0' [1.6.9]" ;;
  "get-volume @DEFAULT_AUDIO_SINK@")
    value=$(cat "$DT_STATE/pw_sink" 2>/dev/null || echo "0.35 [MUTED]")
    [[ $value == none ]] && { echo "Translate ID error: '-1' is not a valid ID (returned by default-nodes-api)" >&2; exit 0; }
    echo "Volume: $value" ;;
  "get-volume @DEFAULT_AUDIO_SOURCE@")
    value=$(cat "$DT_STATE/pw_source" 2>/dev/null || echo "1.00")
    [[ $value == none ]] && { echo "Translate ID error: '-1' is not a valid ID (returned by default-nodes-api)" >&2; exit 0; }
    echo "Volume: $value" ;;
  *) exit 2 ;;
esac
EOF

    cat > "$DT_BIN/pactl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DT_STATE/pactl.log"
[[ $(cat "$DT_STATE/pa_server" 2>/dev/null || echo up) == up ]] || { echo "Connection failure: Connection refused" >&2; exit 1; }
case "$*" in
  info) printf 'Server String: /run/user/1000/pulse/native\nServer Name: pulseaudio\n' ;;
  "get-sink-volume @DEFAULT_SINK@") echo "Volume: front-left: 26214 /  40% / -23.88 dB,   front-right: 26214 /  40% / -23.88 dB" ;;
  "get-sink-mute @DEFAULT_SINK@") echo "Mute: no" ;;
  "get-source-volume @DEFAULT_SOURCE@") echo "Volume: mono: 65536 / 100% / 0.00 dB" ;;
  "get-source-mute @DEFAULT_SOURCE@") echo "Mute: yes" ;;
  *) exit 2 ;;
esac
EOF

    # Shared chooser double, installed where the providers look for it.
    cat > "$XDG_CONFIG_HOME/hypr/scripts/menu_choose.sh" <<'EOF'
#!/usr/bin/env bash
{ printf 'menu_choose.sh\0'; for arg in "$@"; do printf '%s\0' "$arg"; done; } > "$DT_STATE/last/menu_choose.sh"
printf 'x\n' >> "$DT_STATE/count/menu_choose.sh"
case "$(cat "$DT_STATE/menu" 2>/dev/null || echo cancel)" in
  yes) echo yes; exit 0 ;;
  cancel) exit 3 ;;
  fail) exit 1 ;;
esac
EOF
    chmod +x "$DT_BIN"/* "$XDG_CONFIG_HOME/hypr/scripts/menu_choose.sh"
}

# dt_restricted_path: PATH with core tools only (no device or audio commands).
dt_restricted_path() {
    local dir="$DT_STATE/restricted-bin" tool path
    mkdir -p "$dir"
    for tool in bash sh env jq awk grep sed date timeout head tail tr cat mkdir mktemp rm mv dirname basename id \
        setsid sleep cut wc sort printf realpath; do
        path=$(command -v "$tool" 2>/dev/null) || continue
        [[ $path == /* ]] && ln -sf "$path" "$dir/$tool"
    done
    ln -sf "$DT_BIN/pgrep" "$dir/pgrep"
    ln -sf "$DT_BIN/notify-send" "$dir/notify-send"
    printf '%s\n' "$dir"
}
