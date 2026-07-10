# PasteLite

PasteLite is a lightweight macOS clipboard history manager built with Swift,
SwiftUI, AppKit, and SQLite.

## Features

- Clipboard history for text, links, colors, images, and files.
- Searchable floating history panel.
- Copy selected history items back to the clipboard with Return.
- Paste selected history items into the previous app when Accessibility
  permission is granted.
- Custom global hotkey recording.
- Local SQLite persistence.
- Menu bar utility UI.

## Requirements

- macOS 12.0 or later.
- Apple Silicon or Intel Mac.

## Downloads

Release builds are published as separate architecture-specific DMGs:

- `PasteLite-0.1.1-macos-arm64.dmg` for Apple Silicon Macs.
- `PasteLite-0.1.1-macos-x86_64.dmg` for Intel Macs.

The current release is ad-hoc signed and not notarized. macOS Gatekeeper may
require opening the app from Finder with "Open" the first time.

## Development

Run tests:

```bash
./script/run_checks.sh
```

Build and package the app locally:

```bash
CONFIGURATION=release ./script/build_and_run.sh --package
```

Build release artifacts for both architectures:

```bash
./script/package_release.sh
```
