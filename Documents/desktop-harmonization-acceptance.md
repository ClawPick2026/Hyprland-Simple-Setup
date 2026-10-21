# Desktop harmonization: acceptance matrix

**Status: Implemented on branch; VM acceptance pending (user-led).**

This is the I01.5 cross-role acceptance matrix for the desktop harmonization plans (F01-F04, D01-D07, I01 under `plans/planned/desktop-harmonization/`). It maps each acceptance slice to the automated suites that cover it and the manual checks still open, and it summarizes the capability ledger's current support labels. It does not record any pass. Automated suites prove contracts against test doubles and isolated userlands. Graphical, live-session and hardware behavior is proven only by the user-led steps in [VM testing](desktop-harmonization-vm-testing.md).

## 1. Candidate identity

| Item | Value |
|---|---|
| Branch | `feat/harmonize-visual-design`, based on `d940475` (after `v0.7.0`) |
| Change set | Uncommitted: 61 tracked files changed (+2629/−983), plus new runtime scripts, providers, theme engine, ledger, coverage fragments and test suites |
| Capability ledger | `capabilities.json` (schema 1) plus `capabilities.d/d01`-`d07` |
| Runtime contract | [Runtime actions, status and managed configuration](runtime-managed-configuration.md) |
| Theme | `dotfiles/.config/hypr/theme/` (tokens schema 1, units registry, `hss_theme.py`) |
| Coverage | `tests/fixtures/harmonization/coverage/*.json` (schema 1), validated by `tests/shell/harmonization_coverage.sh` |
| Evidence shape | `tests/fixtures/harmonization/evidence-template.json` and `visual-protocol.md` |

Record the exact commit in every evidence record once the branch is committed.

## 2. Cross-role slices

The slices come from I01 section 8. Coverage is exhaustive per option and None state, with declared interaction samples (for example the nine bar/dock combinations and the six selection rounds in the VM checklist). It is not Cartesian across roles.

| Slice | Required evidence | Automated suites (`tests/shell/` unless noted) | Open manual evidence |
|---|---|---|---|
| Entire catalog | Every option, the four None states, primary/non-primary and all-member fixtures, inbound/outbound switching, unchanged defaults | `cargo test` (chooser and selection export), `tests/check_packages_json.sh`, `capability_contracts.sh`, `harmonization_coverage.sh`, `roles_matrix.sh`, `roles_membership.sh`, `roles_validation.sh`, `roles_package_normalization.sh`, `roles_review_regressions.sh`, `roles_interactive.sh` | Selection rounds 1-6 and None transitions (VM sections 4.1 and 5) |
| Panels/providers | All nine bar/dock combinations; every active Waybar operation; each notification and device provider with frontend wiring and ownership | `bars_parity.sh`, `docks_behavior.sh`, `panel_themes.sh`, `notifications_contracts.sh`, `notifications_lifecycle.sh`, `notifications_rendering.sh`, `device_controls.sh`, `device_themes.sh`, `runtime_ownership.sh`, `roles_dbus_atomic.sh`, `roles_controls.sh`, `waybar_keybinds.sh`, `waybar_updates.sh`, `waybar_review_regressions.sh` | D01, D03 and D04 rows (VM section 4.2) |
| Launchers/terminals/apps | All five launchers and terminals; desktop-entry, cwd and argv effects; D06 file, editor and calendar workflows and None fallback | `launcher_desktop_entries.sh`, `launcher_menus.sh`, `launcher_themes.sh`, `terminal_workspace.sh`, `application_handlers.sh`, `application_renderers.sh`, `application_workflows.sh`, `calendar_workflows.sh`, `file_manager.sh`, `tui_file_manager.sh`, `roles_lua_argv.sh` | D02, D05 terminal and D06 rows |
| Shells/multiplexers/agents | Preserved locale and environment, session targeting, click-only at-most-once triage, offline synthetic agents | `terminal_shell_environment.sh`, `shell_language.sh`, `multiplexer_runtime.sh`, `agent_triage.sh`, `agent_installers.sh`, `agent_legacy_config.sh`, `startup_triage.sh`, `roles_startup.sh` | D05 shell, multiplexer and agent rows; agent launch needs your own account |
| Theme/toolkits | Every selected-member mapping; GTK/Qt/KDE, native-constrained, custom and TUI surfaces; assets, actual adoption and global-setting reach | `theme_rendering.sh`, `theme_activation.sh`, `theme_foundation_regressions.sh`, `managed_configuration.sh`, `harmonization_setup.sh`, `python3 dotfiles/.config/hypr/theme/hss_theme.py check` | Theme switching and visual review (VM sections 3 and 4.3) |
| Session/auxiliary | Lock and authentication ownership, power policy, wallpaper, capture, clipboard, custom dialogs, generic-package dispositions | `session_auxiliary.sh`, `session_auxiliary_rendering.sh`, `capability_contracts.sh` (generic dispositions) | D07 rows |
| Reliability | Stow and custom roots, user edits, failed staging/commit/activation, concurrent attempts, interruption, guarded partial recovery | `reliability_atomic.sh`, `reliability_failures.sh`, `reliability_latest_log.sh`, `reliability_lifecycle.sh`, `reliability_rollback.sh`, `reliability_two_runs.sh`, `managed_configuration.sh`, `theme_foundation_regressions.sh`, `harmonization_setup.sh`, `harmonization_installer.sh`, `harmonization_transitions.sh`, `runtime_contracts.sh`, `harness_regressions.sh` | VM sections 2.4 and 5 |
| Readability/hardware | Readable focus and dark/light appearance in the VM; existing accessibility preferences preserved; physical device, mixed-DPI and power evidence marked unverified | None (manual by policy P07) | `visual-protocol.md` review; hardware rows stay `blocked`/unverified |

The I01 integration suites are delivered: `harmonization_installer.sh` (managed-file sync, session migrations, default handlers and rollback, consent modes, stock Waybar upgrade, identical rerun, failed validation, no package installation) and `harmonization_transitions.sh` (fresh adoption, identical rerun, primary/member and option↔None switches, dark↔light round trip, user divergence, injected write failure with `setup.sh --rollback`, foreign notification owner). Fresh/rerun/switch/upgrade transitions in a real session remain VM sections 2 and 5.

## 3. Coverage cases per domain

All 260 cases currently have result `not-run`. Required evidence levels:

| Owner | Fragment | Cases | real-effect | visual | modeled-effect | argv | static | documentation | With VM step |
|---|---|---|---|---|---|---|---|---|---|
| F04 | `f-foundation.json` | 9 | 0 | 1 | 6 | 0 | 2 | 0 | 5 |
| D01 | `d01-panels.json` | 83 | 77 | 5 | 1 | 0 | 0 | 0 | 83 |
| D02 | `d02-launchers.json` | 22 | 20 | 1 | 1 | 0 | 0 | 0 | 22 |
| D03 | `d03-notifications.json` | 36 | 31 | 5 | 0 | 0 | 0 | 0 | 36 |
| D04 | `d04-devices.json` | 20 | 11 | 1 | 3 | 5 | 0 | 0 | 20 |
| D05 | `d05-terminal-workspace.json` | 30 | 16 | 8 | 1 | 5 | 0 | 0 | 30 |
| D06 | `d06-applications.json` | 42 | 29 | 0 | 1 | 12 | 0 | 0 | 42 |
| D07 | `d07-session-auxiliary.json` | 18 | 8 | 4 | 3 | 1 | 0 | 2 | 18 |
| **Total** | | **260** | **192** | **25** | **16** | **23** | **2** | **2** | **256** |

`real-effect` and `visual` cases can pass only with VM evidence. `argv`, `modeled-effect` and `static` cases are covered by the delivered suites listed in each case, and their VM steps are supplementary.

## 4. Support labels from the ledger

73 options across 17 roles. These labels are what the installer shows. The [VM checklist](desktop-harmonization-vm-testing.md) can confirm or contradict them but does not change them by itself.

| Role | full | limited | unverified |
|---|---|---|---|
| Browser | 0 | 4 | 1 |
| Shell | 3 | 0 | 0 |
| Terminal | 3 | 0 | 2 |
| Multiplexer | 2 | 0 | 1 |
| File manager | 0 | 0 | 5 |
| TUI file manager | 0 | 5 | 1 |
| Notifications | 0 | 4 | 0 |
| TUI editor | 3 | 1 | 0 |
| GUI editor | 0 | 0 | 5 |
| Bar | 1 | 2 | 0 |
| Dock | 0 | 2 | 0 |
| Calendar | 1 | 1 | 3 |
| Bluetooth | 1 | 1 | 2 |
| Network | 1 | 2 | 1 |
| Audio | 2 | 2 | 1 |
| Launcher | 3 | 1 | 1 |
| Coding agents | 0 | 0 | 5 |
| **Total** | **20** | **25** | **28** |

Option theme surfaces: 44 `supported`, 23 `partial`, 6 `unverified`. Capability claims across all options: 233 supported, 14 partial, 29 unsupported, 40 unverified, 2 not applicable. The None states for dock, TUI file manager, GUI editor and agent have defined behavior and no theme units. The ledger also classifies 119 generic catalog packages: 30 themed interfaces, 12 integrated actions, 50 backend dependencies and 27 outside visual scope.

Per-option labels and their main limitation are listed in [Application selections](app-selections.md#harmonization-support).

## 5. Documented limitations

Cross-cutting limitations. Per-option ones are in the ledger and in [Application selections](app-selections.md#harmonization-support).

- No notification daemon supports a 24-hour history expiry natively, so all four providers are `limited`. Fnott has no readable do-not-disturb, and Mako and Dunst have no browsable history or center. These actions report `unsupported` and never substitute another app.
- Browsers follow only the system dark/light preference, not the Catppuccin palette.
- Native widget shapes differ between GTK, Qt/KDE, libadwaita, Electron and custom renderers. Only colors, fonts, icons and cursor are harmonized.
- Several apps apply a theme change only at next launch (for example fnott, nwg-panel, nwg-dock-hyprland, Foot and Konsole windows, and Herdr after restart). The Xcursor change applies after relogin.
- The SDDM greeter is not themed (privileged; unsupported by design). Night light has no native toggle and is unchanged.
- Runtime switching works only after setup adopted the theme with consent. Before that, it reports `unavailable` and changes nothing.
- Rollback restores files and recorded handler entries only. It cannot undo runtime effects, package installation or vendor installers.
- Partial application is expected when you edit managed keys or regions: the edited app is skipped and reported, and the rest switches.

## 6. Repository checks

Run from the repository root. They install nothing and need no graphical session.

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
bash tests/check_packages_json.sh
bash tests/run.sh
python3 dotfiles/.config/hypr/theme/hss_theme.py check
```

Focused runs, for example `bash tests/run.sh tests/shell/harmonization_coverage.sh tests/shell/capability_contracts.sh`, take explicit suite paths. `bash tests/verify_hypr_config.sh` exits 3 with `SKIPPED` when Hyprland is not installed. That is a skip, not graphical acceptance; run it inside the VM for a real `--verify-config` result. CI (`.github/workflows/ci.yml`) runs syntax checks, ShellCheck, `hss_theme.py check` and `tests/run.sh` on Ubuntu, which is not target-desktop proof.

## 7. What remains unverified

- **Every VM check.** No case has a `passed` result. All `real-effect` and `visual` cases in section 3 are open.
- **Options never run locally** (ledger `unverified`): tofi, Ghostty, Konsole, Herdr, plasma-nm, bluedevil, bluetuith, ncpamixer, all five GUI editors, all five graphical file managers' trash/mount/archive workflows, Yazi trash/archives, Merkuro, GNOME Calendar, KOrganizer, Vivaldi's MIME handling and all real coding-agent sessions.
- **Visual appearance** of every surface in both variants. Rofi and tofi visuals were never captured, and the lock screen never rendered headless.
- **Live reload effects**, D-Bus ownership in a real session, logout targeting and the polkit agent conflict path.
- **Physical hardware:** Wi-Fi association, Bluetooth pairing, audio devices, battery, backlight, suspend/hibernate and mixed-DPI or hotplugged outputs. A VM cannot certify these; they stay unverified with a visible unavailable state in the bar.
- **Other Arch-based distributions.**

## 8. Acceptance criteria

The branch is accepted when:

1. The repository checks in section 6 pass on the final commit.
2. Every option and None state has its VM cases recorded as `passed`, `failed`, `blocked` or `skipped`, with evidence or a reason, and `harmonization_coverage.sh` validates the updated fragments.
3. Every `full` label has passing evidence at its required level, and every `limited` option shows its documented unsupported outcome in the VM instead of a substitute.
4. A signed visual review covers the theme-core scenes in dark and light.
5. Hardware-dependent checks are labeled unverified with a reason. No option is claimed as full parity without evidence.

Release and publication are separate decisions and are not part of this acceptance.
