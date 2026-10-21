# Theme tokens, units and renderer

Plan F03 owns this directory. It is installed with the dotfiles as `~/.config/hypr/theme/`, so `Super+Shift+T`, the bar theme controls and the installer all switch appearance through the same renderer, without the repository checkout and without package installation.

Approved direction (decision P02): Catppuccin Mocha for dark and Latte for light, Blue accents, Noto Sans for GUI text, JetBrains Mono Nerd Font for terminals and code, Breeze icons, and the Rose Pine cursor (`rose-pine-hyprcursor` for Hyprland, matching Xcursor `BreezeX-RosePine-Linux` from `rose-pine-cursor` for every other toolkit). Dark is the fresh-install default.

## Files

| File | Purpose |
|---|---|
| `tokens.json` | Palettes and semantic tokens for both variants (schema 1) |
| `tokens.schema.json` | Documented token structure |
| `units.json`, `units.d/*.json` | Registry of theme units (global units in `units.json`; one fragment per domain owner in `units.d/`, loaded in name order; units are planned and committed in dependency order) |
| `templates/` | Unit templates, one directory per domain |
| `hss_theme.py` | Pure renderer and planner (`check`, `resolve`, `plan`, `finalize`) |

`scripts/providers/theme.sh` commits plans through `scripts/lib/hss_reliability.sh` and runs activation. See `Documents/runtime-managed-configuration.md` for the transaction and consent rules.

## Tokens

Template placeholders use `{{ name | filter:arg }}`. Unknown tokens, unknown filters and unbalanced braces are errors.

| Name | Meaning |
|---|---|
| `variant`, `variant_label`, `flavor`, `flavor_lower`, `is_dark`, `is_dark_int` | Variant identity (`dark`/`light`, `Catppuccin Mocha`, `Mocha`, `mocha`, `true`/`false`, `1`/`0`) |
| `palette.<name>` | The 26 Catppuccin colors of the active flavor |
| `color.<role>` | Semantic colors: `bg`, `bg_alt`, `bg_deep`, `surface0-2`, `fg`, `fg_muted`, `fg_subtle`, `fg_disabled`, `border`, `border_inactive`, `accent`, `accent_alt`, `on_accent`, `focus`, `hover`, `pressed`, `selection_bg`, `selection_fg`, `link`, `visited`, `success`, `warning`, `error`, `critical`, `info`, `shadow`; filled status surfaces `success_bg`/`on_success`, `warning_bg`/`on_warning`, `error_bg`/`on_error`, `info_bg`/`on_info` (readable pairs in both variants); toolkit bevel shades `shade_light`, `shade_midlight`, `shade_mid`, `shade_dark` (ordered light to dark in both variants) |
| `terminal.*` | `foreground`, `background`, `cursor`, `cursor_text`, `selection_fg`, `selection_bg`, `ansi.0`-`ansi.15` |
| `assets.*` | `gtk_theme`, `icon_theme`, `kde_color_scheme`, `color_scheme_preference`, `helix_theme`, `btop_theme` |
| `font.*` | `ui_family`, `ui_size_pt`, `ui_size_px`, `mono_family`, `mono_size_pt`, `mono_size_px`, `bar_size_px`, `symbol_fallback` |
| `metrics.*` | `radius_small`, `radius`, `radius_large`, `space_xs/s/m/l`, `border`, `focus_width`, `icon_size`, `bar_height`, `dock_height`, `cursor_size` |
| `effects.*` | `shell_opacity`, `app_opacity`, `blur`, `motion` |
| `cursor.*` | `hyprcursor_theme`, `xcursor_theme`, `size` |
| `path.*` | `home`, `config_home`, `data_home`, `theme_root`, `generated` (absolute target paths, never staging paths) |

Filters: `uri` (absolute `file://` URI with percent-encoding, for CSS `url()`), `hex`, `nohash`, `upper`, `lower`, `rgb` (`r,g,b`), `rgb_space`, `rgba:A` (CSS), `alpha_hex:A` (`#rrggbbaa`), `argb:A` (`#aarrggbb`), `hypr:A` (`rgba(rrggbbaa)`), `mix:OTHER_TOKEN:RATIO`, `kde_rgb`, `json`, `toml`, `lua`, `int`, `px`, `pt_to_px`. An argument starting with `@` reads a token, for example `rgba:@effects.shell_opacity`.

Shared shell surfaces built on GTK CSS (Waybar, SwayNC, Wofi, nwg-panel, nwg-dock, Wlogout, Ironbar) can `@import` the generated `palette.css` and use its `@hss_*` named colors instead of their own palette.

Terminal renderers set colors and font family, never font size: size is a user readability preference that themes must not override.

## Units

Each entry in `units.json`:

```json
{
  "id": "kitty",
  "owner": "D05",
  "description": "Kitty colors and font family",
  "applies": {"members": ["terminal/kitty"]},
  "depends": ["theme-core"],
  "executables": ["kitty"],
  "outputs": [
    {"target": "theme:generated/kitty/theme.conf", "class": "generated", "template": "d05/kitty-theme.conf.tmpl", "validator": "none"},
    {"target": "config:kitty/kitty.conf", "class": "managed-region", "comment": "#", "position": "append",
     "content": "include {{path.generated}}/kitty/theme.conf"}
  ],
  "activation": [{"kind": "signal", "process": "kitty", "signal": "USR1"}]
}
```

- `applies`: `{"always": true}`, `{"members": ["role/package", ...]}` (any selected member, primary or not), or `{"packages": [...]}` for generic catalog packages. Optional None selections produce no member units.
- Target prefixes: `theme:` (`~/.config/hss-theme`), `config:` (`$XDG_CONFIG_HOME`), `data:` (`$XDG_DATA_HOME`), `home:` (`$HOME`). No absolute paths, `..` or `~`.
- `class`: `generated` (needs `template`), `managed-keys` (`format` `ini`, `toml` or `kv`; `keys` and/or `keys_template`), or `managed-region` (`comment` is one of `#`, `//`, `--`, `;`, `"`, `/* */`, `<!-- -->`; `position` `append` or `prepend`; `content` or `template`).
- `create_if_missing`: create an absent user file containing only the managed keys or region.
- `validator`: `json`, `toml`, `ini`, `css`, `kdl`, `lua` (uses `luac -p` when available) or `none`.
- `assets`: system files the unit needs at runtime, as `[{"package": "breeze-gtk", "paths": ["/usr/share/themes/{{assets.gtk_theme}}"]}]`. When every path of an asset is absent, the plan lists it under `missing_assets` and the theme switch reports "theme asset missing, install PACKAGE" as pending. Configuration is still written. `HSS_THEME_ASSET_ROOT` prefixes these paths in test fixtures.
- Activation kinds: `signal` (`process`, `signal` USR1/USR2/HUP), `reload` (`argv`, optional `process` that must be running), `gsettings` (`schema`, `key`, `value`), `next-launch`, `relogin`. Activation values may use tokens.
- Each target file belongs to exactly one unit (checked at load time across units and units.d fragments, and at plan time after resolving symlinks; a second unit whose target resolves to an already claimed file is `skipped-conflict`). Several outputs of the same unit may edit one file; they are applied in order.
- Units are planned and committed in dependency order regardless of where they are declared.

Include generated files by absolute path (`{{path.generated}}/...`, or `{{path.generated | uri}}` inside CSS `url()`). Relative `../hss-theme` paths break when an application resolves its configuration directory through a Stow symlink into `~/dotfiles`.

Prefer, in this order: an include of a generated file from a managed region; a generated file in the application's own theme directory; managed keys. Never replace a whole user configuration file.

## Planning statuses

`ready`, `unchanged`, `not-selected`, `not-adopted` (an existing user file has no region or recorded keys and adoption was not approved), `skipped-conflict` (a managed key, region or generated file changed outside the theme), `skipped-dependency` and `failed`.

## Checks

```sh
python3 dotfiles/.config/hypr/theme/hss_theme.py check
bash tests/run.sh tests/shell/theme_rendering.sh tests/shell/theme_activation.sh
```
