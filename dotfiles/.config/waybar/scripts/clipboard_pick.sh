#!/usr/bin/env bash
# Pick a clipboard history entry with fzf and copy the stored entry back to the clipboard.
# wl-clipboard-history lists "ID,contents" with newlines removed, so only the leading ID is taken
# from the selection and the full entry is read again by ID. Enter or Ctrl+Alt+Y copies.
set -euo pipefail

selection=$(wl-clipboard-history -l 376 | fzf --prompt 'Clipboard> ' --bind 'ctrl-alt-y:accept') || exit 0
id=${selection%%,*}
if [[ ! $id =~ ^[0-9]+$ ]]; then
  printf 'Error: unexpected clipboard history entry\n' >&2
  exit 1
fi
# The stored entry has no trailing newline; sqlite3 adds one when printing.
wl-clipboard-history -p "$id" | wl-copy -n
