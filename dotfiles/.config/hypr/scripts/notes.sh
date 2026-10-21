#!/usr/bin/env bash
set -euo pipefail

roles_file=${HSS_ROLES_FILE:-$HOME/.config/hypr/roles.json}
if [[ -z "${INSIDE_HSS_NOTES:-}" ]]; then
  exec env INSIDE_HSS_NOTES=1 "$HOME/.config/hypr/scripts/term_exec.sh" \
    --app-id hss-notes --title Notes -- bash "$0" "$@"
fi

editor=$(jq -er '.roles.tui_editor.editor_bin' "$roles_file")
notes_dir=${HSS_NOTES_DIR:-$HOME/Dokumente/0_Notes}
mkdir -p "$notes_dir"

# Resolve a note name inside the notes directory. Subdirectories are allowed; "..", absolute
# paths and symbolic links that lead outside the notes directory are refused.
note_path() {
  local name=$1 root target
  [[ -n $name && $name != /* ]] || return 1
  root=$(realpath -m -- "$notes_dir") || return 1
  target=$(realpath -m -- "$root/$name") || return 1
  [[ $target == "$root"/* ]] || return 1
  printf '%s\n' "$target"
}

read -rp "Do you want to create a new file? (Y/n) " choice
if [[ "$choice" =~ ^[Yy]$|^$ ]]; then
  read -rp "Name your new note file: " new_file
  base_name=${new_file##*/}
  [[ "$base_name" == *.* ]] || new_file=${new_file}.txt
  if ! note_file=$(note_path "$new_file"); then
    printf 'Invalid note name: use a name inside %s\n' "$notes_dir" >&2
    exit 2
  fi
  [[ -d ${note_file%/*} ]] || { printf 'Folder does not exist: %s\n' "${note_file%/*}" >&2; exit 1; }
  touch -- "$note_file"
  exec "$editor" "$note_file"
fi

printf 'Available notes:\n'
shopt -s nullglob
files=("$notes_dir"/*)
((${#files[@]} > 0)) || { printf 'No notes found.\n'; exit 0; }
select file in "${files[@]}"; do
  [[ -n "$file" ]] || { printf 'Invalid selection.\n'; continue; }
  exec "$editor" "$file"
done
