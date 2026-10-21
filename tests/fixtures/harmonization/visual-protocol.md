# Manual visual review protocol

Plan F04.5. Policy P07: appearance is reviewed by a person in the user's disposable Arch Linux VM after all changes are assembled on the branch. There are no numeric thresholds: no pixel-difference tolerance, contrast ratio, latency or resource budget. Screenshots document a review; they are never an automated acceptance gate and never prove hidden functional behavior.

Record each review with the capture metadata template at the end of this file and attach it to the coverage case as `visual` evidence (`evidence-template.json`, `"kind": "visual"`).

## 1. Prepare the VM

1. Use a disposable VM snapshot with the branch installed by `setup.sh`. Note the repository commit (`git -C ~/Hyprland-Simple-Setup rev-parse HEAD`).
2. Create a dedicated review user or a fresh HOME with synthetic data only. Never sign in to accounts, never import browser profiles, calendars, credentials, agent configuration or real files.
3. Fix what can be fixed: one locale (`LANG=en_US.UTF-8` unless the scene tests another), the wallpaper shipped by the repository, a fixed clock if the scene shows time (or mask the clock, see section 4), and the output scale you intend to review.
4. Select the roles under review in the installer and record the primary and every selected member of each role involved.
5. Apply the variant under review with `Super+Shift+T` or the bar control and confirm it with `~/.config/hypr/scripts/status_read.sh theme`. Review dark first, then light, in the same session.

## 2. Synthetic content

Use only content created for the review:

- Notifications: `notify-send -a "HSS review" "Review summary" "Synthetic body text"`; for urgency states add `-u low` and `-u critical`; for long text use a sentence of placeholder words long enough to wrap.
- Files and folders: a `~/review/` tree with plain names, one long name, one name with spaces, one hidden file and one archive.
- Calendar: one local event titled "Review event" today and one all-day event; no online account.
- Terminal: `printf` a 16-color test line, a prompt in a Git repository created for the review, and a line of box-drawing and Nerd Font symbols.
- Network and Bluetooth: use whatever the VM exposes; never capture real SSIDs, MAC addresses, device aliases or IP addresses. Mask them if they appear.

## 3. Scenes

Review each scene in dark and light. A scene is one surface in one state; keep the window geometry and output unchanged between the two variants.

| Scene | States to show |
|---|---|
| Bar on every connected output | idle, hover, focused workspace, urgent workspace, each module's unavailable state (missing battery, Bluetooth or backlight) |
| Dock (when selected) | pinned, running, active indicator, hover |
| Launcher | empty query, results with icons, no results, long entry names, keyboard selection |
| Shared chooser and confirmation | default choice `No`, keyboard focus on each choice |
| Notifications | popup normal, low, critical, with actions, long text, history or center with several entries, DND on |
| Lock screen | idle, typing, wrong password; confirm no notification content is shown |
| Power and logout screen | default focus, hover, keyboard focus |
| Terminal | prompt, 16 ANSI colors, selection, cursor, Nerd Font glyphs |
| GTK 3, GTK 4/libadwaita and Qt/KDE apps from the selection | main window, a menu, a dialog, a disabled control, keyboard focus ring, text selection |
| Pointer | default, text and resize cursors over a GTK and a Qt window |

## 4. Capture

1. Capture with tools already in the catalog, for example `grim -o <output> scene-dark.png` for a full output or `grim -g "$(slurp)" scene-dark.png` for a region. Do not install capture tools only for the review.
2. Pair captures: the same scene, geometry and output for dark and light, named `<scene>-<state>-<variant>.png`.
3. Repeat a capture of an unchanged scene once per session. Differences between the two identical captures are rendering noise (cursor blink, clock, animation frame); note them so they are not mistaken for regressions.
4. Masks are allowed only for approved nondeterminism: clock, cursor blink, animation, and private data such as network names. Record every mask. Never mask a missing control, an error, or text that demonstrates the capability under review.
5. Fill in the capture metadata template for the session.

## 5. Privacy review before sharing

Before any capture leaves the VM, open it and check:

- no notification body other than the synthetic text above;
- no clipboard content, password field contents, SSID, IP or MAC address, Bluetooth alias, user name or host name that is not synthetic;
- no browser tab, calendar entry or file name from real data.

Delete and retake a capture that fails this check; masking is acceptable only for the private data listed above.

## 6. Semantic rubric

Judge each scene against these questions. Answer pass, issue or not applicable, and write one sentence for every issue. Native widget differences between toolkits are expected and are not issues by themselves.

| Aspect | Questions |
|---|---|
| Hierarchy | Is the primary content or action the most prominent element? Do headings, secondary text and disabled text read in that order? |
| Token intent | Do backgrounds, surfaces, accent (Blue) and semantic colors (success, warning, error, critical) match their meaning in Catppuccin Mocha (dark) or Latte (light)? |
| Readable contrast | Can every label, placeholder, disabled label and icon be read comfortably at the reviewed scale? Is anything near-invisible against its background? |
| Typography and glyphs | GUI text in Noto Sans, terminal and code in JetBrains Mono Nerd Font; terminal font size unchanged by the theme; no missing-glyph boxes or fallback symbols where an icon is expected |
| Focus | Is the keyboard focus visible on every interactive element in the scene, in both variants? |
| Clipping and layout | Is any text, icon or control clipped, overlapping or cut at the edge? Do long names wrap or elide cleanly? Are spacing and rounding consistent with neighbouring surfaces? |
| State cues | Are hover, pressed, selected, active, urgent, DND, muted, disabled and unavailable states distinguishable without relying on color alone? Does an unavailable device look different from disabled, error and stale? |
| Dark and light | Does the light variant keep the same hierarchy and state cues as the dark one? Is anything left in the other variant's colors? |
| Transparency | Is shell transparency subtle and is application content opaque? |
| Pointer | Is the Rose Pine cursor shown consistently over Hyprland, GTK and Qt surfaces? |
| Accessibility preferences | Are existing enlarged-text or reduced-motion preferences of the review user preserved? |

## 7. Calibration exercises

Run these once per review session before the real scenes, so the reviewer and the procedure demonstrably catch problems:

1. Identical scenes: capture the same unchanged scene twice; record that the rubric gives the same answers and list any noise.
2. Clipped control: shrink a window until a button label is cut; the clipping row must record an issue.
3. Missing glyph: show a string with an unassigned code point in a GUI label or terminal; the typography row must record an issue.
4. Wrong state indicator: toggle DND or mute and compare against the bar's indicator before it refreshes, or use an unavailable device; the state-cue row must record what is shown and whether it is truthful.

If a calibration exercise is not caught, stop and fix the procedure before reviewing scenes.

## 8. Sign-off

A review is complete when every scene for the cases under review has an answer for every rubric row in both variants, every issue has a sentence and a capture, and the reviewer signs the metadata record. A changed baseline needs a written reason; never regenerate captures to hide a difference. Record failed scenes as `failed` with the issue as the reason, and scenes that could not be shown (for example missing hardware) as `blocked` or `skipped` with the reason. Physical-hardware appearance stays unverified.

## Capture metadata template

```yaml
review_id: VR-YYYYMMDD-01
date: YYYY-MM-DD
reviewer: ""
sign_off: ""            # reviewer name and date once section 8 is satisfied
repository_commit: ""
coverage_cases: []      # for example [D01-bar-waybar, F04-theme-visual-review]
environment:
  vm: ""                # hypervisor and image
  hyprland: ""          # hyprctl version
  outputs: []           # name, resolution, scale (hyprctl monitors)
  locale: ""
packages: {}            # pacman -Q output for every application in the scenes
theme:
  variant: dark         # from status_read.sh theme
  tokens_sha256: ""     # ~/.config/hss-theme/state.json
  fonts: ""             # fc-match "Noto Sans"; fc-match "JetBrainsMono Nerd Font"
  icons: ""
  cursor: ""
selection: {}           # role: {primary: ..., members: [...]} for every role involved
accessibility_preferences: ""
masks: []               # region, reason (clock, blink, animation, private data)
noise_observed: ""      # from the repeated identical capture
calibration: {identical: "", clipped: "", missing_glyph: "", wrong_state: ""}
scenes:
  - scene: ""
    state: ""
    captures: {dark: "", light: ""}
    privacy_reviewed: false
    rubric:
      hierarchy: ""
      token_intent: ""
      contrast: ""
      typography: ""
      focus: ""
      clipping: ""
      state_cues: ""
      dark_light: ""
      transparency: ""
      pointer: ""
    issues: []
    result: not-run     # passed, failed, blocked, skipped
```
