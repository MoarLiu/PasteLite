#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_TEST_SCRATCH_PATH="${SWIFT_TEST_SCRATCH_PATH:-$ROOT_DIR/.build-checks}"

swift test --scratch-path "$SWIFT_TEST_SCRATCH_PATH"
