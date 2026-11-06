# PasteLite

PasteLite is a lightweight macOS clipboard history manager built with Swift,
SwiftUI, AppKit, and SQLite.

## Features

- Clipboard history for text, code, links, colors, images, and files.
- Searchable floating history panel with type filters, source app information,
  content previews, light/dark themes, and a compact mode.
- A saved library with named content snapshots, custom groups, and editable text/code snippets.
- Saved content keeps its original clipboard formats independently of history cleanup.
- Search names, content, paths, and source apps; combine group and type filters.
- Per-item usage counts and five-second delete undo for history and saved items.
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
- Manual update checks download and verify new versions inside the app, then offer Install & Relaunch.

## Requirements

- macOS 12.0 or later.
- Apple Silicon or Intel Mac.

## Downloads

Download [PasteLite 0.3.2](https://github.com/MoarLiu/PasteLite/releases/tag/v0.3.2):

- [Apple Silicon DMG](https://github.com/MoarLiu/PasteLite/releases/download/v0.3.2/PasteLite-0.3.2-macos-arm64.dmg)
- [Intel DMG](https://github.com/MoarLiu/PasteLite/releases/download/v0.3.2/PasteLite-0.3.2-macos-x86_64.dmg)

The release is ad-hoc signed and not notarized. If Gatekeeper blocks the first
launch, use System Settings → Privacy & Security → Open Anyway.

## Development

Current development version: **0.4.0 (build 40), local release candidate**.
The published download links above remain on 0.3.2.

In 0.4.0, choose **Saved** in the history panel to organize reusable content.
Use **Save to Library** to retain original formats, or **Save as Text Snippet**
to create an editable plain-text copy. **Control-Tab** switches between History
and Saved; **Command-N** creates a snippet in Saved and **Command-E** edits a
selected snippet. **Command-Return** saves the editor.

Existing ordinary pins migrate to Ungrouped saved items. Concealed legacy pins
remain protected history with their existing expiry. Clearing history keeps the
saved library; clearing all data on quit includes saved items, snippets, and
groups. Saved file references require the original files to remain available.

See [0.4.0 development plan](docs/plan-0.4.0.md) and
[candidate acceptance](docs/acceptance-0.4.0.md) for scope and verification.

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
