# Changelog

## 0.2.0 - 2026-09-09

Version 0.2.0 (build 20).

- Respect search-field editing and input-method composition before dispatching history shortcuts.
- Validate the paste target, focus, clipboard version, and cancellation before sending Paste.
- Show the actual paste target and report storage failures or memory-only history.
- Move SQLite work off the main actor and load original attachments on demand.
- Downsample and cache image previews with a memory budget.
- Preserve native clipboard colors and text containing NUL characters.
- Prevent cancelled status timers from clearing newer messages.

## 0.1.1 - 2026-07-10

- Enabled GitHub release checks by default in packaged builds.
- Kept in-memory clipboard history consistent when SQLite mutations fail.
- Made clipboard content hashing preserve item boundaries and type metadata.
- Bounded self-authored pasteboard change tracking to the latest write.
- Added regression coverage for update configuration, persistence failures,
  structured content hashing, and pasteboard write tracking.

## 0.1.0 - 2026-07-04

Initial PasteLite release.

- Added a menu bar clipboard history manager for macOS 12+.
- Added typed clipboard capture for text, links, colors, images, and files.
- Added SQLite-backed local history persistence.
- Added searchable floating history panel with compact desktop UI.
- Added copy, paste, delete, and clear-history actions.
- Added Return-to-copy behavior that hides the history panel after a successful
  clipboard write.
- Added direct paste into the previous app when Accessibility permission is
  granted.
- Added customizable global hotkey recording.
- Added version display, update-check plumbing, app icon, and release packaging.
- Added separate Apple Silicon and Intel release artifacts.

Checksums:

```text
69bcd104587fa594912ee9ebe8aa8cab3fa08d21488bab4b041ada95869ab524  PasteLite-0.1.0-macos-arm64.dmg
f5a958729b11c2dcc2c5713bd4906c5e11e9fc4b84b226d8dbd45a92da971e9b  PasteLite-0.1.0-macos-x86_64.dmg
```
