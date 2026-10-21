#!/usr/bin/env python3
"""Report whether a Hyprland keybinding file binds a key chord.

Usage: keybinding-chords.py FILE MOD [MOD ...] KEY
Exit 0 when the chord is bound (the matching line is printed), 1 when it is not, 2 on errors.
Understands keybindings.lua `bind("...")`/`hl.bind("...")` expressions built from string
literals and the local aliases used by this project (main_mod, shift, control, alt, plus any
`local NAME = "VALUE"` assignment), and Hyprlang `bind*` lines in .conf files.
"""

import re
import sys

ALIASES = {"SUPER": "SUPER", "MOD4": "SUPER", "WIN": "SUPER", "LOGO": "SUPER", "META": "SUPER",
           "SHIFT": "SHIFT", "CTRL": "CTRL", "CONTROL": "CTRL", "ALT": "ALT", "MOD1": "ALT"}


def normalize(tokens):
    mods, keys = set(), []
    for token in tokens:
        token = token.strip().upper()
        if not token:
            continue
        if token in ALIASES:
            mods.add(ALIASES[token])
        else:
            keys.append(token)
    return frozenset(mods), tuple(keys)


def lua_chords(text):
    variables = {}
    for name, value in re.findall(r'^\s*local\s+([A-Za-z_]\w*)\s*=\s*"([^"]*)"', text, re.M):
        variables[name] = value
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("--"):
            continue
        match = re.match(r'\s*(?:hl\.)?bind\s*\(\s*(.+?)\s*,', line)
        if not match:
            continue
        parts = re.split(r"\s*\.\.\s*", match.group(1))
        value = ""
        for part in parts:
            literal = re.fullmatch(r'"([^"]*)"', part)
            if literal:
                value += literal.group(1)
            elif part in variables:
                value += variables[part]
            else:
                value = None
                break
        if value is None:
            continue
        yield number, line, normalize(re.split(r"[+\s]+", value))


def conf_chords(text):
    variables = {}
    for name, value in re.findall(r"^\s*\$(\w+)\s*=\s*([^#\n]*)", text, re.M):
        variables[name] = value.strip()
    for number, line in enumerate(text.splitlines(), 1):
        match = re.match(r"\s*bind[a-z]*\s*=\s*([^,#]*),\s*([^,#]*),", line)
        if not match:
            continue
        mods = re.sub(r"\$(\w+)", lambda found: variables.get(found.group(1), found.group(0)), match.group(1))
        yield number, line, normalize(re.split(r"[\s_+]+", mods) + [match.group(2)])


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    path, wanted = argv[0], normalize(argv[1:])
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as error:
        print(f"keybinding-chords: {error}", file=sys.stderr)
        return 2
    chords = conf_chords(text) if path.endswith(".conf") else lua_chords(text)
    for number, line, chord in chords:
        if chord == wanted:
            print(f"{number}:{line.strip()}")
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
