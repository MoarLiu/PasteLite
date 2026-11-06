# PasteLite design implementation

Design source: `PasteLite-Design-Kit`, specification v1.0 dated November 5, 2026.
The implementation uses the recommended A / Stack identity and retains macOS 12 support.

## Implemented surfaces and behavior

| Design area | Implementation |
| --- | --- |
| Brand | Stack app icon, normal and paused template menu bar icons; packaging includes the resources. |
| History panel | 880 × 560 pt, 336 pt list, native popover material, semantic colors, type chips with counts, pinned and date groups. |
| Compact mode | 520 × 560 pt, list and primary action with Actions menu. |
| Rows | Content thumbnails or type icons, source app icon/name, compact relative time, pin state, Command-1…9 hints. |
| Search | Title, preview and source search; highlighted matches; empty states with Show All Items. Concealed text stays out of search. |
| Previews | Text, code with language/line numbers, images on a checkerboard, file paths with Finder reveal, opt-in website cards, color representations and copying. |
| Concealed content | Masked title/preview, explicit reveal, configurable skip policy, 24-hour expiry. Transient and generated content remain excluded. |
| Actions | Copy, primary paste/copy, pin/unpin, safe link opening, delete with 5-second undo, clear confirmation preserving pins. |
| Paste | Return invokes the configured primary action; Option-Return reverses the plain text preference; missing permission falls back to copy. Paste/copy HUD lasts 1.7 seconds. |
| Keyboard | Arrows, Command-Up/Down, Command-C/K/Backspace/Z, Shift-Command-P, Command-1…9, standard Tab/Shift-Tab focus navigation and layered Escape; text selections, focused controls, marked text and modal sheets keep their native input behavior. |
| Menu bar | Recording toggle and paused icon, item count, five most recent items, history/settings/update entry points, quit. |
| General settings | Recorder with inline reset/disable, registration feedback and input-source conflict hint; position, preview, paste behavior, theme and eight accent colors. |
| Storage settings | Type breakdown, physical database/WAL/SHM size, adjustable limit, Finder reveal and clear history. Pinned items do not count against the rolling unpinned limit. |
| Privacy settings | Live permission status, sensitive content policy, excluded apps, clear including pins on quit. |
| Updates | HTTPS stable/Beta feeds, manual/periodic checks, optional automatic installation, release and feedback links, advanced feed setting. Updates match architecture and require official GitHub assets, SHA-256, valid archive paths, bundle/version identity and code signature. Replacement uses an adjacent backup and restores it on failure. |
| Compatibility | Existing SQLite history migrates in place to schema v2; assets stay lazy-loaded. Appearance follows the system or the chosen mode. Native motion respects Reduce Motion. |

The user's existing shortcut choice remains in effect. The UI displays the shortcut actually registered, including the automatic fallback.

## Automated verification

Behavior coverage includes existing history/paste regressions, schema migration preserving BLOBs,
pins across prune/clear/recapture/reload, usage counts, undo with original assets, concealed capture
and expiry, pause and exclusion policies, plain text conversion, clipboard rollback privacy markers,
version ordering and update archive rejection.

`DesignSnapshotTests` exports 22 native view renders when explicitly configured. These use only
synthetic fixtures in a separate data directory and preferences suite. Generated output is under
`outputs/design-review/` and is intentionally ignored by Git.

```sh
PASTELITE_DATA_DIRECTORY=/tmp/pastelite-native-previews \
PASTELITE_PREFERENCES_SUITE=PasteLite.NativePreviews \
PASTELITE_PREVIEW_OUTPUT="$PWD/outputs/design-review" \
./script/run_checks.sh
```

On the current Xcode toolchain, a `clang-stat-cache` process stalled during a parallel build.
The suite also runs through SwiftPM's native build system:

```sh
SWIFT_TEST_BUILD_SYSTEM=native \
SWIFT_TEST_SCRATCH_PATH="$PWD/.build-native-checks" \
./script/run_checks.sh
```

## Interactive preview

```sh
./script/preview_design.sh
```

This creates a separate `com.xia.PasteLite.preview` app with temporary data and preferences.
It seeds example items, disables clipboard capture and automatic update checks, and opens history.
The debug preview option is excluded from Release builds.

## Acceptance status

All 90 tests pass. Both arm64 and x86_64 Release builds and bundle signature/plist checks pass.
Native view renders cover light/dark history, all settings pages, menu, all preview types,
compact mode and search states.

Local artifacts:

- `dist/release/PasteLite-0.3.0-macos-arm64.dmg` and `.app.zip`.
- `dist/release/PasteLite-0.3.0-macos-x86_64.dmg` and `.app.zip`.
- Each artifact has an accompanying SHA-256 file.

The release review added regression coverage for concealment markers, cancelled and expired reveals,
concurrent delete/clear/undo, transactional pins, richer plain-text conversion, and installer rollback.
An isolated DEBUG app passed a repeated-quit exercise: history items and attachments were cleared
before the app exited. The packaged app passed the real update staging/identity/signature validation
path. Both DMGs were mounted and checked.

The desktop interaction service timed out during this review, so a fresh manual cross-app paste and
visual focus walkthrough was unavailable. Existing injectable paste/focus tests, keyboard/window
regressions and native renders pass. macOS 12 runtime behavior requires a separate macOS 12 machine.
The app remains ad-hoc signed and not notarized, matching prior releases.
