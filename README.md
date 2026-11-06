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
- Local image OCR, source filtering, ordered multi-selection and Paste Stack.
- Saved-library JSON backup, folder sync, snippet variables, local script transforms and optional read-only MCP.

## Requirements

- macOS 12.0 or later.
- Apple Silicon Mac for 0.4.1 and later. The published 0.4.0 Intel build remains available below.

## Downloads

Download [PasteLite 0.4.1](https://github.com/MoarLiu/PasteLite/releases/tag/v0.4.1):

- [Apple Silicon DMG](https://github.com/MoarLiu/PasteLite/releases/download/v0.4.1/PasteLite-0.4.1-macos-arm64.dmg)
- [Legacy 0.4.0 Intel DMG](https://github.com/MoarLiu/PasteLite/releases/download/v0.4.0/PasteLite-0.4.0-macos-x86_64.dmg)

The release is ad-hoc signed and not notarized. If Gatekeeper blocks the first
launch, use System Settings → Privacy & Security → Open Anyway.

## Development

Current version: **0.4.1 (build 41), Apple Silicon only**.

Version 0.4.1 adds saved-library JSON backups under Saved → Actions,
local image OCR, source filtering, ordered multi-selection with merged text
copying, and Paste Stack. Select items and choose Queue, then open Stack to
reorder entries and paste them one at a time. A failed paste keeps the queue
head. Use Current Target explicitly allows a different target app.

Backups contain original clipboard formats and image payloads; files remain
references. Import merges without overwriting existing content or edits.
OCR uses Apple Vision on this Mac and sends no image data to a service.

Snippet text can use `{{name}}` or Chinese variable names. Calling the snippet
opens a form and preview. Actions → Transform with Script lets you choose a
local `.sh` file, run it explicitly with UTF-8 stdin/stdout, and inspect the
result before copying. Scripts use your normal permissions; execution is never
automatic.

Settings → Privacy contains the optional local MCP server. It is disabled by
default, binds only to `127.0.0.1`, and requires the generated Bearer token.
It exposes only `search_history` and `search_saved`, excluding concealed
content. Copy Connection Details supplies the address and authentication header.

Settings → Storage contains Folder Sync. Choose the same shared folder on
each Mac, for example in iCloud Drive. Saved items, groups, edits and deletions
propagate through immutable JSON change files. Conflict ordering uses a logical
timestamp and UUID; independently saved copies of the same original converge
on one identity. Shared files are readable and keep previous versions. History
is not synced. Disabling sync keeps shared files; clear-on-quit stops sync and
clears this Mac while existing shared copies remain.

See [0.4.1 completion plan](docs/plan-0.4.1.md) and
[candidate acceptance](docs/acceptance-0.4.1.md) for progress and remaining scope.

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
[release verification](docs/acceptance-0.4.0.md) for scope and verification.

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

Build release artifacts for Apple Silicon:

```bash
./script/package_release.sh
```

Preview the redesign with isolated example data:

```bash
./script/preview_design.sh
```

See [design implementation and validation](docs/design-redesign.md) for the
design mapping, native preview exports, and remaining runtime acceptance.
