# Desktop harmonization

Every application you can pick in the installer keeps working the same way at the desktop level: the same shortcuts, bar controls, menus, power actions, file and link handlers, and one shared Catppuccin appearance. Applications keep their own internal features; harmonization does not turn one app into another.

## Appearance

- Dark uses Catppuccin Mocha and light uses Catppuccin Latte, both with Blue accents.
- GUI text uses Noto Sans; terminals and code use JetBrains Mono Nerd Font. Terminal themes never change your font size.
- Icons are Breeze (`breeze-dark` or `breeze`). The cursor is Rose Pine: Hyprland uses `rose-pine-hyprcursor`, and every other toolkit uses the matching Xcursor build `BreezeX-RosePine-Linux` from the `rose-pine-cursor` package.
- GTK, Qt and KDE applications get the palette through their supported settings: Breeze GTK named colors, qt5ct/qt6ct color schemes, `kdeglobals` color groups and the desktop color-scheme preference that libadwaita, browsers and Electron editors follow. Native widget shapes still differ between toolkits.
- Shell surfaces (bars, menus, notifications) may be slightly translucent; application content stays opaque.

Dark is the default for new installations. Existing installations keep their recorded choice.

### Switching dark and light

Use any of these. They all run the same internal action and never install packages:

- `Super+Shift+T` in Hyprland. Setup adds this binding only when you have not already bound that key combination; a conflict is reported and your binding is kept.
- The theme button on the bar.
- The installer's **Appearance** setting, or `HSS_THEME_VARIANT=dark|light` for `setup.sh`.
- `~/.config/hypr/scripts/action_exec.sh theme.set dark|light` (or `theme.toggle`) from a terminal.

The shortcut, bar control and command switch only configuration that setup has already adopted. Before adoption they report that the theme is unavailable and change nothing (see [Existing installations](#existing-installations)).

Running applications are reloaded only when they support a safe native reload (for example Kitty, Waybar, SwayNC, Mako, Dunst and Hyprland itself). Everything else picks up the change the next time it starts; a few settings, such as the cursor, apply after the next login. Nothing is restarted for you.

Generated theme files live in `~/.config/hss-theme/`. Do not edit them; they are rewritten on every switch. Change the tokens in `~/.config/hypr/theme/tokens.json` instead.

## Support labels

The installer shows a label for each application:

| Label | Meaning |
|---|---|
| `full` | Every required desktop workflow for that group is provided by the application's own native features, and the setup has evidence for it. |
| `limited` | At least one required workflow has no native support in that application. The app stays selectable and launches normally; the missing action explains itself instead of doing something else. |
| `unverified` | The behavior could not be checked yet, usually because it needs a real graphical session, hardware or an application that is not packaged for the test platform. |

Limitations are never filled in with extra helper programs, and a missing action never silently opens a different app. For example, an ALSA-only mixer cannot control per-application volume, so the "application volumes" action reports that it is unsupported.

The labels come from the capability ledger, `capabilities.json` and `capabilities.d/`, which records the native evidence behind every claim.

## Existing installations

Setup never rewrites your configuration without consent:

| `HSS_HARMONIZATION_ADOPT` / installer setting | Effect |
|---|---|
| `preview` (default for installations that never adopted the theme) | Nothing is changed. Setup prints which files and settings would change and stores the full report in the setup run directory. |
| `apply` | Adds theme includes or managed keys to your existing configuration files, applies the selected variant and reloads what can be reloaded safely. |
| `skip` | Leaves desktop harmonization alone. |

Once a configuration has been adopted, later setup runs keep applying selection and variant changes unless you choose `skip`. Automatic adoption (a fresh install, or a later run after you adopted once) only covers files setup installed under `~/dotfiles`, files that do not exist yet and files already managed; your own configuration files elsewhere are previewed until you choose `apply` explicitly.

What adoption touches:

- **Includes and regions.** Lines between `>>> hss-theme:<name> >>>` and `<<< hss-theme:<name> <<<` comments belong to the theme. Everything outside them is yours and is never changed.
- **Managed keys.** A short list of appearance keys in files such as `gtk-3.0/settings.ini`, `qt6ct/qt6ct.conf` and `kdeglobals`. Other keys, comments and order stay as they are.
- **Generated files.** These are written only under `~/.config/hss-theme/` and in a few application theme directories.

If you later change a managed key or a theme region yourself, that application is skipped and your edit is preserved. Other applications still switch, and setup and the theme switch report the result as partially applied.

## Default applications

Approved primary choices also become the default handlers:

- The primary browser opens web links and HTML files.
- The primary graphical file manager opens folders.
- The primary GUI editor opens text files and shell scripts. With GUI editor set to None, a managed desktop entry opens them in the primary TUI editor inside the selected terminal.

The previous associations are recorded, so a rollback restores only what setup changed. Browser profiles, editor extensions, calendars and accounts are never touched.

## Session and power

- Hyprpolkitagent is the authentication agent. Setup no longer starts a second KDE agent. An authentication agent that is already running is reported, not stopped.
- Logout, reboot and shutdown ask for confirmation. Lock is immediate and suspend is direct. Hibernate appears only when the system reports that it can hibernate.
- Logout ends only the current session. If that session cannot be identified, logout fails with an explanation instead of ending all of your sessions.

## Notifications

One notification daemon owns the notification service at a time. If another daemon already owns it, the selected one is not started and the conflict is logged; nothing is terminated. Do-not-disturb hides ordinary popups and lets critical ones through where the daemon supports it. The lock screen is meant to hide notifications; this is not verified until the VM check. History limits use each daemon's own settings. No extra history storage is added, so daemons that cannot meet the retention policy are labeled `limited`.

## Recovery

Every theme switch and every setup run is recorded:

```sh
./setup.sh --list-runs
./setup.sh --rollback RUN_ID
```

Rollback restores the files that run changed, guarded by checksums. If you edited a file after that run, rollback asks before overwriting it. Rollback cannot undo runtime effects such as a notification that was already shown or an application that was already reloaded.

## Verified environments

Automated tests run against current Arch Linux packages. Visual and live-session behavior is checked manually in a disposable Arch Linux VM; see [VM testing](desktop-harmonization-vm-testing.md). Other Arch-based distributions and physical hardware (radios, audio devices, battery, backlight, suspend/hibernate, mixed-DPI monitors) are unverified. The current state of every check is in the [acceptance matrix](desktop-harmonization-acceptance.md); VM acceptance is still pending.
