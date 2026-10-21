# Harmonization verification fixtures

Plan F04 owns this directory. It holds the coverage descriptors that tie every catalog option to its tests, the evidence template and the manual visual-review protocol. The shared fixture library is `tests/shell/harmonization_testlib.sh`.

| Path | Purpose |
|---|---|
| `coverage/*.json` | Coverage fragments, one per owner. Validated by `tests/shell/harmonization_coverage.sh` |
| `evidence-template.json` | Shape of one evidence record for a `passed` result |
| `visual-protocol.md` | Manual visual review in the disposable Arch VM, with the capture metadata template |

## Evidence levels

Each level proves something different. A higher functional level never follows from a lower one, and visual evidence never proves hidden functional behavior.

| Level | How it is produced | What it can prove | What it cannot prove |
|---|---|---|---|
| `static` | Reading files: registry, rendered templates, configuration wiring | Structure, syntax, token mapping, that a menu entry or include exists | That any command runs or any application reads the file |
| `argv` | A double records the exact NUL-separated argv | Which executable is chosen and that arguments arrive literally, once | That the application behaves as intended |
| `modeled-effect` | A stateful double changes fixture state; the test reads that state back independently | Adapter orchestration: ordering, skips, conflicts, outcomes, cleanup, no writes on dry-run | Real provider behavior, version differences, rendering |
| `real-effect` | The actual provider in an isolated environment (for example `archresearch` with `hss-headless`), with state observed independently of the adapter's own report | That the native capability works in the recorded environment and version | Other versions, physical hardware, appearance |
| `visual` | Manual review following `visual-protocol.md` | Hierarchy, readability, focus, clipping and state cues in the recorded scene | Functional correctness that is not visible |

Rules:

- An echoed request is not an oracle. A double that reports success without changing state must make the test fail (see the read-back case in `tests/shell/theme_activation.sh`).
- `documentation` evidence (ledger only) is weaker than `static`.
- Physical hardware stays `unverified`; a VM or headless run never certifies radios, audio devices, batteries, backlights, mixed-DPI hotplug or suspend/hibernate.
- Never claim `real-effect` for something only read in documentation.

## Coverage fragments

Each owner writes one file `coverage/<name>.json`. The validator merges all fragments.

```json
{
  "schema_version": 1,
  "owner": "D03",
  "description": "Optional one-line description",
  "cases": [
    {
      "id": "D03-swaync-dnd",
      "option": "notifications/swaync",
      "capability": "notifications.dnd",
      "evidence_required": "real-effect",
      "tests": [{"path": "tests/shell/notifications_contracts.sh", "state": "delivered"}],
      "vm_check": "Toggle DND from the bar; send a normal and a critical notification",
      "result": "not-run",
      "limits": ""
    }
  ]
}
```

| Field | Rule |
|---|---|
| `owner` | `F01`-`F04`, `D01`-`D07` or `I01`. A case may override it with its own `owner` |
| `id` | Unique across all fragments and prefixed with the case owner, for example `D03-...` |
| `option` | `role/package` from `packages.json`, `role/none` for the optional roles `dock`, `agent`, `tui_file_manager` and `gui_editor`, `generic/<name>` (or `package/<name>`) for a generic package from the catalog or the ledger's `generic_packages`, or `null` for a cross-cutting foundation case |
| `capability` | Capability ID from the F01 ledger (`capabilities.json`, `capabilities.d/*.json`). Checked as a foreign key whenever the ledger exists. The reserved ID `theme` means the option's `theme` entry in the ledger (`options.<option>.theme`), which must exist. `null` only for cross-cutting cases and for placeholders whose tests are all planned |
| `evidence_required` | `documentation` (a documented limitation, no test), `static`, `argv`, `modeled-effect`, `real-effect` or `visual` |
| `tests` | List of `{"path", "state"}` (optional `case` name). It may be empty only for a manual-only case with a `vm_check`, or a `documentation` case with a reason in `limits`. `delivered`: the file exists in the repository. `planned`: `limits` must name the owner task that delivers it, for example `D03.6` |
| `vm_check` | The manual VM step for this case; empty when nothing is checked in the VM |
| `result` | `not-run`, `passed`, `failed`, `blocked` or `skipped`. Owners leave `not-run`; I01 records results |
| `limits` | Known limits, hardware boundaries, decision IDs. Required reason for `failed`, `blocked` and `skipped` |
| `evidence` | Required for `passed`: an evidence ID (`E-D03-001`, resolved in the ledger), an object shaped like `evidence-template.json`, or a list of these. Its level must reach `evidence_required`; argv evidence never satisfies a real-effect requirement |

Optional descriptive fields: `selection`, `context`, `preconditions`, `assertions`, `notes`. Any other field is rejected so typos cannot silently drop data.

The validator also fails when any catalog option or None state has no case from an owned fragment, when a `passed` result has neither a delivered test nor a manual `vm_check`, and when `packages.json` changes its optional roles.

## Adding cases as a domain owner

1. Replace your skeleton fragment (`d01-panels.json` ... `d07-session-auxiliary.json`). Each skeleton holds one planned placeholder case per option you own; keep at least one case for every option and None state.
2. Use capability IDs from your ledger fragment and set `evidence_required` to the level that proves the capability, not the level your test happens to reach.
3. Point `tests` at your suite. Use `planned` with the producing task in `limits` until the file exists.
4. Write a `vm_check` a user can follow in the VM.
5. Run `bash tests/run.sh tests/shell/harmonization_coverage.sh` in the test userland.

Suites build on `tests/shell/harmonization_testlib.sh`: `ht_fixture_init` (private HOME/XDG roots, no host session variables, stateful doubles first on PATH), `ht_double`, `ht_write_roles`, `ht_stow_fixture`, `ht_copy_runtime`, `ht_theme_apply`, `ht_snapshot_tree`/`assert_tree_unchanged`, `ht_assert_user_lines_preserved`, `assert_argv` and `assert_json`.
