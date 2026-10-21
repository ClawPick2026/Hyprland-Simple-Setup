#!/usr/bin/env python3
"""Update owned Waybar actions while preserving JSONC comments and other settings."""

import json
from pathlib import Path
import sys

# Use the same JSONC grammar as the installed Waybar launcher without writing
# bytecode into the source dotfiles tree during setup or dry-run.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'dotfiles/.config/waybar/scripts'))
from hss_jsonc import TOKENS, json_text

DECODER = json.JSONDecoder()


def skip_space(text, pos):
    while pos < len(text) and text[pos].isspace():
        pos += 1
    return pos


def object_members(text):
    clean = json_text(text)
    value = json.loads(clean)
    if not isinstance(value, dict):
        raise ValueError('Waybar module must be an object')
    pos = skip_space(clean, 0) + 1
    members = {}
    previous_comma = None
    while clean[skip_space(clean, pos)] != '}':
        start = skip_space(clean, pos)
        key, end = DECODER.raw_decode(clean, start)
        value_start = skip_space(clean, skip_space(clean, end) + 1)
        _, value_end = DECODER.raw_decode(clean, value_start)
        delimiter = skip_space(clean, value_end)
        comma = delimiter if clean[delimiter] == ',' or text[delimiter] == ',' else None
        # A trailing comma was blanked; find it in the original gap instead.
        if comma is None:
            gap = TOKENS.sub(lambda m: ' ' * len(m.group()) if not m.group().startswith('"') else m.group(), text[value_end:delimiter])
            offset = gap.find(',')
            if offset >= 0:
                comma = value_end + offset
        members[key] = (start, value_start, value_end, previous_comma, comma)
        previous_comma = comma
        pos = (comma + 1) if comma is not None else value_end
    return members, skip_space(clean, pos)


def apply_edits(text, edits):
    merged = []
    for start, end, replacement in sorted(edits):
        if merged and start < merged[-1][1]:
            prior = merged[-1]
            if replacement or prior[2]:
                raise ValueError('overlapping Waybar edits')
            merged[-1] = (prior[0], max(end, prior[1]), '')
        else:
            merged.append((start, end, replacement))
    for start, end, replacement in reversed(merged):
        text = text[:start] + replacement + text[end:]
    return text


def update_object(text, updates, removed=()):
    members, closing = object_members(text)
    edits = []
    additions = {}
    for key, value in updates.items():
        encoded = json.dumps(value, ensure_ascii=False)
        if key in members:
            _, start, end, _, _ = members[key]
            edits.append((start, end, encoded))
        else:
            additions[key] = value
    for key in removed:
        if key in members:
            start, _, end, before, after = members[key]
            edits.append((start if after is not None else (before if before is not None else start),
                          after + 1 if after is not None else end, ''))
    text = apply_edits(text, edits)
    if additions:
        members, closing = object_members(text)
        trailing = bool(members) and next(reversed(members.values()))[4] is not None
        prefix = ',' if members and not trailing else ''
        fields = ',\n'.join('  ' + json.dumps(key) + ': ' + json.dumps(value, ensure_ascii=False)
                            for key, value in additions.items())
        text = text[:closing] + prefix + '\n' + fields + '\n' + text[closing:]
    json.loads(json_text(text))
    return text


SCRIPTS = '$HOME/.config/hypr/scripts'
WAYBAR_SCRIPTS = '$HOME/.config/waybar/scripts'
ACTION = SCRIPTS + '/action_exec.sh '

# Owned action keys: always set to the semantic action contract (plan D01.3).
OWNED_ACTIONS = {
    'clock': {'on-click': SCRIPTS + '/float_calendar.sh'},
    'pulseaudio': {'on-click': ACTION + 'audio.streams.open',
                   'on-click-right': ACTION + 'audio.hardware.open'},
    'bluetooth': {'on-click': ACTION + 'bluetooth.open'},
    'network': {'on-click': ACTION + 'network.connect.choose',
                'on-click-right': ACTION + 'network.profile.edit'},
    'custom/notification': {
        'exec': WAYBAR_SCRIPTS + '/notification_status.sh',
        'on-click': ACTION + 'notifications.primary',
        'on-click-right': ACTION + 'notifications.dnd.toggle'},
}
OWNED_REMOVALS = {'custom/notification': ('interval', 'exec-if')}

# Stock values from earlier releases. Only these exact values (or an absent key) are
# migrated, so user-customized gestures and labels stay untouched.
LEGACY_POWER = {name: (f'~/.config/waybar/scripts/power_action.sh {name}',
                       f'$HOME/.config/waybar/scripts/power_action.sh {name}')
                for name in ('suspend', 'hibernate', 'shutdown', 'reboot', 'logout')}
REMOVE = object()  # STOCK_MIGRATIONS value: delete the key when it still has a stock value.
STOCK_MIGRATIONS = {
    'bluetooth': [((), 'on-click-right', (None, SCRIPTS + '/toggle_bluetooth.sh'),
                   ACTION + 'bluetooth.radio.toggle')],
    'pulseaudio': [((), 'tooltip-format',
                    ('Output: {desc}\nVolume: {volume}%\nMicrophone: {source_volume}%\n'
                     'Left or right click: selected audio control',),
                    'Output: {desc}\nVolume: {volume}%\nMicrophone: {source_volume}%\n'
                    'Left click: application volumes \u2022 Right click: device mixer')],
    'hyprland/workspaces': [(('tooltips',), 'default',
                             ('Workspace {name}\nLeft click: switch \u2022 Scroll: previous/next',),
                             'Workspace {name}\nLeft click: switch')],
    'custom/power': [(('menu-actions',), name, legacy, ACTION + 'session.' + name)
                     for name, legacy in LEGACY_POWER.items()],
    # The taskbar follows the GTK icon theme (Breeze) instead of an uninstalled theme.
    'wlr/taskbar': [((), 'icon-theme', ('Numix-Circle',), REMOVE)],
}
# Icons for notification states that earlier configurations did not define.
NOTIFICATION_ICONS = {'stopped': '\uf0a2', 'disabled': '\uf0a2',
                      'unavailable': '\uf0a2 n/a', 'error': '\uf0a2 !'}


def hardware_module(kind):
    return {'return-type': 'json',
            'exec': f'{WAYBAR_SCRIPTS}/hardware_state.sh {kind}',
            'exec-if': f'{WAYBAR_SCRIPTS}/hardware_state.sh --absent {kind}',
            'interval': 60, 'tooltip': True, 'escape': True}


# Approved baseline additions: (module, definition, anchor module it follows).
ENSURED_MODULES = [
    ('custom/theme', {
        'format': '{icon}',
        'format-icons': {'dark': '\uf186', 'light': '\uf185',
                         'unavailable': '\uf042', 'error': '\uf042 !'},
        'return-type': 'json', 'exec': WAYBAR_SCRIPTS + '/theme_status.sh', 'interval': 30,
        'tooltip': True, 'on-click': ACTION + 'theme.toggle', 'escape': True}, 'custom/notification'),
    ('custom/backlight-unavailable', hardware_module('backlight'), 'backlight'),
    ('custom/keyboard-state-unavailable', hardware_module('keyboard'), 'keyboard-state'),
    ('custom/battery-unavailable', hardware_module('battery'), 'battery'),
]
MODULE_ARRAYS = ('modules-left', 'modules-center', 'modules-right')


def member_value(text, key):
    """Return the parsed value of KEY in the object TEXT, or a missing marker."""
    members, _ = object_members(text)
    if key not in members:
        return members, MISSING
    _, start, end, _, _ = members[key]
    return members, json.loads(json_text(text[start:end]))


MISSING = object()


def edit_nested(text, path, fn):
    """Apply FN to the object at PATH inside TEXT; missing or non-object paths are left alone."""
    if not path:
        return fn(text)
    members, _ = object_members(text)
    if path[0] not in members:
        return text
    _, start, end, _, _ = members[path[0]]
    if not isinstance(json.loads(json_text(text[start:end])), dict):
        return text
    return text[:start] + edit_nested(text[start:end], path[1:], fn) + text[end:]


def migrate_stock(text, path, key, old_values, new_value):
    def apply(obj):
        _, current = member_value(obj, key)
        if new_value is REMOVE:
            return update_object(obj, {}, (key,)) if current in old_values else obj
        if current is MISSING and None in old_values or current in old_values:
            return update_object(obj, {key: new_value})
        return obj
    return edit_nested(text, path, apply)


def ensure_keys(text, defaults):
    members, _ = object_members(text)
    missing = {key: value for key, value in defaults.items() if key not in members}
    return update_object(text, missing) if missing else text


def update_module(module, text):
    if module in OWNED_ACTIONS:
        text = update_object(text, OWNED_ACTIONS[module], OWNED_REMOVALS.get(module, ()))
    for path, key, old_values, new_value in STOCK_MIGRATIONS.get(module, ()):
        text = migrate_stock(text, path, key, old_values, new_value)
    if module == 'custom/notification':
        text = edit_nested(text, ('format-icons',), lambda obj: ensure_keys(obj, NOTIFICATION_ICONS))
    return text


def array_elements(text, key):
    """Positions of string elements in the top-level array KEY: list of (start, end, value)."""
    members, _ = object_members(text)
    if key not in members:
        return None
    _, start, end, _, _ = members[key]
    clean = json_text(text)
    if clean[start] != '[':
        return None
    elements = []
    pos = skip_space(clean, start + 1)
    while pos < end and clean[pos] != ']':
        value, value_end = DECODER.raw_decode(clean, pos)
        elements.append((pos, value_end, value))
        pos = skip_space(clean, value_end)
        if clean[pos] == ',':
            pos = skip_space(clean, pos + 1)
    return elements


def insert_after(text, key, anchor, module):
    elements = array_elements(text, key) or []
    for start, end, value in elements:
        if value == anchor:
            line_start = text.rfind('\n', 0, start) + 1
            indent = text[line_start:start]
            separator = ',\n' + indent if not indent.strip() else ', '
            return text[:end] + separator + json.dumps(module) + text[end:]
    return text


def update_bar(text):
    members, _ = object_members(text)
    for module in list(OWNED_ACTIONS) + [m for m in STOCK_MIGRATIONS if m not in OWNED_ACTIONS]:
        members, _ = object_members(text)
        if module not in members:
            continue
        _, start, end, _, _ = members[module]
        if not isinstance(json.loads(json_text(text[start:end])), dict):
            continue
        text = text[:start] + update_module(module, text[start:end]) + text[end:]
    for module, definition, anchor in ENSURED_MODULES:
        placed = [key for key in MODULE_ARRAYS
                  if module in [value for _, _, value in (array_elements(text, key) or [])]]
        anchored = [key for key in MODULE_ARRAYS
                    if anchor in [value for _, _, value in (array_elements(text, key) or [])]]
        if not placed and not anchored:
            continue
        members, _ = object_members(text)
        if module not in members:
            text = update_object(text, {module: definition})
        if not placed:
            text = insert_after(text, anchored[0], anchor, module)
    return text


def update_document(text):
    clean = json_text(text)
    parsed = json.loads(clean)
    if isinstance(parsed, dict):
        result = update_bar(text)
    elif isinstance(parsed, list):
        edits = []
        pos = skip_space(clean, 0) + 1
        for _ in parsed:
            pos = skip_space(clean, pos)
            _, end = DECODER.raw_decode(clean, pos)
            edits.append((pos, end, update_bar(text[pos:end])))
            pos = skip_space(clean, end)
            if clean[pos] == ',':
                pos += 1
        result = apply_edits(text, edits)
    else:
        raise ValueError('Waybar configuration must be an object or array of objects')
    json.loads(json_text(result))
    return result


if __name__ == '__main__':
    try:
        sys.stdout.write(update_document(Path(sys.argv[1]).read_text()))
    except (ValueError, OSError, IndexError) as error:
        print(f'Cannot update Waybar configuration: {error}', file=sys.stderr)
        sys.exit(1)
