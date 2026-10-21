#!/usr/bin/env bash

set -euo pipefail

roles_file=${HSS_ROLES_FILE:-$HOME/.config/hypr/roles.json}

die() {
  local msg="$1"
  printf '%s\n' "repos_wofi.sh: $msg" >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u normal -a "hypr" "repos_wofi.sh" "$msg" >/dev/null 2>&1 || true
  fi
}

format_repo_label() {
  local abs="$1"

  # If there's a .../Github/<repo> or .../GitHub/<repo> segment, strip everything up to it.
  if [[ "$abs" == *"/Github/"* ]]; then
    printf '%s' "${abs#*"/Github/"}"
    return 0
  fi
  if [[ "$abs" == *"/GitHub/"* ]]; then
    printf '%s' "${abs#*"/GitHub/"}"
    return 0
  fi

  # Otherwise, keep $HOME-relative if possible.
  if [[ "$abs" == "$HOME" ]]; then
    return 1
  elif [[ "$abs" == "$HOME/"* ]]; then
    printf '%s' "${abs#"$HOME/"}"
    return 0
  fi

  # Fallback: absolute path.
  printf '%s' "$abs"
}

discover_git_repos() {
  # Defaulting to filesystem root (/) makes discovery expensive/noisy on most systems:
  # it traverses many unrelated/unreadable directories and can slow down the picker.
  # Prefer user locations by default; opt in to scanning / via REPOS_WOFI_INCLUDE_ROOT=1
  # or by explicitly listing / in REPOS_WOFI_ROOTS.
  local -a roots=()
  local max_depth="${REPOS_WOFI_MAX_DEPTH:-6}"

  if [[ -n "${REPOS_WOFI_ROOTS:-}" ]]; then
    # Colon-separated list of roots, e.g. "$HOME:$HOME/GitHub:/mnt/SSD_NVME_4TB/GitHub"
    IFS=':' read -r -a roots <<<"${REPOS_WOFI_ROOTS}"
  else
    roots=(
      "$HOME"
      "$HOME/GitHub"
      "$HOME/Github"
      "$HOME/Projects"
    )
    if [[ "${REPOS_WOFI_INCLUDE_ROOT:-0}" == "1" ]]; then
      roots+=("/")
    fi
  fi

  local root
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue

    if command -v fd >/dev/null 2>&1; then
      fd -H -I -t d --max-depth "$max_depth" \
        --exclude ".cache" --exclude ".claude" --exclude ".cargo" --exclude ".local" \
        --exclude "proc" --exclude "sys" --exclude "dev" --exclude "run" --exclude "tmp" \
        --exclude "System_BackUp" \
        -0 '^\.git$' "$root" \
        | xargs -0 -r dirname -z --
    else
      # Fallback: slower than fd, but always available.
      find "$root" -maxdepth "$max_depth" \
        \( -path /proc -o -path /proc/\* -o -path /sys -o -path /sys/\* -o -path /dev -o -path /dev/\* -o -path /run -o -path /run/\* -o -path /tmp -o -path /tmp/\* -o -path /var/cache -o -path /var/cache/\* -o -path /var/tmp -o -path /var/tmp/\* -o -path /mnt/SSD_NVME_4TB/System_BackUp -o -path /mnt/SSD_NVME_4TB/System_BackUp/\* \) -prune -o \
        \( -type d \( -name ".cache" -o -name ".claude" -o -name ".cargo" -o -name ".local" \) -prune \) -o \
        \( -type d -name .git -print0 \) 2>/dev/null \
        | xargs -0 -r dirname -z --
    fi
  done | sort -zu
}

# Collect repos. Paths stay NUL-separated so every directory name keeps its identity.
mapfile -d '' repos < <(discover_git_repos || true)
(( ${#repos[@]} > 0 )) || { die "No git repos found (max depth: ${REPOS_WOFI_MAX_DEPTH:-6}). Configure search roots via REPOS_WOFI_ROOTS or set REPOS_WOFI_INCLUDE_ROOT=1."; exit 1; }

# Offer one chooser record per repository. The record ID, not the label, selects the path;
# menu_choose.sh disambiguates repeated labels and refuses anything that is not offered.
repo_paths=()
records=""
for abs in "${repos[@]}"; do
  [[ -n "$abs" ]] || continue
  label="$(format_repo_label "$abs" || true)"
  [[ -n "${label:-}" ]] || continue
  records+="r${#repo_paths[@]}"$'\t'"${label//$'\n'/ }"$'\n'
  repo_paths+=("$abs")
done
(( ${#repo_paths[@]} > 0 )) || { die "No git repos found (after filtering)"; exit 1; }

[[ -r "$roles_file" ]] || { die "Missing role data: $roles_file"; exit 1; }
status=0
chosen_id="$(printf '%s' "$records" | "$HOME/.config/hypr/scripts/menu_choose.sh" --prompt Repositories)" || status=$?
case "$status" in
  0) ;;
  3) exit 0 ;;
  *) die "Repository selection failed (menu status $status)"; exit 1 ;;
esac

if [[ ! "$chosen_id" =~ ^r(0|[1-9][0-9]{0,8})$ ]] || (( ${chosen_id#r} >= ${#repo_paths[@]} )); then
  die "Failed to map the selection to a repository"
  exit 1
fi
chosen_abs="${repo_paths[${chosen_id#r}]}"

if [[ "$chosen_abs" = /* ]]; then
  dir="$chosen_abs"
else
  dir="$HOME/$chosen_abs"
fi
if [[ ! -d "$dir" ]]; then
  die "Chosen repo directory not found: $dir"
  exit 1
fi

editor=$(jq -er '.roles.tui_editor.editor_bin' "$roles_file")
cd "$dir"
exec "$HOME/.config/hypr/scripts/term_exec.sh" --app-id hss-repos --title "$(basename "$dir")" -- "$editor" .
