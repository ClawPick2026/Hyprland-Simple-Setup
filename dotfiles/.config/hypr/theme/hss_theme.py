#!/usr/bin/env python3
"""Deterministic theme renderer for Hyprland Simple Setup.

The renderer is pure: it reads tokens, the unit registry, templates, the selected
roles and the current content of declared targets, and writes candidates into a
private staging directory together with a plan. It never writes live configuration,
starts processes or contacts the network. providers/theme.sh commits the plan with
the shared reliability primitives and performs the declared activation.

Contract: dotfiles/.config/hypr/theme/README.md.
"""

from __future__ import annotations

import argparse
import configparser
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path

SCHEMA_VERSION = 1
THEME_DIR = Path(__file__).resolve().parent
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
UNIT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
MEMBER_RE = re.compile(r"^[a-z][a-z0-9_]*/[a-z0-9@._+-]+$")
PLACEHOLDER_RE = re.compile(r"\{\{\s*([^{}]+?)\s*\}\}")
TARGET_PREFIXES = ("theme:", "config:", "data:", "home:")
CLASSES = ("generated", "managed-keys", "managed-region")
VALIDATORS = ("json", "toml", "ini", "css", "lua", "kdl", "none")
COMMENT_STYLES = {
    "#": ("#", ""),
    "//": ("//", ""),
    "--": ("--", ""),
    ";": (";", ""),
    '"': ('"', ""),
    "/* */": ("/*", " */"),
    "<!-- -->": ("<!--", " -->"),
}
VARIANTS = ("dark", "light")


class ThemeError(Exception):
    """Invalid tokens, registry, template or input."""


# ---------------------------------------------------------------------------
# Tokens


def _hex(value: str) -> str:
    if not isinstance(value, str) or not COLOR_RE.match(value):
        raise ThemeError(f"invalid color {value!r}")
    return value.lower()


def load_json(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError as error:
        raise ThemeError(f"missing file {path}") from error
    except json.JSONDecodeError as error:
        raise ThemeError(f"invalid JSON in {path}: {error}") from error
    if not isinstance(data, dict):
        raise ThemeError(f"{path} must contain a JSON object")
    return data


def resolve_tokens(tokens: dict, variant: str) -> dict:
    """Return the flattened template context for VARIANT."""
    if tokens.get("schema_version") != SCHEMA_VERSION:
        raise ThemeError(f"unsupported token schema {tokens.get('schema_version')!r}")
    if variant not in VARIANTS:
        raise ThemeError(f"unknown variant {variant!r}")
    variants = tokens.get("variants")
    palettes = tokens.get("palettes")
    if not isinstance(variants, dict) or not isinstance(palettes, dict):
        raise ThemeError("tokens need palettes and variants")
    if set(variants) != set(VARIANTS):
        raise ThemeError("tokens must define exactly the dark and light variants")
    reference_keys = None
    for name in VARIANTS:
        keys = _shape(variants[name])
        if reference_keys is None:
            reference_keys = keys
        elif keys != reference_keys:
            raise ThemeError("dark and light variants must define the same token keys")
    spec = variants[variant]
    palette_name = spec.get("palette")
    palette = palettes.get(palette_name)
    if not isinstance(palette, dict):
        raise ThemeError(f"variant {variant} references unknown palette {palette_name!r}")
    palette = {name: _hex(value) for name, value in palette.items()}

    def ref(value):
        if isinstance(value, str) and value.startswith("@"):
            name = value[1:]
            if name not in palette:
                raise ThemeError(f"unknown palette reference {value!r}")
            return palette[name]
        return value

    context: dict[str, object] = {
        "variant": variant,
        "variant_label": spec.get("label", variant),
        "flavor": spec.get("flavor", variant),
        "flavor_lower": str(spec.get("flavor", variant)).lower(),
        "is_dark": "true" if spec.get("is_dark") else "false",
        "is_dark_int": "1" if spec.get("is_dark") else "0",
    }
    for name, value in palette.items():
        context[f"palette.{name}"] = value
    for name, value in (spec.get("color") or {}).items():
        context[f"color.{name}"] = _hex(ref(value))
    terminal = spec.get("terminal") or {}
    for name, value in terminal.items():
        if name == "ansi":
            if not isinstance(value, list) or len(value) != 16:
                raise ThemeError("terminal.ansi must list 16 colors")
            for index, item in enumerate(value):
                context[f"terminal.ansi.{index}"] = _hex(ref(item))
        else:
            context[f"terminal.{name}"] = _hex(ref(value))
    for name, value in (spec.get("assets") or {}).items():
        context[f"assets.{name}"] = value
    for group in ("font", "metrics", "effects", "cursor"):
        for name, value in (tokens.get(group) or {}).items():
            context[f"{group}.{name}"] = value
    for key, value in context.items():
        if isinstance(value, str) and any(ord(ch) < 32 for ch in value):
            raise ThemeError(f"token {key} contains control characters")
    return context


def _shape(value, prefix=""):
    if isinstance(value, dict):
        keys = set()
        for name, item in value.items():
            keys |= _shape(item, f"{prefix}{name}.")
        return keys
    if isinstance(value, list):
        return {f"{prefix}[{len(value)}]"}
    return {prefix.rstrip(".")}


# ---------------------------------------------------------------------------
# Template filters


def _rgb(color: str) -> tuple[int, int, int]:
    color = _hex(color)
    return int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)


def _alpha_byte(text: str) -> int:
    try:
        alpha = float(text)
    except ValueError as error:
        raise ThemeError(f"invalid alpha {text!r}") from error
    if not 0 <= alpha <= 1:
        raise ThemeError(f"alpha out of range {text!r}")
    return round(alpha * 255)


def _mix(color: str, other: str, ratio: str) -> str:
    weight = float(ratio)
    if not 0 <= weight <= 1:
        raise ThemeError(f"mix ratio out of range {ratio!r}")
    first, second = _rgb(color), _rgb(other)
    mixed = [round(a * (1 - weight) + b * weight) for a, b in zip(first, second)]
    return "#" + "".join(f"{part:02x}" for part in mixed)


def _quote_toml(text: str) -> str:
    return json.dumps(text, ensure_ascii=False)


def _quote_lua(text: str) -> str:
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def apply_filter(value: object, spec: str, context: dict) -> object:
    name, _, argument = spec.partition(":")
    name = name.strip()
    args = [part.strip() for part in argument.split(":")] if argument else []
    # "@token.name" arguments read another token, for example rgba:@effects.shell_opacity.
    args = [str(lookup(context, arg[1:])) if arg.startswith("@") and name != "mix" else arg for arg in args]
    if name == "hex":
        return _hex(str(value))
    if name == "nohash":
        return _hex(str(value))[1:]
    if name == "upper":
        return str(value).upper()
    if name == "lower":
        return str(value).lower()
    if name == "rgb":
        return ",".join(str(part) for part in _rgb(str(value)))
    if name == "rgb_space":
        return " ".join(str(part) for part in _rgb(str(value)))
    if name == "rgba":
        alpha = args[0] if args else "1"
        _alpha_byte(alpha)
        red, green, blue = _rgb(str(value))
        return f"rgba({red}, {green}, {blue}, {alpha})"
    if name == "alpha_hex":
        return _hex(str(value)) + f"{_alpha_byte(args[0] if args else '1'):02x}"
    if name == "argb":
        return f"#{_alpha_byte(args[0] if args else '1'):02x}" + _hex(str(value))[1:]
    if name == "hypr":
        return f"rgba({_hex(str(value))[1:]}{_alpha_byte(args[0] if args else '1'):02x})"
    if name == "mix":
        if len(args) != 2:
            raise ThemeError("mix needs OTHER_TOKEN:RATIO")
        other = lookup(context, args[0].lstrip("@"))
        ratio = str(lookup(context, args[1][1:])) if args[1].startswith("@") else args[1]
        return _mix(str(value), str(other), ratio)
    if name == "json":
        return json.dumps(value, ensure_ascii=False)
    if name == "toml":
        return _quote_toml(str(value))
    if name == "lua":
        return _quote_lua(str(value))
    if name == "int":
        return str(int(float(str(value))))
    if name == "px":
        return f"{value}px"
    if name == "pt_to_px":
        return str(round(float(str(value)) * 4 / 3))
    if name == "uri":
        return "file://" + urllib.parse.quote(str(value), safe="/")
    if name == "kde_rgb":
        return ",".join(str(part) for part in _rgb(str(value)))
    raise ThemeError(f"unknown filter {name!r}")


def lookup(context: dict, key: str) -> object:
    if key not in context:
        raise ThemeError(f"unknown token {key!r}")
    return context[key]


def render_text(text: str, context: dict, origin: str) -> str:
    def replace(match: re.Match) -> str:
        expression = match.group(1)
        parts = [part.strip() for part in expression.split("|")]
        try:
            value = lookup(context, parts[0])
            for spec in parts[1:]:
                value = apply_filter(value, spec, context)
        except (ThemeError, ValueError) as error:
            raise ThemeError(f"{origin}: {error}") from error
        return str(value)

    rendered = PLACEHOLDER_RE.sub(replace, text)
    if "{{" in rendered or "}}" in rendered:
        raise ThemeError(f"{origin}: unbalanced template braces")
    return rendered


# ---------------------------------------------------------------------------
# Registry


@dataclass
class Output:
    target: str
    klass: str
    template: str | None = None
    validator: str = "none"
    mode: str = "0644"
    format: str | None = None
    keys: list = field(default_factory=list)
    keys_template: str | None = None
    comment: str | None = None
    position: str = "append"
    content: str | None = None
    create_if_missing: bool = False


@dataclass
class Unit:
    id: str
    owner: str
    description: str
    applies: dict
    outputs: list
    depends: list
    activation: list
    executables: list
    assets: list = field(default_factory=list)


def registry_documents(path: Path) -> list[tuple[Path, dict]]:
    """units.json followed by units.d/*.json in name order; each domain owns one fragment."""
    documents = [(path, load_json(path))]
    fragments = path.parent / "units.d"
    if fragments.is_dir():
        documents += [(item, load_json(item)) for item in sorted(fragments.glob("*.json"))]
    for source, data in documents:
        if data.get("schema_version") != SCHEMA_VERSION:
            raise ThemeError(f"unsupported registry schema {data.get('schema_version')!r} in {source.name}")
        if not isinstance(data.get("units"), list):
            raise ThemeError(f"{source.name} needs a units list")
    return documents


def load_registry(path: Path) -> list[Unit]:
    units: list[Unit] = []
    seen_ids: set[str] = set()
    seen_targets: dict[str, str] = {}
    raw_units = [raw for _source, data in registry_documents(path) for raw in data["units"]]
    for raw in raw_units:
        unit_id = raw.get("id", "")
        if not UNIT_ID_RE.match(unit_id) or unit_id in seen_ids:
            raise ThemeError(f"invalid or duplicate unit id {unit_id!r}")
        seen_ids.add(unit_id)
        applies = raw.get("applies") or {}
        if not isinstance(applies, dict) or not (
            applies.get("always") is True or applies.get("members") or applies.get("packages")
        ):
            raise ThemeError(f"unit {unit_id}: applies needs always, members or packages")
        for member in applies.get("members", []):
            if not MEMBER_RE.match(member):
                raise ThemeError(f"unit {unit_id}: invalid member {member!r}")
        outputs = []
        for item in raw.get("outputs", []):
            output = Output(
                target=item.get("target", ""),
                klass=item.get("class", ""),
                template=item.get("template"),
                validator=item.get("validator", "none"),
                mode=item.get("mode", "0644"),
                format=item.get("format"),
                keys=item.get("keys", []),
                keys_template=item.get("keys_template"),
                comment=item.get("comment"),
                position=item.get("position", "append"),
                content=item.get("content"),
                create_if_missing=bool(item.get("create_if_missing", False)),
            )
            _validate_output(unit_id, output)
            # One unit owns each file; several outputs of the same unit may edit it in sequence.
            key = normalized_target(output.target)
            owner = seen_targets.get(key)
            if owner is not None and owner != unit_id:
                raise ThemeError(f"unit {unit_id}: target {output.target} is also owned by {owner}")
            seen_targets[key] = unit_id
            outputs.append(output)
        if not outputs:
            raise ThemeError(f"unit {unit_id} has no outputs")
        activation = raw.get("activation", [])
        for step in activation:
            _validate_activation(unit_id, step)
        units.append(
            Unit(
                id=unit_id,
                owner=raw.get("owner", ""),
                description=raw.get("description", ""),
                applies=applies,
                outputs=outputs,
                depends=list(raw.get("depends", [])),
                activation=activation,
                executables=list(raw.get("executables", [])),
                assets=_validated_assets(unit_id, raw.get("assets", [])),
            )
        )
    ids = {unit.id for unit in units}
    for unit in units:
        for dependency in unit.depends:
            if dependency not in ids:
                raise ThemeError(f"unit {unit.id} depends on unknown unit {dependency}")
    _check_acyclic(units)
    return _dependency_order(units)


def normalized_target(spec: str) -> str:
    """Home-relative form of a target spec with the default XDG layout, for collision checks."""
    prefix, relative = spec.split(":", 1)
    base = {"theme": ".config/hss-theme/", "config": ".config/", "data": ".local/share/", "home": ""}[prefix]
    return os.path.normpath(base + relative)


def _dependency_order(units: list[Unit]) -> list[Unit]:
    """Stable topological order: registry order, except that prerequisites come first."""
    by_id = {unit.id: unit for unit in units}
    ordered: list[Unit] = []
    placed: set[str] = set()

    def place(unit: Unit) -> None:
        if unit.id in placed:
            return
        for dependency in unit.depends:
            place(by_id[dependency])
        placed.add(unit.id)
        ordered.append(unit)

    for unit in units:
        place(unit)
    return ordered


def _validate_output(unit_id: str, output: Output) -> None:
    if output.klass not in CLASSES:
        raise ThemeError(f"unit {unit_id}: invalid class {output.klass!r}")
    if not output.target.startswith(TARGET_PREFIXES):
        raise ThemeError(f"unit {unit_id}: target must start with {', '.join(TARGET_PREFIXES)}")
    relative = output.target.split(":", 1)[1]
    parts = Path(relative).parts
    if not relative or relative.startswith("/") or ".." in parts or any(part.startswith("~") for part in parts):
        raise ThemeError(f"unit {unit_id}: unsafe target {output.target!r}")
    if output.validator not in VALIDATORS:
        raise ThemeError(f"unit {unit_id}: unknown validator {output.validator!r}")
    if not re.fullmatch(r"0[0-7]{3}", output.mode) or output.mode not in ("0644", "0600", "0755"):
        raise ThemeError(f"unit {unit_id}: unsupported mode {output.mode!r}")
    if output.klass == "generated":
        if not output.template:
            raise ThemeError(f"unit {unit_id}: generated output needs a template")
        template = (THEME_DIR / "templates" / output.template).resolve()
        if THEME_DIR / "templates" not in template.parents or not template.is_file():
            raise ThemeError(f"unit {unit_id}: missing template {output.template}")
    elif output.klass == "managed-keys":
        if output.format not in ("ini", "toml", "kv"):
            raise ThemeError(f"unit {unit_id}: managed-keys format must be ini, toml or kv")
        if not output.keys and not output.keys_template:
            raise ThemeError(f"unit {unit_id}: managed-keys output needs keys or keys_template")
        if output.keys_template and not (THEME_DIR / "templates" / output.keys_template).is_file():
            raise ThemeError(f"unit {unit_id}: missing keys template {output.keys_template}")
        for key in output.keys:
            if not isinstance(key, dict) or not key.get("key") or "value" not in key:
                raise ThemeError(f"unit {unit_id}: invalid managed key {key!r}")
            if output.format == "ini" and not key.get("section"):
                raise ThemeError(f"unit {unit_id}: ini key {key.get('key')} needs a section")
    elif output.klass == "managed-region":
        if output.comment not in COMMENT_STYLES:
            raise ThemeError(f"unit {unit_id}: unknown comment style {output.comment!r}")
        if output.position not in ("append", "prepend"):
            raise ThemeError(f"unit {unit_id}: position must be append or prepend")
        if output.content is None and not output.template:
            raise ThemeError(f"unit {unit_id}: managed-region needs content or a template")


def _validated_assets(unit_id: str, assets: list) -> list:
    """Assets are system files a unit needs at runtime, for example a GTK theme directory."""
    if not isinstance(assets, list):
        raise ThemeError(f"unit {unit_id}: assets must be a list")
    for asset in assets:
        paths = asset.get("paths") if isinstance(asset, dict) else None
        if not isinstance(asset, dict) or not re.fullmatch(r"[a-z0-9@._+-]+", str(asset.get("package", ""))) \
                or not isinstance(paths, list) or not paths:
            raise ThemeError(f"unit {unit_id}: asset needs a package and paths")
        for path in paths:
            if not isinstance(path, str) or not path.startswith("/") or ".." in Path(path).parts:
                raise ThemeError(f"unit {unit_id}: asset path must be absolute: {path!r}")
    return assets


def missing_assets(unit: Unit, context: dict) -> list[dict]:
    """Assets whose paths are all absent. HSS_THEME_ASSET_ROOT prefixes paths in test fixtures."""
    root = os.environ.get("HSS_THEME_ASSET_ROOT", "")
    missing = []
    for asset in unit.assets:
        paths = [render_text(path, context, f"{unit.id} asset") for path in asset["paths"]]
        if not any(os.path.exists(root + path) for path in paths):
            missing.append({"package": asset["package"], "paths": paths})
    return missing


def _validate_activation(unit_id: str, step: dict) -> None:
    kind = step.get("kind")
    if kind == "signal":
        if not re.fullmatch(r"[A-Za-z0-9._+-]{1,15}", step.get("process", "")):
            raise ThemeError(f"unit {unit_id}: signal activation needs an exact process name")
        if step.get("signal") not in ("USR1", "USR2", "HUP"):
            raise ThemeError(f"unit {unit_id}: unsupported signal {step.get('signal')!r}")
    elif kind == "reload":
        argv = step.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(item, str) for item in argv):
            raise ThemeError(f"unit {unit_id}: reload activation needs argv")
    elif kind == "gsettings":
        for name in ("schema", "key", "value"):
            if not isinstance(step.get(name), str) or not step.get(name):
                raise ThemeError(f"unit {unit_id}: gsettings activation needs {name}")
    elif kind in ("next-launch", "relogin"):
        pass
    else:
        raise ThemeError(f"unit {unit_id}: unknown activation kind {kind!r}")


def _check_acyclic(units: list[Unit]) -> None:
    graph = {unit.id: unit.depends for unit in units}
    state: dict[str, int] = {}

    def visit(node: str, trail: list[str]) -> None:
        if state.get(node) == 2:
            return
        if state.get(node) == 1:
            raise ThemeError("dependency cycle: " + " -> ".join(trail + [node]))
        state[node] = 1
        for child in graph[node]:
            visit(child, trail + [node])
        state[node] = 2

    for node in graph:
        visit(node, [])


# ---------------------------------------------------------------------------
# Paths, roles and managed state


@dataclass
class Paths:
    home: Path
    config_home: Path
    data_home: Path
    theme_root: Path

    def target(self, spec: str) -> Path:
        prefix, relative = spec.split(":", 1)
        base = {
            "theme": self.theme_root,
            "config": self.config_home,
            "data": self.data_home,
            "home": self.home,
        }[prefix]
        return base / relative


def selected_members(roles_path: Path | None) -> set[str]:
    if roles_path is None or not roles_path.is_file():
        return set()
    data = load_json(roles_path)
    if data.get("schema_version") != 2:
        raise ThemeError(f"unsupported roles schema {data.get('schema_version')!r}")
    members: set[str] = set()
    for role, options in (data.get("selected") or {}).items():
        for option in options or []:
            package = option.get("package") if isinstance(option, dict) else None
            if package:
                members.add(f"{role}/{package}")
    return members


def unit_applies(unit: Unit, members: set[str]) -> bool:
    if unit.applies.get("always") is True or unit.applies.get("packages"):
        return True
    return any(member in members for member in unit.applies.get("members", []))


def load_managed(theme_root: Path) -> dict:
    path = theme_root / "managed.json"
    if not path.exists():
        return {"schema_version": SCHEMA_VERSION, "files": {}, "keys": {}, "regions": {}}
    data = load_json(path)
    if data.get("schema_version") != SCHEMA_VERSION:
        raise ThemeError(f"unsupported managed state schema {data.get('schema_version')!r}")
    for section in ("files", "keys", "regions"):
        if not isinstance(data.get(section, {}), dict):
            raise ThemeError(f"managed.json section {section} must be an object")
        data.setdefault(section, {})
    return data


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(path: Path) -> str:
    return os.path.realpath(path)


# ---------------------------------------------------------------------------
# Validators


def validate_content(kind: str, text: str, origin: str) -> str:
    """Return 'valid', 'unvalidated' or raise ThemeError."""
    if kind == "none":
        return "unvalidated"
    if kind == "json":
        try:
            json.loads(text)
        except json.JSONDecodeError as error:
            raise ThemeError(f"{origin}: invalid JSON: {error}") from error
        return "valid"
    if kind == "toml":
        try:
            tomllib.loads(text)
        except tomllib.TOMLDecodeError as error:
            raise ThemeError(f"{origin}: invalid TOML: {error}") from error
        return "valid"
    if kind == "ini":
        parser = configparser.ConfigParser(interpolation=None, strict=False, allow_no_value=True)
        parser.optionxform = str
        try:
            parser.read_string(text if text.lstrip().startswith("[") else "[__top__]\n" + text)
        except configparser.Error as error:
            raise ThemeError(f"{origin}: invalid INI: {error}") from error
        return "valid"
    if kind in ("css", "kdl"):
        depth = 0
        for char in _strip_comments(text, kind):
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth < 0:
                    raise ThemeError(f"{origin}: unbalanced braces")
        if depth != 0:
            raise ThemeError(f"{origin}: unbalanced braces")
        return "valid"
    if kind == "lua":
        compiler = shutil.which("luac") or shutil.which("luac5.4")
        if not compiler:
            return "unvalidated"
        result = subprocess.run([compiler, "-p", "-"], input=text.encode(), capture_output=True, check=False)
        if result.returncode != 0:
            raise ThemeError(f"{origin}: invalid Lua: {result.stderr.decode(errors='replace').strip()}")
        return "valid"
    raise ThemeError(f"{origin}: unknown validator {kind}")


def _strip_comments(text: str, kind: str) -> str:
    if kind == "css":
        return re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)


# ---------------------------------------------------------------------------
# Managed keys and regions


def split_lines(text: str) -> tuple[list[str], str]:
    """Split on LF only, so form feeds, U+2028 and other separators stay inside lines.

    Returns the lines without terminators and the file's line ending (CRLF when present).
    """
    eol = "\r\n" if "\r\n" in text else "\n"
    body = text[:-1] if text.endswith("\n") else text
    lines = body.split("\n") if body else []
    if eol == "\r\n":
        lines = [line[:-1] if line.endswith("\r") else line for line in lines]
    return lines, eol


def join_lines(lines: list[str], eol: str) -> str:
    return eol.join(lines) + eol if lines else ""


INI_HEADER_RE = re.compile(r"\[(.+)\]")
INI_KEY_RE = re.compile(r"^(\s*)([^=#;\s][^=]*?)\s*=")


def edit_ini(text: str, keys: list[tuple[str, str, str]]) -> str:
    """Set SECTION/KEY=VALUE pairs, preserving every other line and comment.

    Every occurrence of a managed key is updated, because GTK, Qt and KConfig read the last one.
    """
    lines, eol = split_lines(text)
    wanted = {(section, key): value for section, key, value in keys}
    seen: set[tuple[str, str]] = set()
    section = None
    output: list[str] = []
    section_last_index: dict[str, int] = {}
    for line in lines:
        stripped = line.strip()
        header = INI_HEADER_RE.fullmatch(stripped)
        if header:
            section = header.group(1)
            output.append(line)
            section_last_index[section] = len(output) - 1
            continue
        match = INI_KEY_RE.match(line)
        if match and section is not None and (section, match.group(2).strip()) in wanted:
            name = match.group(2).strip()
            output.append(f"{match.group(1)}{name}={wanted[(section, name)]}")
            seen.add((section, name))
        else:
            output.append(line)
        if section is not None and stripped:
            section_last_index[section] = len(output) - 1
    additions: dict[str, list[str]] = {}
    for (wanted_section, key), value in wanted.items():
        if (wanted_section, key) not in seen:
            additions.setdefault(wanted_section, []).append(f"{key}={value}")
    for wanted_section in sorted(additions, key=lambda name: section_last_index.get(name, 1 << 30)):
        entries = additions[wanted_section]
        if wanted_section in section_last_index:
            index = section_last_index[wanted_section] + 1
            output[index:index] = entries
            for name, position in section_last_index.items():
                if position >= index:
                    section_last_index[name] = position + len(entries)
        else:
            if output and output[-1].strip():
                output.append("")
            output.append(f"[{wanted_section}]")
            output.extend(entries)
    return join_lines(output, eol)


def read_ini_value(text: str, section: str, key: str) -> str | None:
    current = None
    found = None
    for line in split_lines(text)[0]:
        stripped = line.strip()
        header = INI_HEADER_RE.fullmatch(stripped)
        if header:
            current = header.group(1)
            continue
        match = re.match(r"^\s*([^=#;\s][^=]*?)\s*=(.*)$", line)
        if match and current == section and match.group(1).strip() == key:
            found = match.group(2).strip()
    return found


def _toml_string_flags(lines: list[str]) -> list[bool]:
    """For each line, whether it starts inside a TOML multi-line (triple-quoted) string."""
    flags: list[bool] = []
    delimiter = None
    for line in lines:
        flags.append(delimiter is not None)
        index = 0
        while index < len(line):
            if delimiter is None:
                char = line[index]
                if char == "#":
                    break
                if line.startswith('"""', index) or line.startswith("'''", index):
                    delimiter = line[index:index + 3]
                    index += 3
                    continue
                if char in "\"'":
                    quote, index = char, index + 1
                    while index < len(line) and line[index] != quote:
                        index += 2 if quote == '"' and line[index] == "\\" else 1
                index += 1
            elif delimiter == '"""' and line[index] == "\\":
                index += 2
            elif line.startswith(delimiter, index):
                # Up to two extra quotes may belong to the string content.
                end = index + 3
                while end < len(line) and end < index + 5 and line[end] == delimiter[0]:
                    end += 1
                delimiter, index = None, end
            else:
                index += 1
    return flags


def edit_kv(text: str, keys: list[tuple[str, str, str]], toml: bool) -> str:
    """Set top-level KEY=VALUE (kv) or KEY = VALUE (toml, before any table); all occurrences."""
    lines, eol = split_lines(text)
    wanted = {key: value for _section, key, value in keys}
    seen: set[str] = set()
    output: list[str] = []
    in_table = False
    first_table = None
    separator = " = " if toml else "="
    inside = _toml_string_flags(lines) if toml else [False] * len(lines)
    for line, in_string in zip(lines, inside):
        if in_string:
            output.append(line)
            continue
        stripped = line.strip()
        if toml and stripped.startswith("["):
            in_table = True
            if first_table is None:
                first_table = len(output)
        match = re.match(r"^(\s*)([A-Za-z0-9_.-]+)\s*=", line)
        if match and not in_table and match.group(2) in wanted:
            name = match.group(2)
            output.append(f"{match.group(1)}{name}{separator}{wanted[name]}")
            seen.add(name)
        else:
            output.append(line)
    entries = [f"{key}{separator}{value}" for key, value in wanted.items() if key not in seen]
    if entries:
        if toml and first_table is not None:
            output[first_table:first_table] = entries + [""]
        else:
            output.extend(entries)
    return join_lines(output, eol)


def read_kv_value(text: str, key: str, toml: bool) -> str | None:
    found = None
    lines = split_lines(text)[0]
    inside = _toml_string_flags(lines) if toml else [False] * len(lines)
    for line, in_string in zip(lines, inside):
        if in_string:
            continue
        if toml and line.strip().startswith("["):
            break
        match = re.match(r"^\s*([A-Za-z0-9_.-]+)\s*=\s*(.*)$", line)
        if match and match.group(1) == key:
            found = match.group(2).strip()
    return found


def managed_key_values(output: Output, context: dict, origin: str) -> list[tuple[str, str, str]]:
    """Rendered (section, key, value) triples from inline keys and an optional INI template."""
    values = [(spec.get("section", ""), spec["key"], render_text(str(spec["value"]), context, origin))
              for spec in output.keys]
    if output.keys_template:
        text = render_text((THEME_DIR / "templates" / output.keys_template).read_text(encoding="utf-8"), context, origin)
        section = ""
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith(("#", ";")):
                continue
            header = re.fullmatch(r"\[(.+)\]", stripped)
            if header:
                section = header.group(1)
                continue
            key, separator, value = stripped.partition("=")
            if not separator or not key.strip():
                raise ThemeError(f"{origin}: invalid managed key line {stripped!r}")
            values.append((section, key.strip(), value.strip()))
    seen = set()
    for section, key, _value in values:
        if (section, key) in seen:
            raise ThemeError(f"{origin}: duplicate managed key {section}/{key}")
        seen.add((section, key))
    return values


def region_markers(comment: str, unit_id: str) -> tuple[str, str]:
    opening, closing = COMMENT_STYLES[comment]
    return (f"{opening} >>> hss-theme:{unit_id} >>>{closing}", f"{opening} <<< hss-theme:{unit_id} <<<{closing}")


def find_region(text: str, comment: str, unit_id: str) -> tuple[int, int] | None:
    start_marker, end_marker = region_markers(comment, unit_id)
    lines = split_lines(text)[0]
    start = end = None
    for index, line in enumerate(lines):
        if line.strip() == start_marker:
            if start is not None:
                raise ThemeError(f"duplicate theme region for {unit_id}")
            start = index
        elif line.strip() == end_marker:
            if start is None or end is not None:
                raise ThemeError(f"malformed theme region for {unit_id}")
            end = index
    if start is None and end is None:
        return None
    if start is None or end is None:
        raise ThemeError(f"unterminated theme region for {unit_id}")
    return start, end


def region_content(text: str, comment: str, unit_id: str) -> str | None:
    span = find_region(text, comment, unit_id)
    if span is None:
        return None
    lines = split_lines(text)[0]
    return "\n".join(lines[span[0] + 1 : span[1]])


def set_region(text: str, comment: str, unit_id: str, body: str, position: str) -> str:
    start_marker, end_marker = region_markers(comment, unit_id)
    block = [start_marker, *body.rstrip("\n").split("\n"), end_marker]
    lines, eol = split_lines(text)
    span = find_region(text, comment, unit_id)
    if span is not None:
        lines[span[0] : span[1] + 1] = block
    elif position == "prepend":
        lines = block + lines
    else:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend(block)
    return join_lines(lines, eol)


# ---------------------------------------------------------------------------
# Planning


def plan(args: argparse.Namespace) -> dict:
    tokens = load_json(Path(args.tokens))
    context = resolve_tokens(tokens, args.variant)
    units = load_registry(Path(args.registry))
    paths = Paths(
        home=Path(args.home),
        config_home=Path(args.config_home),
        data_home=Path(args.data_home),
        theme_root=Path(args.theme_root),
    )
    context.update(
        {
            "path.home": str(paths.home),
            "path.config_home": str(paths.config_home),
            "path.data_home": str(paths.data_home),
            "path.theme_root": str(paths.theme_root),
            "path.generated": str(paths.theme_root / "generated"),
        }
    )
    roles_path = Path(args.roles) if args.roles else None
    members = selected_members(roles_path)
    managed = load_managed(paths.theme_root)
    wanted = set(filter(None, (args.units or "").split(","))) or None
    if wanted:
        unknown = wanted - {unit.id for unit in units}
        if unknown:
            raise ThemeError(f"unknown units: {', '.join(sorted(unknown))}")
    staging = Path(args.staging)
    staging.mkdir(parents=True, exist_ok=True)
    adopt = args.adopt
    scopes = [canonical(Path(scope)) for scope in args.adopt_scope]
    results: list[dict] = []
    by_id: dict[str, dict] = {}
    # Canonical file -> unit, so symlink aliases cannot let two units overwrite each other.
    claimed: dict[str, str] = {}
    for unit in units:
        if wanted and unit.id not in wanted and not _required_by(unit.id, wanted, units):
            continue
        entry = {
            "id": unit.id,
            "owner": unit.owner,
            "description": unit.description,
            "depends": unit.depends,
            "executables": unit.executables,
            "status": "ready",
            "reason": "",
            "outputs": [],
            "activation": [],
            "missing_assets": [],
        }
        if not unit_applies(unit, members):
            entry["status"] = "not-selected"
            entry["reason"] = "no selected member uses this unit"
            results.append(entry)
            by_id[unit.id] = entry
            continue
        try:
            entry["activation"] = [_render_activation(step, context, unit.id) for step in unit.activation]
            entry["missing_assets"] = missing_assets(unit, context)
            working: dict[str, bytes | None] = {}
            for index, output in enumerate(unit.outputs):
                target_key = canonical(paths.target(output.target))
                owner = claimed.get(target_key)
                if owner is not None and owner != unit.id:
                    _mark(entry, "skipped-conflict",
                          f"{output.target} resolves to the same file as unit {owner}'s output")
                claimed.setdefault(target_key, unit.id)
                entry["outputs"].append(
                    _plan_output(unit, index, output, context, paths, managed, staging, adopt, entry, working,
                                 scopes)
                )
        except ThemeError as error:
            entry["status"] = "failed"
            entry["reason"] = str(error)
            entry["outputs"] = []
        if entry["status"] == "ready" and all(item["action"] == "unchanged" for item in entry["outputs"]):
            entry["status"] = "unchanged"
        results.append(entry)
        by_id[unit.id] = entry
    # Units are in dependency order, so one pass propagates skips through chains.
    for entry in results:
        blocked = [dep for dep in entry["depends"] if by_id.get(dep, {}).get("status") in (
            "failed", "skipped-conflict", "skipped-dependency", "not-adopted")]
        if blocked and entry["status"] in ("ready", "unchanged"):
            entry["status"] = "skipped-dependency"
            entry["reason"] = "required unit did not apply: " + ", ".join(blocked)
    ready = [entry for entry in results if entry["status"] in ("ready", "unchanged")]
    skipped = [entry for entry in results if entry["status"] in (
        "failed", "skipped-conflict", "skipped-dependency", "not-adopted")]
    return {
        "schema_version": SCHEMA_VERSION,
        "variant": args.variant,
        "tokens_sha256": sha256_bytes(Path(args.tokens).read_bytes()),
        "registry_sha256": sha256_bytes(b"".join(
            source.read_bytes() for source, _data in registry_documents(Path(args.registry)))),
        "adopt": adopt,
        "units": results,
        "summary": {
            "ready": len(ready),
            "skipped": len(skipped),
            "batch": "complete" if not skipped else "partial",
        },
    }


def _required_by(unit_id: str, wanted: set[str], units: list[Unit]) -> bool:
    graph = {unit.id: unit.depends for unit in units}
    pending = list(wanted)
    seen = set()
    while pending:
        node = pending.pop()
        if node in seen:
            continue
        seen.add(node)
        for dependency in graph.get(node, []):
            if dependency == unit_id:
                return True
            pending.append(dependency)
    return False


def _render_activation(step: dict, context: dict, unit_id: str) -> dict:
    rendered = {}
    for key, value in step.items():
        if isinstance(value, str):
            rendered[key] = render_text(value, context, f"{unit_id} activation")
        elif isinstance(value, list):
            rendered[key] = [render_text(item, context, f"{unit_id} activation") for item in value]
        else:
            rendered[key] = value
    return rendered


def _read_target(target: Path, origin: str) -> bytes | None:
    try:
        if not target.exists():
            return None
        if not target.is_file():
            raise ThemeError(f"{origin}: target is not a regular file")
        return target.read_bytes()
    except OSError as error:
        raise ThemeError(f"{origin}: cannot read target: {error.strerror or error}") from error


def _decode(data: bytes | None, origin: str) -> str:
    if data is None:
        return ""
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ThemeError(f"{origin}: target is not UTF-8 text; it was left unchanged") from error


def _template_text(name: str, origin: str) -> str:
    try:
        return (THEME_DIR / "templates" / name).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ThemeError(f"{origin}: cannot read template {name}") from error


def _adoption_allowed(key: str, original: bytes | None, managed: dict, scopes: list[str]) -> bool:
    """Scoped adoption: files under a scope, missing files and files the theme already manages."""
    if not scopes or original is None:
        return True
    if key in managed["files"] or key in managed["keys"] or key in managed["regions"]:
        return True
    return any(key == scope or key.startswith(scope + os.sep) for scope in scopes)


def _plan_output(unit, index, output, context, paths, managed, staging, adopt, entry, working,
                 scopes=()) -> dict:
    """Plan one output. WORKING holds this unit's earlier candidates for files it edits twice."""
    target = paths.target(output.target)
    key = canonical(target)
    origin = f"{unit.id}:{output.target}"
    original = _read_target(target, origin)
    # A user-owned file outside the adoption scope is previewed, never adopted implicitly.
    adopt = adopt and _adoption_allowed(key, original, managed, list(scopes))
    current = working.get(key, original) if key in working else original
    item = {
        "target": str(target),
        "canonical": key,
        "class": output.klass,
        "mode": output.mode,
        "staged": None,
        "sha256": None,
        "action": "unchanged",
        "validation": "unvalidated",
        "record": {},
    }
    if output.klass == "generated":
        text = render_text(_template_text(output.template, origin), context, origin)
        item["validation"] = validate_content(output.validator, text, origin)
        candidate = text.encode("utf-8")
        recorded = managed["files"].get(key, {}).get("sha256")
        if original is not None and original != candidate:
            in_theme_root = key.startswith(canonical(paths.theme_root) + os.sep)
            if recorded is None and not (adopt and in_theme_root):
                _mark(entry, "skipped-conflict", f"{output.target} exists and is not managed by the theme")
            elif recorded is not None and sha256_bytes(original) != recorded:
                _mark(entry, "skipped-conflict", f"{output.target} was edited after the last theme change")
        item["record"] = {"sha256": sha256_bytes(candidate)}
    elif output.klass == "managed-keys":
        original_text = _decode(original, origin)
        text = _decode(current, origin)
        if current is None and not output.create_if_missing:
            _mark(entry, "not-adopted", f"{output.target} does not exist")
            return item
        recorded_keys = managed["keys"].get(key)
        values = managed_key_values(output, context, origin)
        if recorded_keys is None and not adopt:
            _mark(entry, "not-adopted", f"{output.target} has not been adopted; rerun setup with adoption")
            return item
        if recorded_keys is not None:
            for section, name, value in values:
                label = f"{section}/{name}" if section else name
                if output.format == "ini":
                    present = read_ini_value(original_text, section, name)
                else:
                    present = read_kv_value(original_text, name, output.format == "toml")
                last = recorded_keys.get(label)
                if present is None and last is not None and not adopt:
                    _mark(entry, "skipped-conflict", f"{output.target}: {label} was removed outside the theme")
                elif present is not None and present != last and present != value:
                    _mark(entry, "skipped-conflict", f"{output.target}: {label} was changed outside the theme")
        if output.format == "ini":
            new_text = edit_ini(text, values)
        else:
            new_text = edit_kv(text, values, output.format == "toml")
        item["validation"] = validate_content(output.validator, new_text, origin)
        candidate = new_text.encode("utf-8")
        item["record"] = {"keys": {(f"{s}/{k}" if s else k): v for s, k, v in values}}
    else:
        original_text = _decode(original, origin)
        text = _decode(current, origin)
        if current is None and not output.create_if_missing:
            _mark(entry, "not-adopted", f"{output.target} does not exist")
            return item
        if output.template:
            body = render_text(_template_text(output.template, origin), context, origin)
        else:
            body = render_text(output.content or "", context, origin)
        existing = region_content(original_text, output.comment, unit.id)
        recorded = managed["regions"].get(key, {}).get(unit.id)
        if existing is None and not adopt:
            _mark(entry, "not-adopted", f"{output.target} has no theme region; rerun setup with adoption")
            return item
        if existing is not None and recorded is not None and sha256_bytes(existing.encode()) != recorded \
                and existing.rstrip("\n") != body.rstrip("\n"):
            _mark(entry, "skipped-conflict", f"{output.target}: theme region was edited")
        new_text = set_region(text, output.comment, unit.id, body, output.position)
        item["validation"] = validate_content(output.validator, new_text, origin)
        candidate = new_text.encode("utf-8")
        item["record"] = {"region": sha256_bytes(body.rstrip("\n").encode())}
    working[key] = candidate
    digest = sha256_bytes(candidate)
    item["sha256"] = digest
    if original is not None and original == candidate:
        item["action"] = "unchanged"
    else:
        item["action"] = "create" if original is None else "replace"
        staged = staging / unit.id / f"{index:02d}-{target.name}"
        staged.parent.mkdir(parents=True, exist_ok=True)
        staged.write_bytes(candidate)
        item["staged"] = str(staged)
    # A later output of this unit for the same file supersedes this candidate at commit time.
    for earlier in entry["outputs"]:
        if earlier["canonical"] == key and earlier["staged"]:
            earlier["superseded"] = True
    return item


SEVERITY = {"ready": 0, "unchanged": 0, "not-adopted": 1, "skipped-conflict": 2, "failed": 3}


def _mark(entry: dict, status: str, reason: str) -> None:
    if SEVERITY[status] > SEVERITY.get(entry["status"], 0):
        entry["status"] = status
        entry["reason"] = reason


# ---------------------------------------------------------------------------
# Finalizing managed state


def finalize(args: argparse.Namespace) -> None:
    """Record what was actually committed in managed.json and summarize state.json.

    Units in --applied/--unchanged are recorded completely. Outputs listed in --written-file
    (canonical paths, one per line) are recorded even when their unit failed partway, so the
    theme's own writes are never mistaken for user edits later.
    """
    plan_data = load_json(Path(args.plan))
    theme_root = Path(args.theme_root)
    managed = load_managed(theme_root)
    applied = set(filter(None, (args.applied or "").split(",")))
    unchanged = set(filter(None, (args.unchanged or "").split(",")))
    failed = set(filter(None, (args.failed or "").split(",")))
    blocked = set(filter(None, (args.blocked or "").split(",")))
    written: set[str] = set()
    if args.written_file and Path(args.written_file).is_file():
        written = {line for line in Path(args.written_file).read_text(encoding="utf-8").split("\n") if line}
    for unit in plan_data.get("units", []):
        whole_unit = unit["id"] in applied | unchanged
        for output in unit.get("outputs", []):
            key = output["canonical"]
            if not whole_unit and key not in written:
                continue
            record = output.get("record") or {}
            if output["class"] == "generated" and "sha256" in record:
                managed["files"][key] = {"unit": unit["id"], "sha256": record["sha256"]}
            elif output["class"] == "managed-keys" and "keys" in record:
                managed["keys"].setdefault(key, {}).update(record["keys"])
            elif output["class"] == "managed-region" and "region" in record:
                managed["regions"].setdefault(key, {})[unit["id"]] = record["region"]
    statuses = {unit["id"]: unit["status"] for unit in plan_data.get("units", [])}
    for unit_id in applied:
        statuses[unit_id] = "applied"
    for unit_id in unchanged:
        statuses[unit_id] = "unchanged"
    for unit_id in blocked:
        statuses[unit_id] = "skipped-dependency"
    for unit_id in failed:
        statuses[unit_id] = "failed"
    previous = {}
    state_path = theme_root / "state.json"
    if state_path.is_file():
        try:
            previous = load_json(state_path)
        except ThemeError:
            previous = {}
    core_ok = statuses.get("theme-core") in ("applied", "unchanged")
    # The recorded variant changes only when the shared prerequisite really switched.
    variant = plan_data["variant"] if core_ok else previous.get("variant")
    state = {
        "schema_version": SCHEMA_VERSION,
        "variant": variant,
        "requested_variant": plan_data["variant"],
        "tokens_sha256": plan_data["tokens_sha256"] if core_ok else previous.get("tokens_sha256"),
        "units": {unit_id: statuses[unit_id] for unit_id in sorted(statuses)},
        "batch": "complete" if all(
            value in ("applied", "unchanged", "not-selected") for value in statuses.values()
        ) else "partial",
    }
    Path(args.out_managed).write_text(json.dumps(managed, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    Path(args.out_state).write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Command line


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    defaults = {
        "tokens": str(THEME_DIR / "tokens.json"),
        "registry": str(THEME_DIR / "units.json"),
    }

    check = sub.add_parser("check", help="validate tokens, registry and templates for both variants")
    check.add_argument("--tokens", default=defaults["tokens"])
    check.add_argument("--registry", default=defaults["registry"])

    resolve = sub.add_parser("resolve", help="print the resolved token context")
    resolve.add_argument("--tokens", default=defaults["tokens"])
    resolve.add_argument("--variant", required=True, choices=VARIANTS)

    planner = sub.add_parser("plan", help="render candidates into a staging directory and print a plan")
    planner.add_argument("--tokens", default=defaults["tokens"])
    planner.add_argument("--registry", default=defaults["registry"])
    planner.add_argument("--variant", required=True, choices=VARIANTS)
    planner.add_argument("--roles")
    planner.add_argument("--home", required=True)
    planner.add_argument("--config-home", required=True)
    planner.add_argument("--data-home", required=True)
    planner.add_argument("--theme-root", required=True)
    planner.add_argument("--staging", required=True)
    planner.add_argument("--units")
    planner.add_argument("--adopt", action="store_true")
    planner.add_argument("--adopt-scope", action="append", default=[], metavar="DIR",
                         help="limit --adopt to targets under DIR, missing targets and files already managed")
    planner.add_argument("--out")

    final = sub.add_parser("finalize", help="compute managed.json and state.json after commit")
    final.add_argument("--plan", required=True)
    final.add_argument("--theme-root", required=True)
    final.add_argument("--applied", default="")
    final.add_argument("--unchanged", default="")
    final.add_argument("--failed", default="")
    final.add_argument("--blocked", default="")
    final.add_argument("--written-file")
    final.add_argument("--out-managed", required=True)
    final.add_argument("--out-state", required=True)

    args = parser.parse_args(argv)
    try:
        if args.command == "check":
            tokens = load_json(Path(args.tokens))
            units = load_registry(Path(args.registry))
            for variant in VARIANTS:
                context = resolve_tokens(tokens, variant)
                context.update({name: f"/check/{name}" for name in (
                    "path.home", "path.config_home", "path.data_home", "path.theme_root", "path.generated")})
                for unit in units:
                    for output in unit.outputs:
                        origin = f"{unit.id}:{output.target} ({variant})"
                        if output.template:
                            text = render_text((THEME_DIR / "templates" / output.template).read_text(encoding="utf-8"), context, origin)
                            if output.klass == "generated":
                                validate_content(output.validator, text, origin)
                        if output.content is not None:
                            render_text(output.content, context, origin)
                        if output.klass == "managed-keys":
                            managed_key_values(output, context, origin)
                    for step in unit.activation:
                        _render_activation(step, context, unit.id)
                    for asset in unit.assets:
                        for path in asset["paths"]:
                            render_text(path, context, f"{unit.id} asset ({variant})")
            print(f"ok: {len(units)} units, {len(VARIANTS)} variants")
        elif args.command == "resolve":
            context = resolve_tokens(load_json(Path(args.tokens)), args.variant)
            print(json.dumps(context, indent=2, sort_keys=True))
        elif args.command == "plan":
            result = plan(args)
            text = json.dumps(result, indent=2, sort_keys=True) + "\n"
            if args.out:
                Path(args.out).write_text(text, encoding="utf-8")
            else:
                sys.stdout.write(text)
        elif args.command == "finalize":
            finalize(args)
    except ThemeError as error:
        print(f"hss_theme: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
