# Desktop harmonization: VM testing checklist

**Status: implemented on branch `feat/harmonize-visual-design`; VM acceptance pending (user-led).** None of the checks below has been run in a VM yet. Every coverage case is still `not-run`, and the support labels in the installer come from offline tests, research probes and documentation, not from a graphical session.

This checklist is for the person testing the branch in a disposable Arch Linux VM. Work through it in order: foundations, theme switching, every role and option, partial application and recovery, then record the evidence. Each check lists its steps and expected result, plus the coverage case ID used as the `case` field in its evidence record (see [Recording evidence](#7-recording-evidence)). Background: [Desktop harmonization](desktop-harmonization.md), [Runtime actions and managed configuration](runtime-managed-configuration.md), the [acceptance matrix](desktop-harmonization-acceptance.md) and the [visual review protocol](../tests/fixtures/harmonization/visual-protocol.md).

Labels are kept apart: `full`, `limited` and `unverified` describe an option in the capability ledger, while `passed`, `failed`, `blocked` and `skipped` describe one VM check. A VM run never certifies physical hardware such as radios, audio devices, batteries, backlights, suspend/hibernate or mixed-DPI hotplug. Record those checks as `blocked` or `skipped` with the reason.

## 1. Prerequisites

1. **Disposable VM.** Install current Arch Linux in a VM that can run Hyprland, for example QEMU/KVM with virtio-gpu and 3D acceleration. Give it network access, SDDM as the login manager (setup configures it), at least two virtual outputs if your hypervisor supports them, and a second TTY you can log in on.
2. **Snapshots.** Take a snapshot `clean-base` before running setup. Take another, `installed`, after the first successful setup run (section 2.1). Revert to these instead of repairing a broken state by hand.
3. **AUR helper.** Install `yay` as shown in the README Quick Start (`git`, `base-devel`, `makepkg -si`).
4. **Get the branch into the VM.** The harmonization work is currently uncommitted in the branch checkout, so the VM must receive exactly that tree:
   - If the branch has been committed and pushed: `git clone -b feat/harmonize-visual-design https://github.com/firstp1ck/Hyprland-Simple-Setup.git ~/Hyprland-Simple-Setup`, or `install.sh --ref feat/harmonize-visual-design --no-tui`.
   - Otherwise copy the working tree into the VM (shared folder or `rsync -a --exclude target/ ...`) to `~/Hyprland-Simple-Setup`.
   - Record `git -C ~/Hyprland-Simple-Setup rev-parse HEAD` and, for a copied tree, `git status --short | sha256sum`. Use this as `versions.repository_commit` in every evidence record.
5. **Upgrade baseline (optional, for section 2.3).** In a separate snapshot, install the previous release first (`git clone -b v0.7.0 ...` and run its `setup.sh`), log in once, then copy in the branch tree. This gives an existing installation that has never adopted the theme.
6. **Observation tools.** All are in the catalog or base system: `jq`, `notify-send` (libnotify), `busctl`, `xdg-mime`, `hyprctl`, `wpctl`, `grim` and `slurp`. The helpers used below live in `~/.config/hypr/scripts/`:
   ```sh
   S=~/.config/hypr/scripts
   $S/status_read.sh theme              # typed status for theme, notifications, network, bluetooth, audio, session
   $S/action_exec.sh --json theme.toggle # prints one result envelope with outcome and exit_status
   ```
7. **Synthetic data only.** Do not sign in to accounts or import real profiles, calendars or files. Create the review content from [visual protocol section 2](../tests/fixtures/harmonization/visual-protocol.md#2-synthetic-content). Coding-agent launch checks need your own agent account; skip them if you do not want to sign in.
8. **Repository checks inside the VM (optional).** With Hyprland installed, `bash tests/verify_hypr_config.sh` runs the real `Hyprland --verify-config` instead of skipping with exit 3. Record its output as `static` evidence. The other repository checks are listed in the [acceptance matrix](desktop-harmonization-acceptance.md#6-repository-checks).

## 2. Foundations: setup, consent, preview and rollback

Run these in order from the `clean-base` snapshot unless noted. "Setup" means either the TUI (`cargo run --release` or `hyprland-simple-setup`) or `./setup.sh`. The TUI preflight has two settings for this work: **Appearance** (Keep current / Dark / Light, exported as `HSS_THEME_VARIANT`) and **Existing configuration** (Automatic / Preview only / Apply harmonized configuration / Skip, exported as `HSS_HARMONIZATION_ADOPT`). Automatic and Keep current export nothing. Default handlers follow `HSS_HANDLERS_MODE` (`apply` by default, `preview` or `skip`); it has no TUI setting.

State and run records live in `${XDG_STATE_HOME:-~/.local/state}/hyprland-simple-setup/runs/<run-id>/`. A preview leaves `theme-report.json` there, and handler changes leave `handlers-preview.tsv` and `handlers.tsv`. Theme state is in `~/.config/hss-theme/state.json` and `managed.json`.

### 2.1 Fresh installation

| # | Steps | Expected result | Case |
|---|---|---|---|
| F-1 | Run setup with all defaults (Appearance: Keep current, Existing configuration: Automatic). Reboot and log in through SDDM. | Setup summary shows Desktop Harmonization as applied, not "Preview only". `status_read.sh theme` reports `"variant":"dark"` and `"batch":"complete"`, or lists `partial_units` with reasons. `~/.config/hss-theme/` exists, and `hyprctl binds` lists "Toggle Dark/Light Theme" on Super+Shift+T exactly once. | `F04-managed-configuration` |
| F-2 | Open a terminal, the file manager (Dolphin, Qt/KDE) and a GTK app (Qalculate with `Super+Enter`). | Catppuccin Mocha surfaces, Blue accent, Noto Sans GUI text, JetBrains Mono Nerd Font in the terminal, Breeze icons and the Rose Pine cursor over Hyprland, GTK and Qt windows. Application windows are opaque. | `F04-theme-visual-review` |
| F-3 | Trigger one action from a keybinding and one from the bar, then run an unsupported action, for example `action_exec.sh notifications.center.toggle` with Mako selected (section 4, D03). | Each action works once. The unsupported action shows one explanatory notification and opens nothing else. | `F04-action-dispatch` |
| F-4 | With the notification daemon running, run `~/.config/hypr/scripts/role_exec.sh notifications` again. | Nothing new starts and the running daemon keeps its notifications. A foreign owner is reported as a conflict (exit 10) and never terminated. | `F04-dbus-ownership-probe` |
| F-5 | Run setup a second time with the same selection. Then take the `installed` snapshot. | Theme units report `unchanged`. Super+Shift+T is still bound once, no service starts twice, and `./setup.sh --list-runs` shows the new run. | `F04-managed-configuration` |

### 2.2 Consent modes

| # | Steps | Expected result | Case |
|---|---|---|---|
| C-1 | On an existing installation that never adopted the theme (2.3 baseline), run setup with Existing configuration: Automatic. | Mode is `preview`. Setup prints "Existing configuration was not changed" and the path of `theme-report.json`, which lists units, targets and reasons. `~/.config/hss-theme/managed.json` records no keys or regions, and `grep -rl '>>> hss-theme' ~/.config/` finds no new regions. Other setup steps, such as role lines and default handlers, still run as before. | `F04-managed-configuration` |
| C-2 | Before adopting, press `Super+Shift+T` (if bound) or run `action_exec.sh --json theme.toggle`. | Outcome `unavailable` (exit 7): "the desktop theme has not been adopted yet". Nothing changes, including desktop settings. | `F04-managed-configuration` |
| C-3 | Run setup with `HSS_HARMONIZATION_ADOPT=apply` (TUI: Existing configuration → Apply). | Theme regions (`>>> hss-theme:<name> >>>` ... `<<< hss-theme:<name> <<<`) and managed keys are added to existing files. Text outside the regions is unchanged; compare with the backups in the run directory. | `F04-managed-configuration` |
| C-4 | Run setup with `HSS_HARMONIZATION_ADOPT=skip`. | "Desktop harmonization skipped". No theme file changes and the run records a skip. | `F04-managed-configuration` |
| C-5 | Run setup with `HSS_THEME_VARIANT=light`, then again with Appearance: Keep current. | First run applies Latte. The second keeps light, as recorded in `~/.config/hss-theme/state.json`. | `F04-theme-activation` |
| C-6 | Before setup, bind `Super+Shift+T` to something else in `~/.config/hypr/sources/keybindings.lua`, then run setup. | Setup warns that Super+Shift+T is already bound, keeps your binding and adds no theme binding. The bar theme control still works. | `F04-managed-configuration` |
| C-7 | Run setup with `HSS_HANDLERS_MODE=preview` after changing the primary browser. | `handlers-preview.tsv` lists the planned association changes and `xdg-mime query default x-scheme-handler/https` is unchanged. Rerunning with the default `apply` changes it. | `D06-firefox-handlers` (or the browser under test) |

### 2.3 Upgrade from v0.7.0

| # | Steps | Expected result | Case |
|---|---|---|---|
| U-1 | From the v0.7.0 baseline, run the branch setup with defaults. | Preview only (C-1). `roles.json` keeps schema 2. Existing selections, custom bindings and locale settings are preserved. | `F04-managed-configuration` |
| U-2 | Rerun with Apply. Log out and back in. | Theme applied as in F-1. The stock `XCURSOR_THEME` line now points at `BreezeX-RosePine-Linux`; a customized line is left alone. | `F04-managed-configuration` |

### 2.4 Rollback

| # | Steps | Expected result | Case |
|---|---|---|---|
| R-1 | `./setup.sh --list-runs`. Pick the run ID of the last theme switch (each switch is its own run) and run `./setup.sh --rollback RUN_ID`. | The files in that run's manifest return to their previous content, guarded by digests. Rollback does not reload anything: running applications keep their appearance until they reload or restart. | `F04-managed-configuration` |
| R-2 | Switch the theme, edit one of the files it changed, then roll that run back non-interactively. | Rollback stops before overwriting the edited file and reports it. Your edit is kept. | `F04-managed-configuration` |
| R-3 | Change the primary browser, run setup, then `./setup.sh --rollback RUN_ID` for that run. | Only the association entries that run wrote are restored. An entry you changed afterwards is kept and reported as a conflict. | `D06-firefox-handlers` |
| R-4 | Run two `action_exec.sh theme.toggle` commands at the same time. | One applies. The other reports `conflict` (exit 10, "another setup or theme change is running") and writes nothing. | `F04-theme-activation` |

## 3. Theme switching

Do these on the `installed` snapshot with a terminal, a GTK app and a Qt app open.

| # | Steps | Expected result | Case |
|---|---|---|---|
| T-1 | Press `Super+Shift+T`. | Variant flips (dark ↔ light). Kitty, Waybar, SwayNC, Mako, Dunst and Hyprland borders reload live where they are running. Other apps change the next time they start, and the cursor changes after the next login. Nothing new is launched and no package is installed. | `F04-theme-activation` |
| T-2 | Click the theme control on the bar. Repeat on every bar you test in section 4. | Same as T-1, and the bar icon follows the variant. | `D01-bar-<bar>-theme-control` |
| T-3 | `~/.config/hypr/scripts/action_exec.sh --json theme.set light`, then `theme.set dark`, then `theme.set dark` again. | Envelopes report `completed`. The third call changes nothing (`unchanged` units). `status_read.sh theme` matches each request. | `F04-theme-activation` |
| T-4 | `action_exec.sh --json theme.set blue` | Outcome `usage` (exit 2) and no change. | `F04-action-dispatch` |
| T-5 | Edit one managed key, for example `gtk-theme-name` in `~/.config/gtk-3.0/settings.ini`, then press `Super+Shift+T`. | The GTK unit is reported as `skipped-conflict` and your edit stays. Other units switch, and status reports `"batch":"partial"` with the unit in `partial_units`. | `F04-managed-configuration` |
| T-6 | Follow the [visual protocol](../tests/fixtures/harmonization/visual-protocol.md) for the theme-core scenes in dark and light. | A signed review with every rubric row answered. Readable focus in both variants; shell surfaces slightly translucent, application content opaque. | `F04-theme-visual-review` |

## 4. Roles and options by domain

### 4.1 Selection rounds

Single-choice roles can hold only one option at a time, so test in rounds. Revert to `installed`, or rerun setup with the next round's selection; setup never uninstalls earlier choices. Then log out and back in. For multi-choice roles, select every member from round 2 on, so all member themes are present, and rotate the primary. Bold entries are None states.

| Round | Bar / dock | Launcher | Notifications | Network | Bluetooth | Audio | File manager | Calendar | Primary browser / shell / terminal / multiplexer / TUI editor / GUI editor | TUI file manager | Agent |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 (defaults) | waybar / **None** | wofi | swaync | plasma-nm | bluedevil | pavucontrol-qt | dolphin | merkuro | zen-browser-bin / fish / kitty / herdr-bin / neovim / visual-studio-code-bin | **None** | pi |
| 2 | ironbar / nwg-dock-hyprland | rofi | mako | network-manager-applet | blueman | pavucontrol | thunar | gnome-calendar | firefox / bash / alacritty / tmux / helix / zed | yazi | opencode |
| 3 | nwg-panel / nwg-panel | fuzzel | dunst | nm-connection-editor | bluetui | qastools | nautilus | korganizer | chromium / zsh / foot / zellij / vim / kate | ranger | claude-code |
| 4 | waybar / nwg-panel | bemenu | fnott | networkmanager | bluetuith | alsa-utils | nemo | calcurse | vivaldi / fish / ghostty / tmux / nano / mousepad | lf (members nnn, mc, vifm) | codex-cli |
| 5 | ironbar / **None** | tofi | swaync | plasma-nm | bluedevil | ncpamixer | pcmanfm-qt | khal | brave-bin / bash / konsole / herdr-bin / neovim / **None** | nnn, then mc, then vifm as primary | cursor-cli, then **None** |
| 6 | round 1 again | | | | | | | | | | |

Round 6 checks inbound switching (None → option for GUI editor and agent) and an identical rerun after many changes. For the nine bar/dock combinations (`D01-bar-dock-combinations`), cycle only `ROLE_BAR` and `ROLE_DOCK` and log in again each time.

Example for round 2 with the shell installer:

```sh
ROLE_BAR=ironbar ROLE_DOCK=nwg-dock-hyprland ROLE_LAUNCHER=rofi ROLE_NOTIFICATIONS=mako \
ROLE_NETWORK=network-manager-applet ROLE_BLUETOOTH=blueman ROLE_AUDIO=pavucontrol \
ROLE_FILE_MANAGER=thunar ROLE_CALENDAR=gnome-calendar \
ROLE_BROWSER=firefox ROLE_BROWSER_PACKAGES='firefox chromium vivaldi zen-browser-bin brave-bin' \
ROLE_SHELL=bash ROLE_SHELL_PACKAGES='bash fish zsh' \
ROLE_TERMINAL=alacritty ROLE_TERMINAL_PACKAGES='kitty alacritty ghostty konsole foot' \
ROLE_MULTIPLEXER=tmux ROLE_MULTIPLEXER_PACKAGES='tmux zellij herdr-bin' \
ROLE_TUI_EDITOR=helix ROLE_TUI_EDITOR_PACKAGES='neovim helix vim nano' \
ROLE_GUI_EDITOR=zed ROLE_GUI_EDITOR_PACKAGES='zed visual-studio-code-bin cursor-bin kate mousepad' \
ROLE_TUI_FILE_MANAGER=yazi ROLE_TUI_FILE_MANAGER_PACKAGES='yazi ranger lf nnn mc vifm' \
ROLE_AGENT=opencode ROLE_AGENT_PACKAGES='opencode' \
./setup.sh
```

After each round, check the setup report: every selected member has its theme unit listed, and None roles list none.

### 4.2 Checks per domain

The tables below are generated from the coverage fragments. Rows that share the same steps across options of one role are merged. Run the row once per listed option, in the round where that option is selected, and record one evidence entry per case ID. The Evidence column is the level the case requires (`evidence_required`). A VM observation can satisfy `real-effect` and `visual`. Cases that require only `argv` or `modeled-effect` are already covered by automated suites, and the VM step is a supplementary end-to-end check. Run `S=~/.config/hypr/scripts` first; `action_exec.sh` and `status_read.sh` below mean `$S/action_exec.sh` and `$S/status_read.sh`.

#### D01 Bars and docks

Source: `tests/fixtures/harmonization/coverage/d01-panels.json` (83 cases).

| Case | Option | Steps and expected result | Known limits | Evidence |
|---|---|---|---|---|
| `D01-bar-waybar-outputs`<br>`D01-bar-ironbar-outputs`<br>`D01-bar-nwg-panel-outputs` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: connect a second monitor (or add a virtual output) and confirm the bar appears on both; unplug it again | - | `real-effect` |
| `D01-bar-waybar-power-screen`<br>`D01-bar-ironbar-power-screen`<br>`D01-bar-nwg-panel-power-screen` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: left-click the power control; the power screen opens | - | `real-effect` |
| `D01-bar-waybar-power-menu`<br>`D01-bar-ironbar-power-menu`<br>`D01-bar-nwg-panel-power-menu` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: right-click the power control; choose each entry and cancel the confirmation for shutdown/reboot/logout; suspend directly | nwg-panel: nwg-panel buttons and executors have no right-click menus; the controls popup is not used because it adds a SwayNC widget | `real-effect` |
| `D01-bar-waybar-app-menu`<br>`D01-bar-ironbar-app-menu`<br>`D01-bar-nwg-panel-app-menu` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: left-click Menu twice: the launcher opens and closes | - | `real-effect` |
| `D01-bar-waybar-tools-menu`<br>`D01-bar-ironbar-tools-menu`<br>`D01-bar-nwg-panel-tools-menu` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: right-click Menu; open each entry (snapshot only when Timeshift is configured) | nwg-panel: No right-click menus in nwg-panel 0.12.1 | `real-effect` |
| `D01-bar-waybar-tray`<br>`D01-bar-ironbar-tray`<br>`D01-bar-nwg-panel-tray` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: start nm-applet or another tray app; its icon appears and opens its menu | - | `real-effect` |
| `D01-bar-waybar-workspaces`<br>`D01-bar-ironbar-workspaces`<br>`D01-bar-nwg-panel-workspaces` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: open windows on workspaces 1, 2 and 10; click each workspace in the bar | - | `real-effect` |
| `D01-bar-waybar-submap`<br>`D01-bar-ironbar-submap`<br>`D01-bar-nwg-panel-submap` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: enter a Hyprland submap; its name appears and disappears on exit | - | `real-effect` |
| `D01-bar-waybar-audio`<br>`D01-bar-ironbar-audio`<br>`D01-bar-nwg-panel-audio` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: change volume and mute with keys; left click opens application volumes, right click the device mixer | ironbar: Output volume and both gestures are native; the microphone level is not shown on the bar | `real-effect` |
| `D01-bar-waybar-backlight`<br>`D01-bar-ironbar-backlight`<br>`D01-bar-nwg-panel-backlight` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: on a laptop scroll over brightness; in the VM confirm the n/a state | - | `real-effect` |
| `D01-bar-waybar-backlight-presets`<br>`D01-bar-ironbar-backlight-presets`<br>`D01-bar-nwg-panel-backlight-presets` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: right-click brightness and choose 50% | nwg-panel: Executors have no menus | `real-effect` |
| `D01-bar-waybar-temperature`<br>`D01-bar-ironbar-temperature`<br>`D01-bar-nwg-panel-temperature` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: hover for sensors; left click opens the system monitor | - | `real-effect` |
| `D01-bar-waybar-lock-keys`<br>`D01-bar-ironbar-lock-keys`<br>`D01-bar-nwg-panel-lock-keys` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: toggle Num Lock; the indicator follows (or shows the explicit unreadable state) | - | `real-effect` |
| `D01-bar-waybar-battery`<br>`D01-bar-ironbar-battery`<br>`D01-bar-nwg-panel-battery` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: in the VM confirm battery n/a; on a laptop check charging and low states | - | `real-effect` |
| `D01-bar-waybar-network`<br>`D01-bar-ironbar-network`<br>`D01-bar-nwg-panel-network` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: left click: choose a network; right click: edit connections; disable Wi-Fi and check the state | - | `real-effect` |
| `D01-bar-waybar-bluetooth`<br>`D01-bar-ironbar-bluetooth`<br>`D01-bar-nwg-panel-bluetooth` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: without an adapter the bar shows n/a; with one, right click toggles power | - | `real-effect` |
| `D01-bar-waybar-updates`<br>`D01-bar-ironbar-updates`<br>`D01-bar-nwg-panel-updates` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: wait for the update count; left click asks for confirmation | nwg-panel: Left click starts the confirmed update; the update count needs a streaming widget, which executors are not | `real-effect` |
| `D01-bar-waybar-updates-menu`<br>`D01-bar-ironbar-updates-menu`<br>`D01-bar-nwg-panel-updates-menu` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: right-click updates; run Check and Show log | nwg-panel: Executors have no menus | `real-effect` |
| `D01-bar-waybar-notifications`<br>`D01-bar-ironbar-notifications`<br>`D01-bar-nwg-panel-notifications` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: send notifications, toggle DND with right click, open notifications with left click; stop the daemon and check the state | - | `real-effect` |
| `D01-bar-waybar-theme-control`<br>`D01-bar-ironbar-theme-control`<br>`D01-bar-nwg-panel-theme-control` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: click the theme control: dark/light switches and the icon follows | - | `real-effect` |
| `D01-bar-waybar-clock`<br>`D01-bar-ironbar-clock`<br>`D01-bar-nwg-panel-clock` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: left click opens the selected calendar; check the time format | ironbar: Left click opens the selected calendar; the clock follows the system time zone (no time-zone option) | `real-effect` |
| `D01-bar-waybar-unavailable-hardware`<br>`D01-bar-ironbar-unavailable-hardware`<br>`D01-bar-nwg-panel-unavailable-hardware` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: in the VM, battery/backlight show n/a pills, not empty space | - | `real-effect` |
| `D01-bar-waybar-appearance`<br>`D01-bar-ironbar-appearance`<br>`D01-bar-nwg-panel-appearance` | `bar/waybar`<br>`bar/ironbar`<br>`bar/nwg-panel` | For each option: switch dark/light with Super+Shift+T and the bar control; inspect normal, hover, focused workspace, warning, critical, muted and n/a states and the menus/tooltips | - | `visual` |
| `D01-dock-nwg-dock-hyprland-pins`<br>`D01-dock-nwg-panel-pins` | `dock/nwg-dock-hyprland`<br>`dock/nwg-panel` | For each option: fresh install: pins show terminal, browser, file manager and GUI editor; add a pin, restart the dock, it stays | - | `real-effect` |
| `D01-dock-nwg-dock-hyprland-running`<br>`D01-dock-nwg-panel-running` | `dock/nwg-dock-hyprland`<br>`dock/nwg-panel` | For each option: start an unpinned app; it appears in the dock | - | `real-effect` |
| `D01-dock-nwg-dock-hyprland-launch-focus`<br>`D01-dock-nwg-panel-launch-focus` | `dock/nwg-dock-hyprland`<br>`dock/nwg-panel` | For each option: click a pinned app twice: first launches, second focuses the same window | nwg-panel: Pins always launch a new instance; a running window is focused through its taskbar button | `real-effect` |
| `D01-dock-nwg-dock-hyprland-active-indicator`<br>`D01-dock-nwg-panel-active-indicator` | `dock/nwg-dock-hyprland`<br>`dock/nwg-panel` | For each option: switch between windows; the indicator follows focus | - | `real-effect` |
| `D01-dock-nwg-dock-hyprland-follow-focus`<br>`D01-dock-nwg-panel-follow-focus` | `dock/nwg-dock-hyprland`<br>`dock/nwg-panel` | For each option: with two outputs, focus the second output; the dock stays on the primary output (expected limitation) | nwg-dock-hyprland: The dock stays on the output where it started (fixed primary output)<br>nwg-panel: The dock panel stays on output 0 (fixed primary output) | `real-effect` |
| `D01-dock-nwg-dock-hyprland-appearance`<br>`D01-dock-nwg-panel-appearance` | `dock/nwg-dock-hyprland`<br>`dock/nwg-panel` | For each option: switch dark/light, restart the dock if the option needs it, and inspect the focused-app indicator and hover | nwg-dock-hyprland: CSS is read only at startup; running-indicator images keep their upstream colors | `visual` |
| `D01-dock-none` | `dock/none` | Select None for Dock: no dock appears after login, Super+H still hides only the bar, and no dock theme unit is listed in the setup report | - | `modeled-effect` |
| `D01-bar-dock-combinations` | cross-role | Log in with each of the nine bar/dock combinations; with nwg-panel as bar and dock only one nwg-panel process runs; Super+H hides only the bar | Hermetic test covers process starts with stub programs; real compositor behavior is the VM check | `real-effect` |

#### D02 Launchers and shared menus

Source: `tests/fixtures/harmonization/coverage/d02-launchers.json` (22 cases).

| Case | Option | Steps and expected result | Known limits | Evidence |
|---|---|---|---|---|
| `D02-wofi-applications`<br>`D02-rofi-applications`<br>`D02-fuzzel-applications`<br>`D02-tofi-applications` | `launcher/wofi`<br>`launcher/rofi`<br>`launcher/fuzzel`<br>`launcher/tofi` | For each option: select the app; press Super+Space and run action_exec.sh menu.applications: both open the same desktop-application list; start an application, then press Escape on a second run and confirm nothing starts | rofi: Keyboard paths were not exercisable through Xwayland in the headless probe; the VM run is the first real-effect check.<br>tofi: tofi (AUR) was not installable in the test environment; all tofi behavior is documentation-only until the VM run. | `real-effect` |
| `D02-wofi-commands` | `launcher/wofi` | Run action_exec.sh menu.commands; the run mode lists PATH executables; start one | - | `real-effect` |
| `D02-wofi-chooser`<br>`D02-rofi-chooser`<br>`D02-fuzzel-chooser`<br>`D02-bemenu-chooser`<br>`D02-tofi-chooser` | `launcher/wofi`<br>`launcher/rofi`<br>`launcher/fuzzel`<br>`launcher/bemenu`<br>`launcher/tofi` | For each option: with the app selected press Ctrl+Super+Space (repository picker) with two repositories of the same name: both rows are distinct and each opens its own directory in the TUI editor; Escape opens nothing | rofi: Keyboard paths were not exercisable through Xwayland in the headless probe; the VM run is the first real-effect check.<br>tofi: tofi (AUR) was not installable in the test environment; all tofi behavior is documentation-only until the VM run. | `real-effect` |
| `D02-wofi-confirm`<br>`D02-rofi-confirm`<br>`D02-fuzzel-confirm`<br>`D02-bemenu-confirm`<br>`D02-tofi-confirm` | `launcher/wofi`<br>`launcher/rofi`<br>`launcher/fuzzel`<br>`launcher/bemenu`<br>`launcher/tofi` | For each option: with the app selected run printf '' \| menu_choose.sh --prompt 'Test?' --confirm; echo $?: No is highlighted first; Enter prints nothing and exits 3; selecting Yes prints yes and exits 0 | rofi: Keyboard paths were not exercisable through Xwayland in the headless probe; the VM run is the first real-effect check.<br>tofi: tofi (AUR) was not installable in the test environment; all tofi behavior is documentation-only until the VM run. | `real-effect` |
| `D02-rofi-commands` | `launcher/rofi` | Run action_exec.sh menu.commands; rofi -show run lists PATH executables; start one | Keyboard paths were not exercisable through Xwayland in the headless probe; the VM run is the first real-effect check. | `real-effect` |
| `D02-fuzzel-commands` | `launcher/fuzzel` | Run action_exec.sh menu.commands; executables appear together with applications; start one | - | `real-effect` |
| `D02-bemenu-applications` | `launcher/bemenu` | Select Bemenu; run action_exec.sh menu.applications and confirm the notification explains that Bemenu has no desktop-application mode and nothing opens; Super+Space still opens bemenu-run | - | `real-effect` |
| `D02-bemenu-commands` | `launcher/bemenu` | Run action_exec.sh menu.commands; bemenu-run lists PATH executables; start one | - | `real-effect` |
| `D02-tofi-commands` | `launcher/tofi` | Run action_exec.sh menu.commands; tofi-run lists PATH executables; the selected one starts | tofi (AUR) was not installable in the test environment; all tofi behavior is documentation-only until the VM run. | `real-effect` |
| `D02-theme-units` | cross-role | For each launcher switch dark and light with Super+Shift+T and reopen the launcher and the repository picker: Mocha/Latte surfaces, Blue selection, Noto Sans text and a visible focus border on the search field; the Wi-Fi wofi menu file is unchanged | Rofi and tofi visuals were not captured locally (Xwayland keyboard limits, tofi not installable); wofi, fuzzel and bemenu screenshots exist in both variants. | `visual` |
| `D02-repository-picker` | cross-role | Ctrl+Super+Space: repositories under ~/GitHub and REPOS_WOFI_ROOTS appear with unique labels; a launcher error shows a notification instead of silently closing | - | `modeled-effect` |

#### D03 Notifications

Source: `tests/fixtures/harmonization/coverage/d03-notifications.json` (36 cases).

| Case | Option | Steps and expected result | Known limits | Evidence |
|---|---|---|---|---|
| `D03-swaync-dnd`<br>`D03-mako-dnd`<br>`D03-dunst-dnd` | `notifications/swaync`<br>`notifications/mako`<br>`notifications/dunst` | For each option: select the app; toggle DND from the bar or action_exec.sh notifications.dnd.toggle; send notify-send -u normal and -u critical: only the critical popup appears; status_read.sh notifications shows dnd true | - | `real-effect` |
| `D03-swaync-dismiss` | `notifications/swaync` | Send three notifications, run action_exec.sh notifications.dismiss.all: all popups disappear; the control center still lists them | - | `real-effect` |
| `D03-swaync-history` | `notifications/swaync` | Run action_exec.sh notifications.history.open: the control center opens and lists earlier notifications | - | `real-effect` |
| `D03-swaync-center` | `notifications/swaync` | Run action_exec.sh notifications.center.toggle twice: the control center opens and closes | - | `real-effect` |
| `D03-swaync-status`<br>`D03-mako-status`<br>`D03-dunst-status`<br>`D03-fnott-status` | `notifications/swaync`<br>`notifications/mako`<br>`notifications/dunst`<br>`notifications/fnott` | For each option: with the provider stopped, status_read.sh notifications reports running false and no daemon starts; with it running, counts and DND match what is on screen; no notification text appears in the JSON | - | `real-effect` |
| `D03-swaync-singleton`<br>`D03-mako-singleton`<br>`D03-dunst-singleton`<br>`D03-fnott-singleton` | `notifications/swaync`<br>`notifications/mako`<br>`notifications/dunst`<br>`notifications/fnott` | For each option: with the app selected and another notification daemon already running, log in: role_exec.sh refuses to start the app (exit 10, logged in notifications.log) and the other daemon keeps running | - | `real-effect` |
| `D03-swaync-retention` | `notifications/swaync` | Not applicable for a pass: SwayNC has no native cap or expiry; confirm the limitation text in the installer | No provider supports 24-hour expiry natively; the option stays limited. | `real-effect` |
| `D03-swaync-lock-privacy`<br>`D03-mako-lock-privacy`<br>`D03-dunst-lock-privacy`<br>`D03-fnott-lock-privacy` | `notifications/swaync`<br>`notifications/mako`<br>`notifications/dunst`<br>`notifications/fnott` | For each option: lock with hyprlock (Super+L), send notify-send -u critical from another TTY or ssh: no popup or text is visible on the lock screen; unlock and the notification is handled normally | Lock rendering cannot run headless; ext-session-lock-v1 and the absent above_lock/session_lock_xray settings are the only local evidence. | `visual` |
| `D03-swaync-transient`<br>`D03-mako-transient`<br>`D03-dunst-transient` | `notifications/swaync`<br>`notifications/mako`<br>`notifications/dunst` | For each option: send notify-send -e 'transient'; after it closes it is not in the app's history | mako: Mako stores transient notifications; its case is expected to show the documented limitation. | `real-effect` |
| `D03-mako-dismiss`<br>`D03-dunst-dismiss`<br>`D03-fnott-dismiss` | `notifications/mako`<br>`notifications/dunst`<br>`notifications/fnott` | For each option: send three notifications, run action_exec.sh notifications.dismiss.all: all popups disappear | - | `real-effect` |
| `D03-mako-history`<br>`D03-dunst-history`<br>`D03-fnott-history` | `notifications/mako`<br>`notifications/dunst`<br>`notifications/fnott` | For each option: run action_exec.sh notifications.history.open: a notification explains that the app has no browsable history | - | `real-effect` |
| `D03-mako-center`<br>`D03-dunst-center`<br>`D03-fnott-center` | `notifications/mako`<br>`notifications/dunst`<br>`notifications/fnott` | For each option: run action_exec.sh notifications.center.toggle: a notification explains that the app has no notification center | - | `real-effect` |
| `D03-mako-retention` | `notifications/mako` | Send 105 notifications and dismiss them: makoctl history -j \| jq length stays at 100; restart mako: history is empty | No provider supports 24-hour expiry natively; the option stays limited. | `real-effect` |
| `D03-dunst-retention` | `notifications/dunst` | Send 105 notifications: dunstctl count history stays at 100; restart dunst: history is empty | No provider supports 24-hour expiry natively; the option stays limited. | `real-effect` |
| `D03-fnott-dnd` | `notifications/fnott` | Select Fnott; action_exec.sh notifications.dnd.toggle shows an explanation that Fnott has no readable do-not-disturb and nothing changes | - | `real-effect` |
| `D03-fnott-retention` | `notifications/fnott` | Not applicable: Fnott keeps no history | No provider supports 24-hour expiry natively; the option stays limited. | `real-effect` |
| `D03-theme-units` | cross-role | For each provider switch dark and light with Super+Shift+T and send a normal and a critical notification: Mocha/Latte surfaces, Noto Sans, Blue normal and Red critical accents; SwayNC, mako and dunst restyle immediately, fnott after its restart | - | `visual` |

#### D04 Network, Bluetooth and audio

Source: `tests/fixtures/harmonization/coverage/d04-devices.json` (20 cases).

| Case | Option | Steps and expected result | Known limits | Evidence |
|---|---|---|---|---|
| `D04-nmtui-connect-edit` | `network/networkmanager` | Bar left click opens nmtui connect, right click nmtui edit in the selected terminal; connect to the VM network | Real Wi-Fi association needs hardware | `real-effect` |
| `D04-nmtui-theme` | `network/networkmanager` | nmtui shows Catppuccin colors in dark and light variants; focused buttons readable | - | `visual` |
| `D04-nm-applet-chooser-unsupported` | `network/network-manager-applet` | Chooser action shows an unsupported notification; tray menu still works | - | `argv` |
| `D04-nm-applet-editor` | `network/network-manager-applet` | Editor action opens nm-connection-editor | - | `argv` |
| `D04-nm-connection-editor` | `network/nm-connection-editor` | Profile editor opens; connect action reports unsupported | - | `argv` |
| `D04-plasma-nm` | `network/plasma-nm` | Applet window lists connections; Configure opens kcm_networkmanagement; reconnect prompt behavior outside Plasma | plasma-nm not installable locally | `real-effect` |
| `D04-network-radio` | `network/networkmanager` | Toggle Wi-Fi from the bar; status shows disabled/enabled | Hardware switch states need hardware | `real-effect` |
| `D04-network-status` | `network/networkmanager` | Bar shows connectivity and signal without SSID in shared status | - | `modeled-effect` |
| `D04-blueman` | `bluetooth/blueman` | Pair a device from blueman-manager (USB passthrough) | Needs Bluetooth hardware | `real-effect` |
| `D04-bluedevil` | `bluetooth/bluedevil` | Pair through the KCM wizard; device-initiated pairing without kded6 | Not installable locally; needs hardware | `real-effect` |
| `D04-bluetui` | `bluetooth/bluetui` | Scan, pair, trust and connect in bluetui | Needs hardware | `real-effect` |
| `D04-bluetuith` | `bluetooth/bluetuith` | Pair a device with confirmation; note PIN auto-answer | AUR; needs hardware | `real-effect` |
| `D04-bluetooth-radio-guard` | `bluetooth/blueman` | Super+Shift+B and bar right click toggle power; with no controller nothing powers on and the notification says unchanged | - | `modeled-effect` |
| `D04-bluetooth-status` | `bluetooth/bluetui` | Bar shows unavailable without controller, off/on/blocked otherwise | - | `modeled-effect` |
| `D04-pavucontrol` | `audio/pavucontrol` | Streams action opens Playback; move a stream to another sink | - | `real-effect` |
| `D04-pavucontrol-qt` | `audio/pavucontrol-qt` | Streams action opens Playback; per-app volume | - | `real-effect` |
| `D04-qastools-limited` | `audio/qastools` | Streams action reports unsupported; hardware opens QasMixer | - | `argv` |
| `D04-alsamixer-limited` | `audio/alsa-utils` | Streams action reports unsupported; hardware opens Alsamixer with the managed colors | - | `argv` |
| `D04-ncpamixer` | `audio/ncpamixer` | ncpamixer opens on Playback/Output Devices | AUR; not installable locally | `real-effect` |
| `D04-audio-status` | `audio/pavucontrol-qt` | Bar volume/mute match wpctl | - | `real-effect` |

#### D05 Shells, terminals, multiplexers and agents

Source: `tests/fixtures/harmonization/coverage/d05-terminal-workspace.json` (30 cases).

| Case | Option | Steps and expected result | Known limits | Evidence |
|---|---|---|---|---|
| `D05-bash-environment` | `shell/bash` | Open a Bash terminal: prompt shows the OS name in Blue, a failed command shows [status]; toggle Super+Shift+T and open a new terminal | - | `real-effect` |
| `D05-fish-environment` | `shell/fish` | Open a Fish terminal in both variants: commands Blue, errors red, completion pager readable; `echo $PATH` keeps session entries | - | `real-effect` |
| `D05-zsh-environment` | `shell/zsh` | Select Zsh, open a terminal: coloured prompt, [status] after a failing command | zsh is not in the hermetic userland; the region is render-tested, the prompt behaviour has research real-effect evidence E-D05-024 | `real-effect` |
| `D05-kitty-launch-cwd`<br>`D05-alacritty-launch-cwd`<br>`D05-foot-launch-cwd`<br>`D05-ghostty-launch-cwd`<br>`D05-konsole-launch-cwd` | `terminal/kitty`<br>`terminal/alacritty`<br>`terminal/foot`<br>`terminal/ghostty`<br>`terminal/konsole` | For each option: select the app; open the multiplexer shortcut and a TUI app; run term_exec.sh --cwd ~/Documents -- fish and check pwd | ghostty: ghostty is not available locally; launch flags and theme files are argv/render-tested only<br>konsole: konsole is not available locally; launch flags and theme files are argv/render-tested only | `argv` |
| `D05-kitty-clipboard`<br>`D05-alacritty-clipboard`<br>`D05-foot-clipboard`<br>`D05-ghostty-clipboard`<br>`D05-konsole-clipboard` | `terminal/kitty`<br>`terminal/alacritty`<br>`terminal/foot`<br>`terminal/ghostty`<br>`terminal/konsole` | For each option: in the app: select text, Ctrl+Shift+C, paste with Ctrl+Shift+V in another window | Manual VM check only (default bindings documented, E-D05-035) | `real-effect` |
| `D05-kitty-theme` | `terminal/kitty` | Toggle Super+Shift+T: kitty colours switch (live (SIGUSR1)); font family JetBrainsMono Nerd Font, font size unchanged | - | `visual` |
| `D05-alacritty-theme` | `terminal/alacritty` | Toggle Super+Shift+T: alacritty colours switch (live); font family JetBrainsMono Nerd Font, font size unchanged | - | `visual` |
| `D05-foot-theme`<br>`D05-konsole-theme` | `terminal/foot`<br>`terminal/konsole` | For each option: toggle Super+Shift+T: the app colours switch (new windows); font family JetBrainsMono Nerd Font, font size unchanged | konsole: konsole is not available locally; launch flags and theme files are argv/render-tested only | `visual` |
| `D05-ghostty-theme` | `terminal/ghostty` | Toggle Super+Shift+T: ghostty colours switch (documented SIGUSR2 reload); font family JetBrainsMono Nerd Font, font size unchanged | ghostty is not available locally; launch flags and theme files are argv/render-tested only | `visual` |
| `D05-tmux-session`<br>`D05-zellij-session` | `multiplexer/tmux`<br>`multiplexer/zellij` | For each option: open the app with the shortcut, create a session, split a pane in another directory, detach, reattach explicitly | - | `real-effect` |
| `D05-tmux-theme`<br>`D05-zellij-theme` | `multiplexer/tmux`<br>`multiplexer/zellij` | For each option: toggle the theme with the app open: status/borders follow the variant (live) | - | `visual` |
| `D05-herdr-bin-session` | `multiplexer/herdr-bin` | Open Herdr with the shortcut, create a session, split a pane in another directory, detach, reattach explicitly | Herdr is not installable locally; documentation evidence only (E-D05-020) | `real-effect` |
| `D05-herdr-bin-theme` | `multiplexer/herdr-bin` | Toggle the theme with Herdr open: status/borders follow the variant (after restart) | Herdr is not installable locally; documentation evidence only (E-D05-020) | `visual` |
| `D05-pi-launch`<br>`D05-opencode-launch`<br>`D05-claude-code-launch`<br>`D05-codex-cli-launch`<br>`D05-cursor-cli-launch` | `agent/pi`<br>`agent/opencode`<br>`agent/claude-code`<br>`agent/codex-cli`<br>`agent/cursor-cli` | For each option: with the app selected and signed in by you: trigger a startup warning, click the notification action, confirm the agent opens read-only in the selected terminal/multiplexer | Requires your own agent account; tests are modeled (no authenticated agent run) | `real-effect` |
| `D05-agent-none` | `agent/none` | Select None: no agent notification action, no agent units, existing CLIs untouched | - | `modeled-effect` |

#### D06 Browsers, file managers, editors and calendars

Source: `tests/fixtures/harmonization/coverage/d06-applications.json` (42 cases).

| Case | Option | Steps and expected result | Known limits | Evidence |
|---|---|---|---|---|
| `D06-firefox-handlers`<br>`D06-chromium-handlers`<br>`D06-vivaldi-handlers`<br>`D06-zen-browser-bin-handlers`<br>`D06-brave-bin-handlers` | `browser/firefox`<br>`browser/chromium`<br>`browser/vivaldi`<br>`browser/zen-browser-bin`<br>`browser/brave-bin` | For each option: select the app as primary, run setup, then `xdg-open https://example.org` and open an .html file from the file manager | Desktop IDs from package file lists; effective dispatch in a session is a VM check | `real-effect` |
| `D06-dolphin-folder-handler`<br>`D06-thunar-folder-handler`<br>`D06-nautilus-folder-handler`<br>`D06-nemo-folder-handler`<br>`D06-pcmanfm-qt-folder-handler` | `file_manager/dolphin`<br>`file_manager/thunar`<br>`file_manager/nautilus`<br>`file_manager/nemo`<br>`file_manager/pcmanfm-qt` | For each option: select the app: `xdg-open ~/Documents` opens it; the GTK file chooser still opens from a browser download dialog | - | `real-effect` |
| `D06-dolphin-workflows`<br>`D06-thunar-workflows`<br>`D06-nautilus-workflows`<br>`D06-nemo-workflows`<br>`D06-pcmanfm-qt-workflows` | `file_manager/dolphin`<br>`file_manager/thunar`<br>`file_manager/nautilus`<br>`file_manager/nemo`<br>`file_manager/pcmanfm-qt` | For each option: in the app: open a text file in the editor, browse a mounted USB image or second disk, delete and restore a file from trash, extract a .zip | Manual VM check; gvfs and the Thunar/Nemo archive plugins are installed with their file managers | `real-effect` |
| `D06-yazi-browse`<br>`D06-ranger-browse`<br>`D06-lf-browse`<br>`D06-nnn-browse`<br>`D06-mc-browse`<br>`D06-vifm-browse` | `tui_file_manager/yazi`<br>`tui_file_manager/ranger`<br>`tui_file_manager/lf`<br>`tui_file_manager/nnn`<br>`tui_file_manager/mc`<br>`tui_file_manager/vifm` | For each option: open the app with role_exec.sh tui_file_manager: browse, open a text file in $EDITOR, toggle the theme and relaunch | - | `argv` |
| `D06-tui-file-manager-none` | `tui_file_manager/none` | Select None: role_exec.sh tui_file_manager reports unavailable; Super+E still opens the graphical file manager | - | `argv` |
| `D06-neovim-edit-theme`<br>`D06-vim-edit-theme`<br>`D06-nano-edit-theme` | `tui_editor/neovim`<br>`tui_editor/vim`<br>`tui_editor/nano` | For each option: open a file with the app, edit and save; toggle the theme and reopen (next launch) | - | `real-effect` |
| `D06-helix-edit-theme` | `tui_editor/helix` | Open a file with helix, edit and save; toggle the theme and reopen (live with SIGUSR1) | - | `real-effect` |
| `D06-zed-text-handler`<br>`D06-visual-studio-code-bin-text-handler`<br>`D06-cursor-bin-text-handler`<br>`D06-kate-text-handler`<br>`D06-mousepad-text-handler` | `gui_editor/zed`<br>`gui_editor/visual-studio-code-bin`<br>`gui_editor/cursor-bin`<br>`gui_editor/kate`<br>`gui_editor/mousepad` | For each option: select the app: double-click a .txt and a .sh file in the file manager; both open in the app | visual-studio-code-bin: VS Code's code.desktop does not declare text/plain; verify it is honoured | `real-effect` |
| `D06-gui-editor-none` | `gui_editor/none` | Select GUI editor None: double-click a .txt file; the primary TUI editor opens in the selected terminal; no GUI editor autostarts | - | `modeled-effect` |
| `D06-merkuro-open`<br>`D06-gnome-calendar-open`<br>`D06-korganizer-open`<br>`D06-calcurse-open`<br>`D06-khal-open` | `calendar/merkuro`<br>`calendar/gnome-calendar`<br>`calendar/korganizer`<br>`calendar/calcurse`<br>`calendar/khal` | For each option: click the bar clock / calendar shortcut: the app opens (GUI calendars float and focus at 70%) | - | `argv` |
| `D06-merkuro-local-events`<br>`D06-gnome-calendar-local-events`<br>`D06-korganizer-local-events`<br>`D06-calcurse-local-events`<br>`D06-khal-local-events` | `calendar/merkuro`<br>`calendar/gnome-calendar`<br>`calendar/korganizer`<br>`calendar/calcurse`<br>`calendar/khal` | For each option: fresh profile, no accounts: create, view and edit a local event in the app | merkuro: Manual VM check (Akonadi/EDS first run)<br>gnome-calendar: Manual VM check (Akonadi/EDS first run)<br>korganizer: Manual VM check (Akonadi/EDS first run)<br>khal: Needs `khal configure` once (limited) | `real-effect` |

#### D07 Session, power and auxiliary tools

Source: `tests/fixtures/harmonization/coverage/d07-session-auxiliary.json` (18 cases).

| Case | Option | Steps and expected result | Known limits | Evidence |
|---|---|---|---|---|
| `D07-lock` | `generic/hyprlock` | Super+L and the power screen lock immediately; unlocking needs the password; no notification content is visible while locked | - | `real-effect` |
| `D07-confirmations` | `generic/wlogout` | Reboot/shutdown/logout from keys, bar menu and power screen ask No/Yes; No does nothing | - | `modeled-effect` |
| `D07-logout-current-session` | `generic/hyprland` | Logout returns to SDDM; a second TTY session stays logged in | - | `real-effect` |
| `D07-suspend` | `generic/hypridle` | Suspend locks first and resumes with the display on | Physical suspend unverified | `real-effect` |
| `D07-hibernate` | `generic/wlogout` | Without swap/resume the hibernate button is hidden and the action reports unsupported | Hibernate success not certified | `modeled-effect` |
| `D07-auth-agent` | `generic/hyprpolkitagent` | One polkit prompt from hyprpolkitagent (pkexec true); with polkit-kde-agent started first, the conflict is reported and nothing is killed | - | `real-effect` |
| `D07-power-screen` | `generic/wlogout` | Power screen shows Breeze icons, readable focus ring and theme colors in both variants | - | `visual` |
| `D07-compositor-theme` | `generic/hyprland` | Super+Shift+T switches border/group colors; windows stay opaque | - | `visual` |
| `D07-lock-theme` | `generic/hyprlock` | Lock screen input, checking, failure and caps-lock states readable in both variants | - | `visual` |
| `D07-greeter` | `generic/sddm` | Greeter unchanged (Eucalyptus Drop); recorded as unsupported | Privileged greeter theming blocked by design | `documentation` |
| `D07-btop-cava` | `generic/btop` | btop and cava show Catppuccin colors after theme switch | - | `real-effect` |
| `D07-keybind-viewer` | `generic/tk` | Keybind viewer follows the variant; focus visible on search and buttons | - | `visual` |
| `D07-wallpaper` | `generic/hyprpaper` | Super+W changes the wallpaper on every output | - | `real-effect` |
| `D07-nightlight` | `generic/hyprsunset` | Super+Ctrl+S behavior noted; not changed | No native toggle; script left unchanged | `documentation` |
| `D07-capture` | `generic/hyprshot` | Window/output/region capture opens Satty; Escape saves nothing | Existing behavior preserved; no automated test | `real-effect` |
| `D07-clipboard` | `generic/wl-clipboard-history-git` | Clipboard history opens floating in the selected terminal | - | `argv` |
| `D07-notes` | `generic/python` | Notes create and list inside the notes folder | - | `modeled-effect` |
| `D07-music` | `generic/ffmpeg` | Super+Ctrl+M plays the album when ffmpeg is installed | Network stream; not automated | `real-effect` |

Note on the generated rows: `gvfs` and `thunar-archive-plugin` install with Thunar, `nemo-fileroller` with Nemo, and `gvfs` with PCManFM-Qt. Run the `D06-*-workflows` rows with these extras installed.

### 4.3 Generic tools and global surfaces

The ledger also classifies 119 generic catalog packages. Those with a visible interface (for example qt5ct/qt6ct, nwg-look, btop, Timeshift, Satty, Qalculate, Waypaper and the keybind viewer) should follow the variant after a switch and a relaunch. Record any that do not as a `visual` issue against `D07-keybind-viewer` or `F04-theme-visual-review`, naming the package. The SDDM greeter is not themed by design (`D07-greeter`).

## 5. Independent partial application and recovery

These checks prove that one failing or conflicting application does not block the rest.

| # | Steps | Expected result | Case |
|---|---|---|---|
| P-1 | Edit inside a theme region, for example the `hss-theme` region in `~/.config/kitty/kitty.conf`, then switch the theme. | Kitty is `skipped-conflict` and your edit stays. Every other unit switches. A notification says "Theme partially applied", and `status_read.sh theme` shows `"batch":"partial"`. | `F04-managed-configuration` |
| P-2 | Restore the edit, or delete the region and rerun setup with Apply, then switch again. | All units apply and the batch is `complete`. | `F04-managed-configuration` |
| P-3 | Uninstall one themed member, for example `sudo pacman -R foot` when it is not primary, then switch. | The batch is not blocked: the other units apply, and nothing is launched or installed. Activation for the missing app is skipped because it is not running. | `F04-theme-activation` |
| P-4 | Recreate the conflict from P-1, change only the primary browser and run setup with Apply. | Routing and associations switch to the new primary (`xdg-open https://example.org`). The appearance conflict is reported separately. | `D06-<browser>-handlers` |
| P-5 | Switch an optional role to None and back: dock, TUI file manager, GUI editor and agent (rounds 1, 5 and 6). | None behaves as the ledger describes: no dock process, `role_exec.sh tui_file_manager` reports unavailable, text files open in the TUI editor through `hss-tui-editor.desktop`, and the agent action disappears. Previously installed apps stay installed. Selecting the option again restores its behavior and theme unit. | `D01-dock-none`, `D06-tui-file-manager-none`, `D06-gui-editor-none`, `D05-agent-none` |
| P-6 | Interrupt a setup run during the harmonization step (Ctrl+C in the shell installer), then run `./setup.sh --list-runs` and rerun setup. | The interrupted run is listed. The rerun completes and reports a consistent state. Files from the interrupted run can be rolled back with `--rollback`. | `F04-managed-configuration` |
| P-7 | Start `polkit-kde-agent` manually, then log in again with the default session. | Hyprpolkitagent reports a conflict, and nothing is killed. One agent answers `pkexec true`. | `D07-auth-agent` |
| P-8 | Start a second notification daemon before login (for example `mako` while SwayNC is selected). | The selected daemon is refused with a conflict logged in `notifications.log`, and the foreign owner keeps running. | `D03-<provider>-singleton` |

Recovery never restarts applications, takes over a foreign owner, runs `chsh` or restarts the greeter. Rollback cannot undo runtime effects such as a notification that was shown, an update that ran or a device that was paired.

## 6. Next launch, relogin and environments

- **Live reload** where the app supports it safely: Hyprland, Kitty (SIGUSR1), Waybar, SwayNC, Mako, Dunst, tmux and Zellij. Helix reloads with SIGUSR1.
- **Next launch:** Foot and Konsole (new windows), fnott, nwg-panel, nwg-dock-hyprland, Herdr (restart or reattach), GUI apps and TUI editors.
- **Relogin:** the Xcursor theme for non-Hyprland toolkits, and gsettings values when `gsettings` was unavailable during the switch.
- **Supported test environment:** current Arch Linux packages in a disposable VM. Automated suites ran in an isolated Arch userland without a graphical session. Other Arch-based distributions and physical hardware are unverified.

## 7. Recording evidence

Record one JSON object per case and run, shaped like [`evidence-template.json`](../tests/fixtures/harmonization/evidence-template.json). Keep the records and captures outside the repository, for example in `~/hss-vm-evidence/<case>.json`, until you transfer the results.

| Field | Content |
|---|---|
| `kind` | The level you observed: `real-effect` (actual app, state observed independently), `visual` (manual review using the visual protocol), or `static` for configuration inspection. Never record `real-effect` for something you only read about. |
| `case` | Coverage case ID from the tables, for example `D03-swaync-dnd` |
| `date` | `YYYY-MM-DD` |
| `environment` | Hypervisor, Arch snapshot date, Hyprland version, number and scale of outputs, locale |
| `versions` | `provider` (`pacman -Q <pkg>`), `hyprland` (`hyprctl version`), `repository_commit` (section 1, step 4) |
| `selection` | `primary`, every selected `members` entry and the `variant` (`status_read.sh theme`) |
| `command` | Exact command or numbered manual steps |
| `oracle` | How you observed the effect independently of the adapter's own report, for example `wpctl get-volume`, `busctl --user status org.freedesktop.Notifications`, `xdg-mime query default`, `hyprctl clients` or a screenshot |
| `result` | One or two sentences describing what happened |
| `artifacts` | Screenshot or log paths, each with `kind` and `privacy_reviewed: true` after the [privacy review](../tests/fixtures/harmonization/visual-protocol.md#5-privacy-review-before-sharing) |
| `limits` | Hardware, version or environment limits; required for any result other than `passed` |
| `reviewer` | Your name or handle |

Result labels for each case:

| Result | Use when |
|---|---|
| `passed` | The expected result was observed, with evidence at or above the case's required level. `argv` evidence never satisfies a `real-effect` case. |
| `failed` | The check ran and the observed result differs. Put the difference in `limits`. |
| `blocked` | The check could not run, for example because hardware is missing, the package is unavailable or an account is required. Give the reason. |
| `skipped` | You chose not to run it. Give the reason. |

To report back, transfer each result into the case's `result` field in `tests/fixtures/harmonization/coverage/*.json`, adding `evidence` for passed cases and a reason in `limits` for the others. Then run `bash tests/run.sh tests/shell/harmonization_coverage.sh`. Visual reviews additionally use the capture metadata template from the visual protocol. A failed check is a finding against the branch, not a reason to change a support label without new evidence.
