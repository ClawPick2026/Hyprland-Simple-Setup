# Changelog

All notable changes to Hyprland-Simple-Setup will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased] - Desktop harmonization

Desktop harmonization on branch `feat/harmonize-visual-design`. Implemented and covered by offline tests; VM acceptance is pending and user-led. See [Desktop harmonization](Documents/desktop-harmonization.md), [VM testing](Documents/desktop-harmonization-vm-testing.md) and the [acceptance matrix](Documents/desktop-harmonization-acceptance.md).

### Added

- **Capability ledger (F01):** `capabilities.json` and `capabilities.d/` record native support and evidence for every option. The installer chooser labels each app `full`, `limited` or `unverified`. The ledger currently lists 20 full, 25 limited and 28 unverified options.
- **Shared runtime (F02):** `action_exec.sh` (semantic actions with fixed exit codes), `status_read.sh` (typed status JSON), `menu_choose.sh` (shared chooser and No/Yes confirmation), window helpers, per-domain providers and managed-configuration rules: theme regions, managed keys and generated files under `~/.config/hss-theme/`. The setup reliability library moved into the installed layout as `scripts/lib/hss_reliability.sh`; the old path is a shim.
- **Theme system (F03):** one token set renders Catppuccin Mocha (dark, default) and Latte (light) with Blue accents, Noto Sans, JetBrains Mono Nerd Font, Breeze icons and the Rose Pine cursor. Switch with `Super+Shift+T`, the bar's theme control, `action_exec.sh theme.set dark|light`, or the installer's **Appearance** setting (`HSS_THEME_VARIANT`). Running apps reload only through a safe native reload; others update at next launch or relogin.
- **Verification foundation (F04):** coverage fragments for every option and None state (260 cases), an evidence template, a manual visual-review protocol and a fixture library. The test runner now removes host session variables. CI runs `hss_theme.py check`.
- **Bars and docks (D01):** Waybar, Ironbar and nwg-panel share the same modules, gestures and status adapters. Docks get default pins and theme units, and a shared nwg-panel bar and dock run as one process.
- **Launchers (D02):** `menu.applications` and `menu.commands` for all five launchers, and the shared chooser with confirmation. The repository picker shows unique labels.
- **Notifications (D03):** do-not-disturb, dismiss, history, center and status actions for SwayNC, Mako, Dunst and fnott. Single-owner enforcement refuses to start a second daemon and never terminates the foreign one.
- **Devices (D04):** network, Bluetooth and audio actions that use each app's native mode and report unsupported operations, plus a guarded Bluetooth radio toggle.
- **Terminal workspace (D05):** theme units for shells, terminals, multiplexers and agents. Terminal themes never change font size.
- **Applications (D06):** default handlers for the primary browser (links, HTML), file manager (folders) and GUI editor (text, scripts), with `HSS_HANDLERS_MODE=apply|preview|skip` and recorded previous associations. With GUI editor set to None, `hss-tui-editor.desktop` opens text files in the primary TUI editor.
- **Session and auxiliary (D07):** session actions for lock, logout, reboot, shutdown, suspend and hibernate, and theme units for Hyprland, hyprlock, wlogout, btop, cava and the keybind viewer.
- **Integration (I01):** setup consent through `HSS_HARMONIZATION_ADOPT=preview|apply|skip` (TUI: **Existing configuration**) with a preview report in the run directory. The `Super+Shift+T` binding is added only when that chord is free. Theme switches and handler changes are restorable with `./setup.sh --rollback RUN_ID`.
- Packages: `noto-fonts`, `rose-pine-cursor` (AUR), `qalculate-gtk` and `ffmpeg`. File-manager extras install with their app: `gvfs` and `thunar-archive-plugin` (Thunar), `nemo-fileroller` (Nemo) and `gvfs` (PCManFM-Qt).

### Changed

- Logout, reboot and shutdown now ask for confirmation (No is the default). Lock is immediate, suspend is direct, and hibernate appears only when the system can hibernate. Logout ends only the current session.
- Left-clicking the bar's notification control runs `notifications.primary`: SwayNC toggles its control center, while Mako, Dunst and fnott dismiss all popups. Right-click toggles do-not-disturb.
- Bar audio, Bluetooth and network clicks go through `action_exec.sh`, so a limited app reports the missing action instead of opening another app.
- Hyprpolkitagent is the only authentication agent setup starts. The KDE agent autostart is removed, and a running foreign agent is reported, not stopped.
- Helix launches as `helix`, the executable Arch installs (previously `hx`). The VS Code desktop ID is now `code.desktop`.
- The Waybar taskbar no longer forces the uninstalled `Numix-Circle` icon theme and follows the GTK icon theme (Breeze). On upgrade, `update-waybar-roles.py` removes only that exact stock value and keeps icon themes you chose yourself.
- Hyprland application windows are fully opaque (opacity 1.0); shell surfaces stay slightly translucent.
- The hyprlock placeholder text is English ("Password") and failures show the PAM message. Lock-screen colors come from the generated theme.
- The stock `XCURSOR_THEME` line points at `BreezeX-RosePine-Linux`. Customized lines are left alone.
- Runtime theme switching requires an installation that setup has adopted. Before adoption, it reports `unavailable` and changes nothing.

### Fixed
- Reruns no longer append a second copy of optional autostart lines (for example `fix-dolphin.sh`) that an earlier run already enabled.
- An invalid `HSS_HARMONIZATION_ADOPT` or `HSS_THEME_VARIANT` is now explained on the console, not only in the run log.
- `setup.sh --rollback` can undo a run whose write failed partway; the failed file is no longer recorded with content it never had.

### Known limitations

- A home directory path containing an apostrophe breaks the generated tmux, fish and vim theme includes.
- No notification daemon offers a native 24-hour history expiry, so all four are `limited`. Fnott has no readable do-not-disturb, and Mako and Dunst have no browsable history.
- Browsers follow only the system dark/light preference. Native widget shapes still differ between toolkits.
- nwg-panel bars have no right-click menus or update count. Docks do not follow the focused output. Ironbar shows no microphone level.
- Some apps apply the theme only at next launch (fnott, nwg-panel, nwg-dock-hyprland, Foot, Konsole, Herdr), and the Xcursor change applies after relogin.
- The SDDM greeter is not themed. Rollback cannot undo runtime effects or package installs.
- 28 options are `unverified` (for example tofi, Ghostty, Konsole, Herdr, plasma-nm, bluedevil, every graphical file manager, every GUI editor and every coding-agent session).

### Verification status

- Offline suites, ledger and coverage validation are delivered. No VM, live-session or hardware check has been run, and all 260 coverage cases are `not-run`. Physical hardware remains unverified.

---

## [0.7.0] - 2026-09-20

## Release v0.7.0

Changes since `v0.6.0`.

## Highlights

- Choose applications across 17 groups, with primary apps used by desktop shortcuts and controls.
- Track setup runs with separate logs, backups, and scoped configuration rollback.
- Use the updated Lua-based Hyprland configuration and expanded Waybar maintenance menu.
- Scroll live installer output without interrupting setup.

## Full Change Summary

### Installation and application choices

- Added a curl-friendly bootstrap installer with repository, revision, and destination options.
- Added independent choices for browsers, shells, terminals, editors, file managers, launchers, notifications, bars, docks, calendars, and desktop controls. Supported groups allow multiple selections and a primary app.
- Added tmux, Zellij, and Herdr multiplexer choices, plus optional terminal file managers. Ctrl+Y opens the primary multiplexer; Super+E opens the graphical file manager.
- Added optional Pi, OpenCode, Claude Code, Codex CLI, and Cursor CLI installation. Authentication remains manual.
- Added Pacsea and usrgrp-manager to the package catalog and corrected package names and sources.
- Shell language settings now apply to selected Bash, Fish, and Zsh installations.

### Installer reliability and interface

- Added `--list-runs` and `--rollback <run-id>`, with per-run manifests, backups, and file-change checks before rollback.
- Added atomic managed-file updates and stricter failure reporting for configuration writes, run metadata, and rollback.
- Dry-run rollback no longer deletes files, validated privileged deletions use sudo, and manifests whose final row lacks a newline are read correctly.
- Generated Lua commands keep argument boundaries and literal characters.
- Unselected role alternatives are removed from explicit and user-added package lists, and registry token checks match the Rust validator.
- Application choosers now show descriptions, support scrolling, and prevent installation with empty required groups.
- Live output supports mouse and keyboard scrolling, a scrollbar, compact/detail views, and a Follow control. Full output is saved separately.

### Desktop and Waybar

- Desktop shortcuts, scratchpads, and Waybar actions now follow selected applications through generated `roles.json` metadata.
- Added a bundled system updater with AUR and repository-only modes, confirmation, duplicate-launch prevention, and logs. Separate menu actions cover firmware, `.pacnew` review, and package-cache cleanup.
- Updated temperature reporting, brightness controls, and the keybinding viewer for Lua configuration.
- Improved wallpaper startup diagnostics and retries, including wallpaper updates for active monitors.
- Startup checks now focus on persistent services and use session-specific readiness markers. An optional troubleshooting action shares diagnostics with the primary coding agent only after a click.

### Tests and maintenance

- Added Rust, shell, Python, and package-registry regression coverage, with separate Rust, shell, and JSON CI jobs.
- Hosted CI, live pacman/AUR availability, and interactive or privileged-system checks were not run before release.

## Breaking Changes

- The shipped Hyprland configuration now uses `hyprland.lua` and Lua modules. Retained `.conf` files are backups, not the active configuration. Monitor and wallpaper helpers now use `sources_specific/monitors.lua` and `change_wallpaper.lua`.
- Setup logs moved from `~/Hyprland-Simple-Setup.log` to `${XDG_STATE_HOME:-$HOME/.local/state}/hyprland-simple-setup/runs/<run-id>/log`. Update scripts that read the old path.

## Upgrade Notes

- Back up custom dotfiles and port existing Hyprland settings to the Lua files before switching. Rerunning setup refreshes managed helpers but does not replace an existing `~/dotfiles` tree or automatically convert all custom configuration.
- Review Applications before installing. Herdr is the default multiplexer, and Pi is selected by default under optional coding agents. Choose None to skip agent installation. Changing selections does not uninstall existing apps.
- Custom multiplexer bindings should execute `apps.multiplex` or `$multiplex` directly, without another terminal wrapper. Setup migrates only recognized stock bindings.
- For unattended installs, use `SHELL_LANGUAGE_CHOICE_OVERRIDE`; the older `FISH_LANGUAGE_CHOICE_OVERRIDE` remains a fallback.
- Rollback restores only files recorded in a run's manifest. It does not undo package installations, service changes, Stow links, or entire directory copies.
- Clicking agent troubleshooting shares diagnostic excerpts with the selected agent and its provider. Credential redaction is best-effort, not a secrecy guarantee.

---

## [0.6.0] - 2026-04-01

# Release v0.6.0

This release focuses on **safer setup behavior**, **better shell/dotfiles**, and **TUI stability improvements**.

## Highlights
- **Setup script hardening**
  - Improved AUR helper detection and support for multiple helpers.
  - Better behavior for **Windows** and **dry-run** modes (skips dependency verification where appropriate while still checking AUR helper logic).
  - Mirror update improvements and better directory/Timeshift handling.
  - PAM configuration handling refactored for clearer and safer appending.
- **TUI improvements**
  - Fixed an input bug where pressing **`q`** in the password field could close the prompt.
  - Refactoring and cleanup to improve readability and maintainability.
  - Package selection/filtering logic improved.
- **Dotfiles & Hyprland tooling updates**
  - Fish shell improvements, including more robust non-interactive language configuration (`FISH_LANGUAGE_CHOICE`).
  - New/updated helper scripts for Hyprland and Waybar (utilities and toggles).
  - Updated themes/configs (Waybar, SwayNC, Kitty, Zellij, Starship, etc.).
- **Project automation**
  - Added/updated GitHub Actions workflows (Rust CI + release workflow).
  - Added `dev/scripts/release.fish` for release automation.

## Notable changes (since v0.5.0)
- Updated README to recommend the `hyprland-simple-setup` TUI command.
- `packages.json`: add `python` and `python-requests`.
- GitHub templates: bug report updated; PR template added.

## Upgrade notes
- If you use Fish in non-interactive setups, review your `FISH_LANGUAGE_CHOICE` usage (whitespace trimming + stricter validation).
- If you customized PAM handling previously, skim the updated `setup.sh` PAM section before re-running the installer.
- As always: consider running `setup.sh` in dry-run first to review planned actions.

## Full changelog
- Compare: `v0.5.0...v0.6.0` (tag this release as `v0.6.0` to enable the GitHub compare link)


---

---

## [0.5.0] - 2025-10-22

# Release Notes

This release is a big step forward for the **TUI installer** and overall setup reliability (dry-run, non-interactive flows, monitor/wallpaper handling, and theming).

## Highlights
- **TUI installer**
  - Added a full install flow with sections, progress/log output, and improved layout/theming.
  - Added monitor setup wizard + visual indicators.
  - Multiple fixes for scrolling, input handling, and install output stability.
  - Keybind help view and improved interaction patterns (including hidden password input).
- **Setup script improvements**
  - Added a **dry-run** option.
  - Improved package verification/auto-install logic and base-devel checks.
  - Better non-interactive behavior (language, wallpaper dir, monitor configuration).
  - Improved wallpaper/monitor detection and runtime-config preference.
  - Fixes for SDDM setup + Hyprlock wallpaper edge cases (incl. AUR installs).
- **Dotfiles / theming**
  - Added KDE theming support (`kdeglobals`) and improved Dolphin theming.
  - Waybar updates (new update button/script, icon/style tweaks, brightness handling improvements, weather tweaks).
  - Fish shell language/env fixes.
- **Docs & examples**
  - README refreshed multiple times and new example screenshots added.

## Notable changes (since v0.4.0)
- Added `Cargo.toml`/`Cargo.lock` and introduced the Rust-based TUI (`src/main.rs`).
- `setup.sh`: non-interactive install improvements + package verification hardening + dry-run support.
- Waybar: added update module/script and refined styles.

## Upgrade notes
- If you previously relied on the old shell-only workflow, review the new TUI flow and its options.
- For automated installs, check your non-interactive settings (language choice, wallpaper directory, monitor config).

## Full changelog
- Compare: `v0.4.0...v0.5.0`



---

## [0.4.0] - 2025-06-04

# Release Notes

## Recent Updates and Fixes

### System Updates and Maintenance
- Improved Arch Linux mirror handling with reflector integration
- Enhanced package management with better error handling
- Added support for Arch Linux specific configurations
- Added local Arch wiki documentation for better reference

### Hyprland Configuration
- Enhanced environment variable handling
- Added better error reporting for failed installations
- Fixed monitor setup issues for better display configuration
- Added brightness control functionality
- Implemented clipboard management with fzf search integration

### Shell and Theme Improvements
- Refactored Fish Shell configuration
- Added GTK and QT application theming support
- Implemented Simple SDDM theme for better login experience

### Notification and System Controls
- Replaced Dunst with SwayNC notification center
- Added Bluetooth toggle functionality (keybind and waybar integration)
- Added startup check for autostart applications on session start

### User Interface Enhancements
- Added Keybinds GUI for simple keybind overview
- Updated README with comprehensive documentation
- Added new example pictures for better visualization

### Testing
- Successfully tested on Arch Linux
- Verified package installations and updates
- Confirmed system configuration compatibility
- Tested mirror synchronization and package management

### Requirements
- Arch Linux or Arch-based distribution
- Base system with standard Arch Linux installation
- Sufficient disk space (minimum 10GB recommended)

### Installation
Please refer to the main README.md for detailed installation instructions.

### Support
For issues and support, please check the repository's issue tracker or refer to the CONTRIBUTING.md file.

**Full Changelog**: https://github.com/Firstp1ck/Hyprland_Simple_Setup/compare/v0.3.1...v0.4.0

---

## [0.3.1] - 2025-05-28

# Release Notes

## Recent Updates and Fixes

### System Updates and Maintenance
- Improved Arch Linux mirror handling with reflector integration
- Enhanced package management with better error handling
- Added support for Arch Linux specific configurations

### Hyprland Configuration
- Enhanced environment variable handling
- Added better error reporting for failed installations

### Testing
- Successfully tested on Arch Linux
- Verified package installations and updates
- Confirmed system configuration compatibility
- Tested mirror synchronization and package management

### Requirements
- Arch Linux or Arch-based distribution
- Base system with standard Arch Linux installation
- Sufficient disk space (minimum 10GB recommended)

### Installation
Please refer to the main README.md for detailed installation instructions.

### Support
For issues and support, please check the repository's issue tracker or refer to the CONTRIBUTING.md file.

**Full Changelog**: https://github.com/Firstp1ck/Hyprland_Simple_Setup/compare/v0.3.0...v0.3.1

---

## [0.3.0] - 2025-05-19

# Release Notes

## Key Features

### 1. Automated Setup & Dependency Management
- **Interactive Setup Script**: `Setup/Start_hyprland_setup.sh` automates installation, configuration, and verification of all required packages (Pacman & AUR), and guides the user through system-specific steps.
- **Logging**: All actions are logged to `~/Linux-Setup.log` for troubleshooting.
- **Package Verification**: Ensures all required packages are installed and reports missing ones.
- **Backup & Stow**: Dotfiles are managed with GNU stow, with automatic backup of existing files.

### 2. Modular Dotfile Structure
- **Config Organization**: All configs are split into modular files (monitors, keybindings, autostart, environment, etc.) for easy customization and troubleshooting.
- **Stow Deployment**: `.local/scripts/Start_stow_solve.sh` deploys dotfiles using stow.

### 3. Hyprland Desktop Environment
- **Multi-Monitor Support**: Interactive monitor configuration, per-monitor workspaces, and dynamic workspace assignment.
- **Window Management**: Advanced controls (edge snap, resize, floating/tiled toggle, window grouping/tabbing).
- **Custom Window Rules**: Easily define rules for floating, centering, opacity, and workspace assignment.
- **Keybindings**: Modular, user-editable keybindings for window management, media, screenshots, and more.

### 4. Visual & Usability Enhancements
- **Waybar Status Bar**: Custom modules (power, weather, updates, Dunst, etc.), system tray, workspace overview, network, volume, battery, and more. Toggle visibility with a script.
- **Wofi Launcher**: Themed, image-capable application launcher with custom menu and style.
- **Kitty Terminal**: Multiple layouts, session management, and custom key mappings.
- **Fish Shell**: Smart history, completions, and workflow aliases.
- **Modern CLI Tools**: Includes `bat`, `lsd`, `btop`, `fzf`, `fd`, and more for an enhanced terminal experience.
- **Theming**: JetBrains Mono Nerd Font, custom CSS for Waybar and Wofi, and easy appearance tweaks.

### 5. Wallpaper & Appearance Management
- **Random Wallpaper Script**: `change_wallpaper.sh` selects a random wallpaper (excluding the current one) and applies it to all monitors, with support for multiple formats.
- **Hyprpaper Integration**: Ensures the wallpaper daemon is running and applies changes live.
- **Night Light**: `hyprsunset.sh` toggles color temperature for day/night modes.

### 6. Notification & System Integration
- **Dunst Notifications**: Persistent critical notifications, action button support, and a script to ensure Dunst is running.
- **Autostart Checks**: `Startup_check.sh` verifies all essential processes (network, clipboard, notifications, etc.) are running and notifies the user of any failures.
- **File Manager Fixes**: `fix-dolphin.sh` ensures Dolphin file manager integration works as expected.

### 7. Productivity & Helper Scripts
- **Music Player**: `play_music.sh` provides a TUI for music playback, including album art and track selection.
- **Notes Utility**: `notes.sh` launches a note-taking session in Kitty and Neovim, with file management.
- **Toggle Scripts**: Scripts to toggle Waybar visibility and window floating state.

### 8. Security & Power Management
- **Screen Locking**: Hyprlock with custom styling and multi-monitor support.
- **Authentication**: Polkit and keyring integration for secure privilege escalation and credential storage.
- **Power Profiles**: Waybar integration for power profile switching and battery monitoring.

### 9. Customization & Extensibility
- **Easy Customization**: All configs are modular and well-commented for user extension.
- **Autostart Applications**: User-defined startup programs via modular config.
- **Environment Variables**: Locale, language, and environment settings are modular and easily adjustable.

### 10. Troubleshooting & Recovery
- **Comprehensive Logging**: All setup and runtime actions are logged for easy troubleshooting.
- **Helper Scripts**: For common issues (e.g., fixing Dolphin, restarting Dunst, checking autostart status).
- **Recovery Options**: Guidance for configuration errors and Hyprland startup issues.

## Supported Platforms
- **Arch Linux** and derivatives (EndeavourOS tested)
- **Wayland** (Hyprland compositor)

## Getting Started
1. Clone the repository and run the setup script to install dependencies and configure your system.
2. Deploy dotfiles using the provided stow script.
3. Customize configuration files as needed for your environment.

For detailed instructions, see the `README.md`.

## Additional Resources
- [Hyprland Wiki](https://wiki.hyprland.org/)
- [Waybar Wiki](https://github.com/Alexays/Waybar/wiki)
- [Kitty Documentation](https://sw.kovidgoyal.net/kitty/)
- [Fish Shell Docs](https://fishshell.com/docs/current/index.html)

For issues, suggestions, or contributions, please open an issue or pull request on GitHub. 

---

## [0.2.0] - 2025-05-07

# Release Notes

## Version 0.2.0 (2024-05-07)

### Major Changes in Setup Script vs. Documentation

#### Package Management Updates
- Added new core Hyprland packages not listed in README:
  - `hyprcursor`
  - `wl-clipboard` and `wl-clip-persist`
  - `hyprgraphics`
  - `hyprland-qtutils`
  - `hyprland-qt-support`
  - `hyprwayland-scanner`

#### New Development Tools
- Added additional development tools:
  - `fd` - Modern alternative to `find`
  - `fzf` - Fuzzy finder
  - `nvim` - Neovim editor
  - `git` - Version control

#### Enhanced Terminal Experience
- Added new terminal utilities:
  - `khal` - Calendar application
  - `zoxide` - Smarter cd command
  - `lshw` - Hardware lister
  - `fastfetch` - System information tool
  - `tldr` - Simplified man pages
  - `konsole` - KDE terminal emulator

#### System Integration
- Added new system utilities:
  - `ntfs-3g` - NTFS filesystem support
  - `firewalld` - Firewall management
  - `qalculate-gtk` - Advanced calculator

#### AUR Package Updates
- Added new AUR packages not documented in README:
  - `lsplug` - Plugin manager
  - `waypaper-git` - Wallpaper manager
  - `pyprland` - Python bindings
  - `wl-clipboard-history-git` - Clipboard manager
  - `hyprsunset` - Night light feature
  - `github-desktop-bin` - GitHub desktop client

### Configuration Improvements

#### Language Configuration
- Added interactive language selection during setup:
  - de_CH (Swiss German)
  - de_DE (German)
  - en_US (US English)
- Automated fish shell language configuration

#### Monitor Configuration
- Added interactive monitor configuration:
  - Resolution prompt per monitor
  - Refresh rate customization
  - Automatic configuration file generation

#### Backup Management
- Added automatic backup creation for configuration files
- Implemented timestamp-based backup naming

### Script Enhancements

#### Error Handling
- Added comprehensive error checking
- Implemented dependency validation
- Added wallpaper directory validation

#### User Experience
- Added colored output messages
- Interactive prompts for critical decisions
- Progress feedback during installation

**Full Changelog**: https://github.com/Firstp1ck/Hyprland_Simple_Setup/compare/v0.1.0...v0.2.0

---

## [0.1.0] - 2025-03-27

# Release Notes

- **New Features:**
  - Initial release of the Hyprland Simple Setup.
  - Includes basic configuration for Hyprland, hyprlock, and other essential utilities.
  - Sample wallpapers and example images provided.

- **Improvements:**
  - Optimized startup scripts for faster configuration.
  - Enhanced documentation covering installation, customization, and troubleshooting.

- **Bug Fixes:**
  - Fixed minor issues with monitor configuration.
  - Resolved compatibility problems in hyprland.conf.

## Additional Information

For detailed documentation, please refer to the [README.md](README.md) file.  
For further troubleshooting and feedback, open an issue via [GitHub Issues](https://github.com/yourusername/Hyprland_Simple_Setup/issues).

Enjoy your new Hyprland experience!

