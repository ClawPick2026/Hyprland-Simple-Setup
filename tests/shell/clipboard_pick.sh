#!/usr/bin/env bash
# clipboard_pick.sh copies the stored entry chosen by its ID, so commas and newlines in the
# entry survive. PATH doubles stand in for wl-clipboard-history, fzf and wl-copy.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/dotfiles/.config/waybar/scripts/clipboard_pick.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
bin="$fixture/bin"
mkdir -p "$bin"

cat > "$bin/wl-clipboard-history" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -l) printf '12,a, b, c\n7,first linesecond line\n' ;;
  -p) printf 'entry %s\n' "$2" >> "$HSS_TEST_LOG"; [[ $2 == 7 ]] && printf 'first line\nsecond line\n' || printf 'a, b, c\n' ;;
esac
STUB
cat > "$bin/fzf" <<'STUB'
#!/usr/bin/env bash
[[ -n ${HSS_TEST_PICK:-} ]] || exit 130
grep -m 1 -- "^$HSS_TEST_PICK,"
STUB
cat > "$bin/wl-copy" <<'STUB'
#!/usr/bin/env bash
[[ $1 == -n ]] || exit 2
cat > "$HSS_TEST_COPIED"
STUB
chmod +x "$bin"/*

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

run() {
  : > "$fixture/log"
  rm -f -- "$fixture/copied"
  env PATH="$bin:$PATH" HSS_TEST_LOG="$fixture/log" HSS_TEST_COPIED="$fixture/copied" "$@" bash "$script"
}

run HSS_TEST_PICK=12 || fail "picking an entry with commas"
[[ $(<"$fixture/copied") == 'a, b, c' ]] || fail "an entry with commas is copied whole"
grep -Fxq 'entry 12' "$fixture/log" || fail "the entry is read again by ID"

run HSS_TEST_PICK=7 || fail "picking a multi-line entry"
[[ $(<"$fixture/copied") == $'first line\nsecond line' ]] || fail "a multi-line entry keeps its newlines"

run || fail "cancelling the picker succeeds"
[[ ! -e $fixture/copied ]] || fail "cancelling the picker copies nothing"

printf 'ok - clipboard picker copies the stored entry by ID and ignores cancellation\n'
