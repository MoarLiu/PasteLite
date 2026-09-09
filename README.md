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

Download [PasteLite 0.2.0](https://github.com/MoarLiu/PasteLite/releases/tag/v0.2.0):

- [Apple Silicon DMG](https://github.com/MoarLiu/PasteLite/releases/download/v0.2.0/PasteLite-0.2.0-macos-arm64.dmg)
- [Intel DMG](https://github.com/MoarLiu/PasteLite/releases/download/v0.2.0/PasteLite-0.2.0-macos-x86_64.dmg)

The release is ad-hoc signed and not notarized. If Gatekeeper blocks the first
launch, use System Settings → Privacy & Security → Open Anyway.

## Development

Current version: **0.2.0 (build 20)**.

Build and test scripts prefer the full Xcode installation at `/Applications/Xcode.app`.
Set `DEVELOPER_DIR` explicitly to use another toolchain.

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
