# PasteLite 0.3.0 release review

Reviewed November 5, 2026. Scope: the complete design implementation, storage/migration,
clipboard capture and delivery, privacy, keyboard/window behavior, update staging/installation,
packaging, repository hygiene, and release metadata.

## Findings resolved

| Priority | Finding | Resolution and verification |
| --- | --- | --- |
| P1 | Copying concealed history lost its pasteboard privacy marker. | Mark every outgoing concealed item, including plain-text conversions; test both formats. |
| P1 | A delayed reveal could populate a different selection or remain past expiry. | Cancellable request tokens, selection/presentation reset, expiry timer; controlled delayed-result and expiry tests. |
| P1 | Pending delete/undo could restore cleared history or replace a newer recapture. | Generation checks, deduplicated removals, non-overwriting restore, undo tokens; database and memory regressions. |
| P1 | Clear-on-quit could be bypassed by repeated requests and could deadlock inside an async action. | Cancel the initial termination while clearing, then terminate after success; isolated application exercised repeated quit and verified zero rows/assets. |
| P2 | Link metadata caused implicit network access to clipboard URLs. | Default-off Privacy setting and rejection of credential-bearing URLs; policy tests. |
| P2 | Plain-text conversion missed native URL/color/file and RTF-only representations. | Shared extraction and off-main conversion, with cancellation/focus/clipboard checks retained; conversion regressions. |
| P2 | Pin mutation could partially commit when pruning failed. | One transaction for pin/prune/snapshot; injected failure verifies rollback. |
| P2 | Actions dismissal could leave a non-key floating panel visible. | Close the panel after the Actions popover is dismissed outside; window regression test. |
| P2 | Failed hotkey registration could still display an active shortcut. | Only registered shortcuts appear as active; configured shortcuts remain visible in the recorder. |
| P2 | Packaging left the common output containing the last-built architecture. | Stage each architecture separately; release assets and checksums are architecture-specific. |

No unresolved code or packaging blocker was found in the reviewed scope after these fixes.

## Validation

- 90 tests pass in seven suites, including all previous regressions.
- 22 native light/dark and state renders generated and inspected.
- Real update staging validates the final packaged app, SHA-256, bundle/version identity,
  architecture, minimum OS, archive paths, and signature.
- Installer fixtures cover success, failed-launch rollback, missing source, protected existing
  backups, and paths containing spaces and shell metacharacters.
- An isolated DEBUG application passed repeated quit with history and attachment clearing.
- Both Release architectures build, both DMGs mount, and signatures/plists/checksums validate.
- The mounted arm64 app stays running in an isolated launch smoke test.
- Source/artifact privacy scans found no credentials, user databases, logs, local personal paths,
  debug fixtures, or unintended files in the published artifact set.
- Release source excludes the local design kit ZIP and full design exports; the selected branding
  and theme tokens are included intentionally.

## Test coverage limits

The desktop interaction service timed out, so this review did not repeat a manual cross-app paste,
popover focus, and shortcut-recorder walkthrough. Those paths have injectable behavior tests,
keyboard/window regressions, and native view render coverage. macOS 12 runtime behavior requires a
separate machine. The app is ad-hoc signed, without hardened runtime or notarization, as in earlier
releases; first launch may require Open Anyway.
