#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PasteLite"
BUNDLE_ID="com.xia.PasteLite"
APP_VERSION="${APP_VERSION:-0.1.1}"
APP_BUILD="${APP_BUILD:-11}"
PASTELITE_UPDATE_CHECK_URL="${PASTELITE_UPDATE_CHECK_URL:-https://api.github.com/repos/MoarLiu/PasteLite/releases/latest}"
MIN_SYSTEM_VERSION="12.0"
CONFIGURATION="${CONFIGURATION:-debug}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RESOURCES_DIR="$ROOT_DIR/Resources"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ARCHIVE="$DIST_DIR/$APP_NAME-app.zip"
SWIFT_BUILD_SCRATCH_PATH="${SWIFT_BUILD_SCRATCH_PATH:-$ROOT_DIR/.build-run}"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

build_args=(--scratch-path "$SWIFT_BUILD_SCRATCH_PATH" --configuration "$CONFIGURATION" --product "$APP_NAME")
bin_path_args=(--scratch-path "$SWIFT_BUILD_SCRATCH_PATH" --configuration "$CONFIGURATION" --show-bin-path)

if [[ -n "${SWIFT_BUILD_TRIPLE:-}" ]]; then
  build_args+=(--triple "$SWIFT_BUILD_TRIPLE")
  bin_path_args+=(--triple "$SWIFT_BUILD_TRIPLE")
fi

swift build "${build_args[@]}"
BUILD_BINARY="$(swift build "${bin_path_args[@]}")/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -f "$RESOURCES_DIR/AppIcon.icns" ]]; then
  cp "$RESOURCES_DIR/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>PasteLiteUpdateCheckURL</key>
  <string>$PASTELITE_UPDATE_CHECK_URL</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --package|package)
    rm -f "$APP_ARCHIVE"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$APP_ARCHIVE"
    echo "$APP_BUNDLE"
    echo "$APP_ARCHIVE"
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not stay running after launch" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--package|--verify]" >&2
    exit 2
    ;;
esac
