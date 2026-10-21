#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal $ in shell programs and expected prompt text.
set -euo pipefail

# D05.2 shell environment and prompts: Bash and Fish start silently when noninteractive,
# keep TERM and locale, tolerate missing optional tools, theme their prompts natively and
# never evaluate branch names. Hermetic: fixture homes, PATH stubs, no network.
unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE DISPLAY BASH_ENV ENV STARSHIP_CONFIG

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/shell/theme_units_testlib.sh
source "$repo_root/tests/shell/theme_units_testlib.sh"
base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# A PATH with the base system but without optional prompt tools (zoxide, starship, lsd).
sysbin="$base/sysbin"
mkdir -p "$sysbin"
for tool in bash fish cat grep sed awk tr env sort find mkdir rm ls head tail printf touch stty id uname wc dirname basename readlink; do
  real=$(command -v "$tool") || continue
  ln -s "$real" "$sysbin/$tool"
done
stubs="$base/stubs"
mkdir -p "$stubs"

home="$base/home"
new_theme_home "$home"
run_in_home() {
  env -i HOME="$home" XDG_CONFIG_HOME="$home/.config" PATH="$stubs:$sysbin" TERM="${TEST_TERM:-xterm-256color}" LANG=C.UTF-8 "$@"
}

# Bash -----------------------------------------------------------------------------------
bash -n "$home/.bashrc" || fail ".bashrc syntax"
output=$(cd "$base" && run_in_home bash -c true 2>&1)
[[ -z $output ]] || fail "noninteractive bash prints: $output"
output=$(cd "$base" && run_in_home bash -l -c true 2>&1)
[[ -z $output ]] || fail "login noninteractive bash prints: $output"
printf 'ok - noninteractive and login Bash shells stay silent\n'

# A git double whose branch name contains command substitution.
cat > "$stubs/git" <<'STUB'
#!/bin/sh
[ "$1" = branch ] && printf '%s\n' '* main$(touch pwned)`touch pwned2`'
STUB
chmod +x "$stubs/git"
prompt_program='false; bash_prompt; printf "%s" "${PS1@P}"'
output=$(cd "$base" && run_in_home bash -i -c "$prompt_program" 2>"$base/bash.err")
[[ $output == *$'\001\e[34m\002'* ]] || fail "OS name uses ANSI slot 4 (accent): $(printf '%q' "$output")"
[[ $output == *$'\001\e[33m\002 (main$(touch pwned)`touch pwned2`)'* ]] || fail "branch shown literally in ANSI slot 3: $(printf '%q' "$output")"
[[ $output == *$'\001\e[31m\002 [1]'* ]] || fail "failed command shows a visible status cue: $(printf '%q' "$output")"
[[ ! -e $base/pwned && ! -e $base/pwned2 ]] || fail "branch name was evaluated by the prompt"
output=$(cd "$base" && run_in_home bash -i -c 'true; bash_prompt; printf "%s" "${PS1@P}"' 2>/dev/null)
[[ $output != *'['*']'* ]] || fail "successful commands show no status cue"
! grep -q 'command not found' "$base/bash.err" || fail "missing optional tools produce errors: $(cat "$base/bash.err")"
output=$(cd "$base" && TEST_TERM=foot run_in_home bash -i -c 'printf "%s" "$TERM"' 2>/dev/null)
[[ $output == foot ]] || fail "interactive Bash keeps the terminal's TERM (got $output)"
output=$(cd "$base" && run_in_home bash -i -c 'printf "%s|%s" "$LANG" "$LANGUAGE"' 2>/dev/null)
[[ $output == de_CH.UTF-8\|de_CH:en_US ]] || fail "Bash locale settings preserved (got $output)"
output=$(cd "$base" && run_in_home bash -i -c 'alias ll >/dev/null 2>&1; alias vim; alias zj' 2>/dev/null)
grep -Fq "alias vim='nvim'" <<<"$output" || fail "existing Bash vim alias preserved"
grep -Fq "alias zj='zellij'" <<<"$output" || fail "existing Bash zellij alias preserved"
printf 'ok - Bash prompt uses ANSI palette slots, shows failures, never evaluates branch names and keeps TERM, locale and aliases\n'

# Fish -----------------------------------------------------------------------------------
for file in "$home/.config/fish/config.fish" "$home/.config/fish/conf.d/"*.fish; do
  fish --no-execute "$file" || fail "fish syntax: $file"
done
! grep -Eq '^[[:space:]]*set (-U|--universal)' "$home/.config/fish/config.fish" || fail "config.fish writes universal variables"
output=$(cd "$base" && run_in_home fish -c true 2>&1)
[[ -z $output ]] || fail "noninteractive fish prints: $output"
output=$(cd "$base" && run_in_home fish -l -c true 2>&1)
[[ -z $output ]] || fail "login noninteractive fish prints: $output"
output=$(cd "$base" && env -i HOME="$home" XDG_CONFIG_HOME="$home/.config" PATH="/opt/hss-custom/bin:$stubs:$sysbin" fish -c 'string join : $PATH' 2>/dev/null)
[[ $output == /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:* ]] || fail "fish keeps its listed PATH order first: $output"
[[ :$output: == *:/opt/hss-custom/bin:* && :$output: == *":$stubs:"* ]] || fail "fish preserves inherited PATH additions: $output"
printf 'ok - noninteractive and login Fish shells stay silent without optional tools and keep inherited PATH additions\n'

# Before the theme is applied the frozen Fish theme stays in effect without errors.
# Interactive fish writes vi-mode cursor escapes to stdout, so values are read back via a file.
fish_value() {
  local program=$1
  rm -f "$base/fish.out"
  (cd "$base" && run_in_home FISH_OUT="$base/fish.out" fish -i -c "$program > \$FISH_OUT" 2>"$base/fish.err" </dev/null >/dev/null) || true
  cat "$base/fish.out" 2>/dev/null
}
output=$(fish_value 'printf "%s" "$fish_color_command"')
[[ $output == normal ]] || fail "frozen theme before theme generation (got $output)"
! grep -q 'Unknown command\|No such file' "$base/fish.err" || fail "fish startup errors: $(cat "$base/fish.err")"
make_member_roles "$base/fish-roles.json" shell=fish,bash
for variant in dark light; do
  theme_plan "$variant" "$base/fish-roles.json" "$home" "$base/plan-$variant" --adopt --units fish
  theme_commit "$base/plan-$variant"
  output=$(fish_value 'printf "%s|%s" "$fish_color_command" "$fish_pager_color_prefix"')
  case $variant in
    dark) [[ $output == '89b4fa|f5c2e7 --bold --underline' ]] || fail "dark fish colours win over the frozen theme (got $output)" ;;
    light) [[ $output == '1e66f5|ea76cb --bold --underline' ]] || fail "light fish colours (got $output)" ;;
  esac
done
grep -Fxq "    source '$home/.config/hss-theme/generated/fish/theme.fish'" "$home/.config/fish/config.fish" || fail "fish region uses the absolute generated path"
printf 'ok - generated Fish syntax and pager colours take precedence over fish_frozen_theme.fish in both variants\n'

# Starship stays optional; without a user config the repository ~/starship.toml is used.
cat > "$stubs/starship" <<'STUB'
#!/bin/sh
[ "$1" = init ] && printf '%s\n' "${STARSHIP_CONFIG-<unset>}" > "$STARSHIP_LOG"
exit 0
STUB
chmod +x "$stubs/starship"
log="$base/starship.log"
(cd "$base" && run_in_home STARSHIP_LOG="$log" fish -i -c true </dev/null >/dev/null 2>&1)
[[ $(<"$log") == "$home/starship.toml" ]] || fail "repository Starship configuration selected (got $(<"$log"))"
(cd "$base" && run_in_home STARSHIP_LOG="$log" STARSHIP_CONFIG=/custom/starship.toml fish -i -c true </dev/null >/dev/null 2>&1)
[[ $(<"$log") == /custom/starship.toml ]] || fail "user STARSHIP_CONFIG preserved"
mkdir -p "$home/.config"
: > "$home/.config/starship.toml"
(cd "$base" && run_in_home STARSHIP_LOG="$log" fish -i -c true </dev/null >/dev/null 2>&1)
[[ $(<"$log") == '<unset>' ]] || fail "user ~/.config/starship.toml takes precedence (got $(<"$log"))"
rm -f "$log" "$home/.config/starship.toml"
(cd "$base" && run_in_home STARSHIP_LOG="$log" fish -c true </dev/null >/dev/null 2>&1)
[[ ! -e $log ]] || fail "Starship is not initialised in noninteractive shells"
printf 'ok - Starship stays optional and only falls back to the repository configuration when the user has none\n'

# Setup's role-environment writers still find their Fish lines.
env_fish="$home/.config/fish/conf.d/01-env.fish"
for pattern in '^set -gx EDITOR ' '^set -gx VISUAL ' '^set -gx TERMINAL ' '^set -gx BROWSER ' '^set -gx LANG ' '^set -gx LANGUAGE '; do
  [[ $(grep -Ec "$pattern" "$env_fish") == 1 ]] || fail "01-env.fish keeps one line for $pattern"
done
printf 'ok - role-aware environment lines that setup rewrites are unchanged\n'
