# Changelog

## 0.3.2 - 2026-11-06

Version 0.3.2 (build 32).

- Keep concealed-content expiry fixed when reusing a history item, with an independent deadline persisted across restarts.
- Skip ambiguous clipboard changes during application switches to better respect excluded apps.
- Restore native Tab navigation, selected-text copying, and focused AppKit control activation.
- Keep Undo available alongside errors, preserve its payload after a failed restore, and allow retry within the undo window.
- Show copy failures from the menu bar and make paused recording visible in the history panel.
- Preserve selection during filtered history updates, choose adjacent items after deletion, and keep the selected item in view.
- Improve text contrast across all eight accent colors, including selected rows and filter counts.
- Improve concurrency safety for source-app icons and website previews, and make concealed-reveal expiry tests deterministic.

Upgrade notes: existing history migrates in place. Concealed items saved before this update receive a fixed deadline based on their stored copy time; an earlier original capture time cannot be recovered.

## 0.3.1 - 2026-11-06

Version 0.3.1 (build 31).

- Refresh the copy time and recent ordering when reusing a history item, while preserving pinned sections and the original record.
- Persist the updated time and ordering across app restarts without adding duplicate records.
- Remove copy and paste success notifications; failures still show their error messages.
- Download and verify updates inside PasteLite after a manual check, then offer Install & Relaunch to finish updating.
- Keep verified updates ready until installation and clearly label the optional GitHub release-notes link.

## 0.3.0 - 2026-11-05

Version 0.3.0 (build 30).

- Redesigned the history panel, menu bar, settings, and app icon with light/dark themes and eight accent colors.
- Added visible type filters, source app icons, richer previews, pinned items, usage counts, and a compact panel.
- Added five-second delete undo and clear-history confirmation that keeps pinned items.
- Made Return perform the selected paste/copy action, with Option-Return to reverse plain-text formatting, layered Escape, and inline shortcut hints.
- Added recording pause, recent menu bar items, storage controls, excluded apps, and clear-on-quit.
- Added masked concealed-content capture with 24-hour expiry and an option to skip it. Concealed copies retain their privacy marker, and delayed reveals cannot appear in another selection.
- Made website metadata fetching opt-in; local link previews work without connecting to websites.
- Added stable/Beta update checks, architecture-aware downloads, checksum and bundle validation, and installation rollback.
- Prevented pending deletes or undo operations from bringing back cleared history and kept clear-on-quit pending through repeated quit requests.
- Preserved rich text, native colors, and file paths when converting to plain text.

Upgrade notes: existing history migrates in place. Return now pastes when permission is available; choose “Copy to clipboard” in General settings to retain copy-only behavior.

## 0.2.1 - 2026-10-25

Version 0.2.1 (build 21).

- Prevent clipboard captures started before Clear History from restoring deleted records.
- Reject oversized clipboard content as a whole and keep the size warning visible in history.
- Scroll keyboard-selected and filtered history items into view without moving mouse-selected rows, and return to the first item on presentation.
- Pause the global hotkey while recording a shortcut, then restore the current choice on completion or cancellation.
- Restrict the history directory to its owner and repair database, WAL, and SHM permissions without replacing saved data.
- Exclude copied extended attributes and resource forks from release ZIP archives.

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
