#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Tempra"
WATCHDOG_NAME="TempraWatchdog"
PRIVILEGED_HELPER_NAME="TempraPrivilegedHelper"
LEGACY_APP_NAME="Temper"
BUNDLE_ID="io.github.temperapp.Temper"
MIN_SYSTEM_VERSION="14.2"
APP_VERSION="0.3.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_HELPER_TOOLS="$APP_CONTENTS/Library/HelperTools"
APP_LAUNCH_DAEMONS="$APP_CONTENTS/Library/LaunchDaemons"
APP_BINARY="$APP_MACOS/$APP_NAME"
WATCHDOG_BINARY="$APP_MACOS/$WATCHDOG_NAME"
PRIVILEGED_HELPER_BINARY="$APP_HELPER_TOOLS/$PRIVILEGED_HELPER_NAME"
PRIVILEGED_HELPER_LABEL="$BUNDLE_ID.PrivilegedHelper"
PRIVILEGED_HELPER_PLIST="$APP_LAUNCH_DAEMONS/$PRIVILEGED_HELPER_LABEL.plist"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$ROOT_DIR/Resources/AppIcon.icns"

stop_running_process() {
  local process_name="$1"
  local attempt

  if ! pgrep -x "$process_name" >/dev/null; then
    return 0
  fi

  if ! /usr/bin/osascript \
    -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1; then
    echo "Could not quit $process_name cleanly; refusing to leave managed apps stopped" >&2
    return 1
  fi

  for ((attempt = 0; attempt < 50; attempt++)); do
    if ! pgrep -x "$process_name" >/dev/null; then
      return 0
    fi
    sleep 0.1
  done

  echo "Timed out waiting for $process_name to quit" >&2
  return 1
}

stop_running_app() {
  stop_running_process "$LEGACY_APP_NAME"
  stop_running_process "$APP_NAME"
}

cd "$ROOT_DIR"
stop_running_app
BUILD_CONFIGURATION="release"
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  BUILD_CONFIGURATION="debug"
fi

swift build -c "$BUILD_CONFIGURATION"
BUILD_BIN_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
BUILD_WATCHDOG_BINARY="$BUILD_BIN_DIR/$WATCHDOG_NAME"
BUILD_PRIVILEGED_HELPER_BINARY="$BUILD_BIN_DIR/$PRIVILEGED_HELPER_NAME"

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/awk '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
  echo "A real Apple code-signing identity is required for Tempra's privileged helper." >&2
  echo "Set CODE_SIGN_IDENTITY to an Apple Development or Developer ID Application identity." >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_HELPER_TOOLS" "$APP_LAUNCH_DAEMONS"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_WATCHDOG_BINARY" "$WATCHDOG_BINARY"
cp "$BUILD_PRIVILEGED_HELPER_BINARY" "$PRIVILEGED_HELPER_BINARY"
cp "$APP_ICON" "$APP_RESOURCES/AppIcon.icns"
chmod +x "$APP_BINARY" "$WATCHDOG_BINARY" "$PRIVILEGED_HELPER_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>3</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

cat >"$PRIVILEGED_HELPER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>$BUNDLE_ID</string>
  </array>
  <key>Label</key>
  <string>$PRIVILEGED_HELPER_LABEL</string>
  <key>BundleProgram</key>
  <string>Contents/Library/HelperTools/$PRIVILEGED_HELPER_NAME</string>
  <key>MachServices</key>
  <dict>
    <key>$PRIVILEGED_HELPER_LABEL</key>
    <true/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$INFO_PLIST" "$PRIVILEGED_HELPER_PLIST"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime \
  --identifier "$BUNDLE_ID.watchdog" "$WATCHDOG_BINARY"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime \
  --identifier "$PRIVILEGED_HELPER_LABEL" "$PRIVILEGED_HELPER_BINARY"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime \
  --identifier "$BUNDLE_ID" "$APP_BINARY"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime "$APP_BUNDLE"

open_app() {
  stop_running_app
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --build-only|build-only)
    echo "Built $APP_BUNDLE"
    ;;
  --debug|debug)
    stop_running_app
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
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
