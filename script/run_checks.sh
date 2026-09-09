#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_TEST_SCRATCH_PATH="${SWIFT_TEST_SCRATCH_PATH:-$ROOT_DIR/.build-checks}"

swift test --scratch-path "$SWIFT_TEST_SCRATCH_PATH"
