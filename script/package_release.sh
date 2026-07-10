#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PasteLite"
APP_VERSION="${APP_VERSION:-0.1.1}"
APP_BUILD="${APP_BUILD:-11}"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHES="${ARCHES:-arm64 x86_64}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$DIST_DIR/release"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

triple_for_arch() {
  case "$1" in
    arm64)
      echo "arm64-apple-macosx12.0"
      ;;
    x86_64)
      echo "x86_64-apple-macosx12.0"
      ;;
    *)
      echo "unsupported arch: $1" >&2
      exit 2
      ;;
  esac
}

write_checksum() {
  local artifact="$1"
  (
    cd "$(dirname "$artifact")"
    shasum -a 256 "$(basename "$artifact")" >"$(basename "$artifact").sha256"
  )
}

for arch in $ARCHES; do
  triple="$(triple_for_arch "$arch")"
  stage_dir="$RELEASE_DIR/stage-$arch"
  app_path="$stage_dir/$APP_NAME.app"
  zip_path="$RELEASE_DIR/$APP_NAME-$APP_VERSION-macos-$arch.app.zip"
  dmg_path="$RELEASE_DIR/$APP_NAME-$APP_VERSION-macos-$arch.dmg"

  echo "==> Building $APP_NAME $APP_VERSION ($APP_BUILD) for $arch"
  SWIFT_BUILD_TRIPLE="$triple" \
    SWIFT_BUILD_SCRATCH_PATH="$ROOT_DIR/.build-release-$arch" \
    CONFIGURATION="$CONFIGURATION" \
    APP_VERSION="$APP_VERSION" \
    APP_BUILD="$APP_BUILD" \
    "$ROOT_DIR/script/build_and_run.sh" --package >/dev/null

  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"
  ditto "$DIST_DIR/$APP_NAME.app" "$app_path"

  actual_arches="$(lipo -archs "$app_path/Contents/MacOS/$APP_NAME")"
  if [[ "$actual_arches" != "$arch" ]]; then
    echo "expected $arch binary, got: $actual_arches" >&2
    exit 1
  fi

  codesign --verify --deep --strict "$app_path"
  plutil -lint "$app_path/Contents/Info.plist" >/dev/null

  rm -f "$zip_path" "$zip_path.sha256" "$dmg_path" "$dmg_path.sha256"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
  hdiutil create -volname "$APP_NAME $APP_VERSION $arch" -srcfolder "$stage_dir" -ov -format UDZO "$dmg_path" >/dev/null
  hdiutil verify "$dmg_path" >/dev/null

  write_checksum "$zip_path"
  write_checksum "$dmg_path"

  echo "$zip_path"
  echo "$dmg_path"
done
