#!/usr/bin/env bash
set -euo pipefail

roles_file=${HSS_ROLES_FILE:-$HOME/.config/hypr/roles.json}
title=""
app_id=""
cwd=""
cwd_set=false

usage() {
  cat <<'EOF'
Usage:
  term_exec.sh [--app-id APP_ID] [--title TITLE] [--cwd DIR] -- <command> [args...]

--cwd DIR starts the command in DIR. DIR must be an existing, accessible
directory; otherwise nothing is launched. Without --cwd the terminal keeps
the working directory inherited from the caller.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      app_id=$2
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      title=$2
      shift 2
      ;;
    --cwd)
      [[ $# -ge 2 && -n $2 ]] || { usage >&2; exit 2; }
      cwd=$2
      cwd_set=true
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) break ;;
  esac
done

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
[[ -r "$roles_file" ]] || { printf 'Missing role data: %s\n' "$roles_file" >&2; exit 1; }
[[ -z "$app_id" || "$app_id" =~ ^[A-Za-z0-9._+-]+$ ]] || { printf 'Invalid app ID\n' >&2; exit 2; }

if $cwd_set; then
  # Validate literally (no shell expansion) and fail instead of silently opening HOME.
  if [[ ! -d $cwd ]]; then
    printf 'term_exec.sh: working directory does not exist or is not a directory: %s\n' "$cwd" >&2
    exit 2
  fi
  if [[ ! -r $cwd || ! -x $cwd ]]; then
    printf 'term_exec.sh: working directory is not accessible: %s\n' "$cwd" >&2
    exit 2
  fi
  # An absolute path cannot be mistaken for a terminal option.
  cwd=$(CDPATH='' cd -- "$cwd" && pwd) || {
    printf 'term_exec.sh: cannot enter working directory: %s\n' "$cwd" >&2
    exit 2
  }
  cd -- "$cwd"
fi

package=$(jq -er '.roles.terminal.package' "$roles_file")
terminal=$(jq -er '.roles.terminal.executable' "$roles_file")
mapfile -t terminal_args < <(jq -r '.roles.terminal.args[]?' "$roles_file")

case "$package" in
  kitty)
    [[ -z "$app_id" ]] || terminal_args+=(--class "$app_id")
    [[ -z "$title" ]] || terminal_args+=(--title "$title")
    ! $cwd_set || terminal_args+=(--directory "$cwd")
    exec "$terminal" "${terminal_args[@]}" -e "$@"
    ;;
  alacritty)
    [[ -z "$app_id" ]] || terminal_args+=(--class "$app_id")
    [[ -z "$title" ]] || terminal_args+=(--title "$title")
    ! $cwd_set || terminal_args+=(--working-directory "$cwd")
    exec "$terminal" "${terminal_args[@]}" -e "$@"
    ;;
  ghostty)
    [[ -z "$app_id" ]] || terminal_args+=("--class=$app_id")
    [[ -z "$title" ]] || terminal_args+=("--title=$title")
    ! $cwd_set || terminal_args+=("--working-directory=$cwd")
    exec "$terminal" "${terminal_args[@]}" -e "$@"
    ;;
  foot)
    [[ -z "$app_id" ]] || terminal_args+=("--app-id=$app_id")
    [[ -z "$title" ]] || terminal_args+=("--title=$title")
    ! $cwd_set || terminal_args+=("--working-directory=$cwd")
    exec "$terminal" "${terminal_args[@]}" "$@"
    ;;
  konsole)
    # Konsole has no app-ID flag. Consumers match a fixed tab title instead.
    [[ -z "$app_id" ]] || title=$app_id
    terminal_args+=(--separate)
    [[ -z "$title" ]] || terminal_args+=(-p "tabtitle=$title")
    ! $cwd_set || terminal_args+=(--workdir "$cwd")
    exec "$terminal" "${terminal_args[@]}" -e "$@"
    ;;
  *)
    printf 'Unsupported terminal role package: %s\n' "$package" >&2
    exit 1
    ;;
esac
