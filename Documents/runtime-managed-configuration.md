# Runtime actions, status and managed configuration

This document freezes the shared contracts used by the desktop harmonization work (plan IDs F01-F04, D01-D07 and I01 under `plans/planned/`). Domain code may add actions inside its own namespace; changes to the shared shapes below need a contract amendment that names the producer, consumers, migration and tests.

Nothing here replaces the existing entry points. `role_exec.sh`, `term_exec.sh`, `menu_exec.sh`, `notification_control.sh`, the Waybar helpers and the schema-2 `roles.json` keep their current arguments, output and exit behavior.

## 1. Installed layout

| Path below `~/.config/hypr/` | Kind | Purpose |
|---|---|---|
| `scripts/action_exec.sh` | executable | Semantic action dispatcher |
| `scripts/status_read.sh` | executable | Typed status observations |
| `scripts/lib/hss_runtime.sh` | source-only | Roles access, outcomes, envelopes, bounded commands |
| `scripts/lib/hss_reliability.sh` | source-only | Lock, run records, atomic writes, manifests and rollback (shared with `setup.sh`) |
| `scripts/providers/<domain>.sh` | source-only | Provider semantics for one domain |
| `scripts/window_present.sh`, `scripts/window_place.sh` | executable | Generic focus/launch/float helpers extracted from Waybar |
| `theme/` | data + renderer | Tokens, unit registry, templates and `hss_theme.py` |

`scripts/lib/setup-reliability.sh` in the repository is a compatibility shim that sources the installed-layout library, so setup and desktop-side theme switching use one transaction engine.

Generated output lives in `${XDG_CONFIG_HOME:-~/.config}/hss-theme/`. That directory is never shipped in `dotfiles/`, so Stow cannot fold it into the dotfiles source tree.

## 2. Outcomes and exit status

Every new machine-facing operation reports exactly one outcome.

| Outcome | Exit | Meaning |
|---|---|---|
| `completed` | 0 | The requested state change was made and independently read back |
| `accepted` | 0 | A launch or request was accepted; its effect was not independently observed |
| `failed` | 1 | The provider or a required command failed |
| `usage` | 2 | Invalid action, arguments or request |
| `cancelled` | 3 | The user dismissed a chooser, confirmation or prompt; no action was taken |
| `disabled` | 4 | The role is set to None |
| `unsupported` | 5 | The selected application has no native capability for the operation |
| `missing-dependency` | 6 | A required executable or asset is not installed |
| `unavailable` | 7 | Hardware, session, service or display is absent |
| `timeout` | 8 | A bounded wait expired; the result is unknown and is never retried automatically |
| `denied` | 9 | Authorization was refused |
| `conflict` | 10 | A foreign owner or user-owned configuration prevents the operation |

`accepted` is not success evidence for an effect. Cancellation never triggers a fallback action. An unsupported operation never substitutes another application or operation.

## 3. Actions

```text
action_exec.sh [--json] [--quiet] ACTION_ID [--] [ARG...]
```

- `ACTION_ID` is `<domain>.<operation>[.<detail>]`, lowercase, `[a-z0-9_.]`. The dispatcher sources `providers/<domain>.sh` and calls `hss_action_<ACTION_ID with dots replaced by underscores>`.
- Arguments after the action are passed as separate argv elements. No provider may use `eval`, `sh -c` with interpolated data, or reconstructed shell strings.
- `--json` prints one result envelope on stdout. Without `--json`, stdout stays empty and a short explanation is shown with `notify-send` for `unsupported`, `missing-dependency`, `unavailable`, `conflict`, `denied`, `timeout` and `failed` unless `--quiet` is given. Notification bodies never contain secrets, notification content or device identifiers.
- Unknown actions exit 2.

Result envelope:

```json
{"schema":1,"action":"notifications.dnd.set","provider":"fnott","outcome":"unsupported","reason":"Fnott has no native do-not-disturb control","exit_status":5}
```

Optional keys: `observed` (typed state read back after the action) and `pending` (deferred work such as a restart).

### Frozen action namespaces

| Domain | Owner | Actions |
|---|---|---|
| `theme` | F03 | `theme.toggle`, `theme.set <dark\|light>`, `theme.apply` |
| `notifications` | D03 | `notifications.primary`, `notifications.center.toggle`, `notifications.history.open`, `notifications.dismiss.all`, `notifications.dnd.set <on\|off>`, `notifications.dnd.toggle` |
| `network` | D04 | `network.open`, `network.connect.choose`, `network.profile.edit`, `network.radio.set <on\|off>`, `network.radio.toggle` |
| `bluetooth` | D04 | `bluetooth.open`, `bluetooth.radio.set <on\|off>`, `bluetooth.radio.toggle` |
| `audio` | D04 | `audio.open`, `audio.streams.open`, `audio.hardware.open` |
| `session` | D07 | `session.lock`, `session.logout`, `session.reboot`, `session.shutdown`, `session.suspend`, `session.hibernate`, `session.power_screen`, `session.auth.start` |
| `menu` | D02 | `menu.applications`, `menu.commands` |

Domain owners may add operations within their namespace and must record them in the capability ledger.

### Power confirmations

`session.logout`, `session.reboot` and `session.shutdown` require a confirmation through the shared chooser unless the caller passes `--confirmed` after an earlier explicit confirmation. Lock is immediate and suspend is direct. Hibernate is offered only when its prerequisites are verified. Logout targets only the current session and fails safely when that session cannot be identified.

## 4. Shared chooser

```text
menu_choose.sh --prompt TEXT [--confirm] < RECORDS
```

Records are newline-separated `ID<TAB>LABEL`. IDs match `[A-Za-z0-9._:-]+` and are unique; labels are display text only. Tabs, newlines and control characters in labels are replaced before display. The selected record's ID is printed on stdout.

Exit status: 0 selected, 3 cancelled (closed, Escape or empty selection), 1 provider failure, 2 invalid request. A returned line that is not exactly one offered label is a failure, never a fuzzy match. `--confirm` offers `No` first and `Yes` second; only `Yes` returns 0. Legacy `menu_exec.sh --dmenu` stays byte-for-byte compatible.

## 5. Status

```text
status_read.sh DOMAIN
```

The script prints one JSON object and exits 0 whenever it can describe the state, including unavailable or failed observations; it exits 2 only for usage errors.

```json
{"schema":1,"domain":"notifications","provider":"swaync","availability":"available","observed_at":"2026-10-20T10:00:00Z","state":{"running":true,"dnd":false,"count":2,"center_visible":null,"inhibited":false},"capabilities":{"dnd":"supported","history":"supported"},"error":null}
```

- `availability`: `available`, `disabled`, `missing-dependency`, `unavailable`, `unsupported` or `error`.
- Unknown values are `null`, never invented defaults such as zero or `false`.
- Shared status contains no icons, markup, tooltip prose, notification content, SSIDs, addresses or device aliases.
- Status queries are bounded (`hss_run_bounded`) and must not mutate state, start daemons, trigger scans, replay history or show notifications.

Frontends (D01) translate this JSON into Waybar, Ironbar or nwg-panel presentation.

### Frozen `state` fields per domain

Every field may be `null` when it cannot be observed. Providers may add fields; frontends must tolerate unknown fields.

| Domain | Fields |
|---|---|
| `notifications` | `running` (bool), `dnd` (bool), `count` (int, notifications the provider reports as waiting), `history_count` (int), `center_visible` (bool), `inhibited` (bool) |
| `network` | `backend` (`"networkmanager"`), `running` (bool), `connectivity` (`full`, `limited`, `portal`, `none`, `unknown`), `primary_type` (`wifi`, `ethernet`, `other`, `none`), `primary_state` (`connected`, `connecting`, `disconnected`, `unavailable`), `wifi_radio` (`enabled`, `disabled`, `unavailable`), `signal` (int 0-100) |
| `bluetooth` | `controller` (`present`, `absent`), `powered` (bool), `blocked` (bool), `connected_devices` (int) |
| `audio` | `server` (`pipewire`, `pulseaudio`), `output_volume` (int percent), `output_muted` (bool), `input_volume` (int percent), `input_muted` (bool), `streams_supported` (bool, whether the selected app natively controls per-application streams) |
| `session` | `hibernate_available` (bool), `auth_agent` (`hyprpolkitagent`, `foreign`, `none`) |
| `theme` | `variant` (`dark`, `light`), `batch` (`complete`, `partial`), `partial_units` (list of unit IDs) |

`capabilities` maps operation names (for example `dnd`, `history`, `connect`, `edit`, `radio`, `streams`, `hardware`) to `supported`, `unsupported` or `unverified` for the selected provider.

## 6. Singleton ownership

- Notifications: one `org.freedesktop.Notifications` owner per user bus. `role_exec.sh notifications` checks the bus name first. If the selected provider already owns it, nothing starts. If another process owns it, the start is refused as `conflict` and logged; the foreign owner is never terminated.
- Authentication: Hyprpolkitagent is the managed owner and starts through `action_exec.sh session.auth.start`. A running foreign polkit agent is reported as `conflict`, not terminated. The setup-owned KDE agent autostart request is removed.
- Panels: one combined `nwg-panel -c hss-panels` process owns a shared bar and dock; a dock launch is a no-op while the bar owns the process.

## 7. Managed configuration

### Ownership classes

| Class | Meaning | Replacement rule |
|---|---|---|
| `generated` | Whole file produced by the renderer under `hss-theme/` or a declared app theme path | Replace only when the current digest equals the last recorded managed digest, or the file is absent |
| `managed-keys` | Named keys inside a user file, such as `gtk-theme-name` | Edit only listed keys; another edit after the last managed write is a conflict |
| `managed-region` | Text between `>>> hss-theme >>>` and `<<< hss-theme <<<` marker comments | Insert or replace only the region; content outside it is never changed |
| `user` | Anything else | Never written |

The record of managed writes is `hss-theme/managed.json`: generated-file digests, the last value written for each managed key, and a digest for each managed region, keyed by resolved path. A `generated` target that is not recorded there and differs from the candidate is a conflict (adoption may claim it only inside `hss-theme/`). Changing or removing a managed key, or editing inside a region, after the last managed write is a conflict for that unit. `managed-keys` and `managed-region` targets in existing user files require adoption consent. Each file belongs to one unit; a unit whose target resolves through a symlink to another unit's file is skipped.

### Batches

A batch applies a set of units. Each unit is one application's (or one global surface's) outputs plus its activation. Units may depend on other units; `theme-core` is the shared prerequisite.

1. Resolve and preview: list units, targets, classes, conflicts and activation effects.
2. Render every candidate into a private staging directory; validate syntax where a validator exists.
3. Mark units with conflicts or failed validation as skipped. Skip every unit that depends on a skipped or failed unit.
4. Commit each ready unit with `write_file_atomic` inside a reliability run (lock, manifest and backups). Unchanged candidates are not rewritten.
5. Record what was actually written in `managed.json` (including outputs written before a later failure in the same unit) and the resulting state in `state.json`. The recorded variant changes only when the shared `theme-core` unit applied.
6. Activate committed units through declared safe reloads; anything needing a restart becomes `pending`.
7. Report each unit as `applied`, `unchanged`, `skipped-conflict`, `skipped-dependency`, `not-adopted`, `not-selected` or `failed`, and the batch as `complete` or `partial`. Deferred activation (restart, next launch, relogin) and missing theme assets are listed in the report's `pending` notes, each prefixed with its unit.

Guarantees: per-file atomic replacement and a recoverable batch. A batch is not atomic across files, and runtime effects cannot be rolled back. `setup.sh --rollback RUN_ID` restores the files of any batch run, with the existing digest guard.

Appearance-only conflicts never block routing or handler changes for a launchable new primary. A failed shared prerequisite blocks all of its dependents.

### Activation

Units declare activation as data, never as shell text:

- `reload`: an argv run only when the application is running, for example `["makoctl","reload"]`.
- `signal`: a signal sent to processes owned by the user with an exact name, for example `kitty` and `SIGUSR1`.
- `gsettings`: schema/key/value triples applied through `gsettings` when it exists; prior values are recorded in the run's `theme-report.json` (`gsettings_previous`). File rollback does not restore them; switching the variant again does.
- `next-launch` or `relogin`: deferred and reported as `pending`.

Nothing is restarted automatically. Absent applications are reported, not launched.

## 8. Consent and preview

- Fresh installation (dotfiles copied by this setup run): shipped configuration already contains the theme includes, so the generated files are written and activated without extra adoption steps.
- Existing installation: `HSS_HARMONIZATION_ADOPT=preview|apply|skip`. When unset (the installer's "Automatic" setting), setup decides: configuration copied by this run adopts directly, an installation that adopted the theme before keeps applying, and any other existing installation is previewed (`preview`). Automatic adoption only takes over files under `~/dotfiles`, files that do not exist yet and files the theme already manages; other existing user files (for example a `~/.zshrc` or `foot.ini` that setup did not install) stay `not-adopted` until you choose `apply` explicitly. `preview` writes only the report under the setup run directory. `apply` adopts includes and managed keys into existing user files, preserving conflicting files and reporting partial state. `skip` leaves harmonization alone.
- Variant: `HSS_THEME_VARIANT=dark|light`. Unset (the installer's "Keep current" setting) keeps the recorded preference from `hss-theme/state.json`, or `dark` on a new installation.
- Runtime switching (Super+Shift+T, bar controls, `action_exec.sh theme.toggle`) is an explicit user request. It requires an installation that setup already adopted (otherwise the outcome is `unavailable` and nothing, including desktop settings, changes), changes only already-adopted outputs and never runs package installation.
- Preview stores only a report (units, targets, actions and reasons) in the setup run directory; staged copies of user files are removed.

## 9. Privacy and logging

Logs and reports never contain notification bodies, clipboard data, passwords, SSIDs, addresses, device aliases or complete URLs. Temporary files are created inside the reliability run directory or a private `mktemp -d` directory and removed on exit.
