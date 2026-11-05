#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW_DATA="$(mktemp -d /tmp/pastelite-design-preview.XXXXXX)"
PREVIEW_DIST="$ROOT_DIR/dist/design-preview"

BUNDLE_ID=com.xia.PasteLite.preview \
CONFIGURATION=debug \
DIST_DIR="$PREVIEW_DIST" \
SWIFT_BUILD_SCRATCH_PATH="$ROOT_DIR/.build-design-preview" \
  "$ROOT_DIR/script/build_and_run.sh" --package

export PASTELITE_DATA_DIRECTORY="$PREVIEW_DATA"
export PASTELITE_PREFERENCES_SUITE="com.xia.PasteLite.preview.$(basename "$PREVIEW_DATA")"
exec "$PREVIEW_DIST/PasteLite.app/Contents/MacOS/PasteLite" --ui-preview
