# PasteLite

PasteLite is a lightweight macOS clipboard history manager built with Swift,
SwiftUI, AppKit, and SQLite.

## Features

- Clipboard history for text, code, links, colors, images, and files.
- Searchable floating history panel with type filters, source app information,
  content previews, light/dark themes, and a compact mode.
- Pinned items, per-item usage counts, and five-second delete undo.
- Return performs the configured paste or copy action; Option-Return reverses
  the plain-text preference. Command-C copies without closing history.
- Paste selected history items into the previous app when Accessibility
  permission is granted.
- Custom global hotkey recording.
- Local SQLite persistence.
- Menu bar recording toggle and five recent items.
- General, Storage, Privacy, and Updates settings.
- Concealed-content masking and expiry, app exclusions, and clear-on-quit.
- Architecture-aware verified updates with stable/Beta channels.

## Requirements

- macOS 12.0 or later.
- Apple Silicon or Intel Mac.

## Downloads

Download [PasteLite 0.3.0](https://github.com/MoarLiu/PasteLite/releases/tag/v0.3.0):

- [Apple Silicon DMG](https://github.com/MoarLiu/PasteLite/releases/download/v0.3.0/PasteLite-0.3.0-macos-arm64.dmg)
- [Intel DMG](https://github.com/MoarLiu/PasteLite/releases/download/v0.3.0/PasteLite-0.3.0-macos-x86_64.dmg)

The release is ad-hoc signed and not notarized. If Gatekeeper blocks the first
launch, use System Settings → Privacy & Security → Open Anyway.

## Development

Current version: **0.3.0 (build 30)**.

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

Preview the redesign with isolated example data:

```bash
./script/preview_design.sh
```

See [design implementation and validation](docs/design-redesign.md) for the
design mapping, native preview exports, and remaining runtime acceptance.
