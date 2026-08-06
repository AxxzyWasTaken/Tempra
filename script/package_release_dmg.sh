#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Tempra"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
UPLOAD_RELEASE=false

usage() {
  echo "usage: $0 [--upload]" >&2
}

case "${1:-}" in
  "")
    ;;
  --upload)
    UPLOAD_RELEASE=true
    ;;
  *)
    usage
    exit 2
    ;;
esac
if (( $# > 1 )); then
  usage
  exit 2
fi

APP_VERSION="$(/usr/bin/sed -n 's/^APP_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$BUILD_SCRIPT")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "The app version in $BUILD_SCRIPT is missing or invalid." >&2
  exit 1
fi

IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" \
    | /usr/bin/awk -F'"' '/"Developer ID Application:/ { print $2; exit }')"
fi
IDENTITY_RECORD="$(printf '%s\n' "$IDENTITIES" \
  | /usr/bin/awk -v identity="$SIGN_IDENTITY" 'index($0, identity) { print; exit }')"
if [[ -z "$SIGN_IDENTITY" || "$IDENTITY_RECORD" != *"Developer ID Application:"* ]]; then
  echo "A Developer ID Application signing identity is required." >&2
  echo "Install the identity or set CODE_SIGN_IDENTITY to its name or SHA-1 hash." >&2
  exit 1
fi

NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"
if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "NOTARYTOOL_PROFILE must name a validated notarytool Keychain profile." >&2
  exit 1
fi

if $UPLOAD_RELEASE; then
  if ! command -v gh >/dev/null; then
    echo "GitHub CLI is required when --upload is used." >&2
    exit 1
  fi
  gh auth status >/dev/null
fi

echo "Validating notarization credentials."
xcrun notarytool history \
  --keychain-profile "$NOTARY_PROFILE" \
  --output-format json \
  --no-progress >/dev/null

mkdir -p "$DIST_DIR"
WORK_DIR="$(mktemp -d "$DIST_DIR/.tempra-release.XXXXXX")"
cleanup() {
  if [[ -n "${WORK_DIR:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

ZIP_PATH="$WORK_DIR/$APP_NAME-$APP_VERSION.zip"
DMG_ROOT="$WORK_DIR/dmg-root"
TEMP_DMG_PATH="$WORK_DIR/$APP_NAME-$APP_VERSION.dmg"
DMG_PATH="$DIST_DIR/$APP_NAME-$APP_VERSION.dmg"

submit_for_notarization() {
  local artifact="$1"
  local response
  local status

  if ! response="$(xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --timeout 30m \
    --output-format json \
    --no-progress)"; then
    printf '%s\n' "$response" >&2
    return 1
  fi
  printf '%s\n' "$response"
  status="$(printf '%s' "$response" \
    | /usr/bin/plutil -extract status raw -o - -)"
  if [[ "$status" != "Accepted" ]]; then
    echo "Notarization did not accept $artifact." >&2
    return 1
  fi
}

echo "Building and signing $APP_NAME $APP_VERSION with Developer ID."
CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_TIMESTAMP=1 \
  "$BUILD_SCRIPT" --build-only

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "Notarizing the app."
submit_for_notarization "$ZIP_PATH"
xcrun stapler staple -v "$APP_BUNDLE"
xcrun stapler validate -v "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

mkdir -p "$DMG_ROOT"
/usr/bin/ditto "$APP_BUNDLE" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

echo "Creating $DMG_PATH."
/usr/sbin/diskutil image create from \
  --format UDZO \
  --volumeName "$APP_NAME $APP_VERSION" \
  "$DMG_ROOT" \
  "$TEMP_DMG_PATH"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp "$TEMP_DMG_PATH"
/usr/bin/codesign --verify --verbose=2 "$TEMP_DMG_PATH"

echo "Notarizing the DMG."
submit_for_notarization "$TEMP_DMG_PATH"
xcrun stapler staple -v "$TEMP_DMG_PATH"
xcrun stapler validate -v "$TEMP_DMG_PATH"
/usr/bin/hdiutil verify "$TEMP_DMG_PATH"
/usr/sbin/spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$TEMP_DMG_PATH"

/bin/mv -f "$TEMP_DMG_PATH" "$DMG_PATH"
/usr/bin/shasum -a 256 "$DMG_PATH"

if $UPLOAD_RELEASE; then
  gh release upload "v$APP_VERSION" "$DMG_PATH" --clobber
  echo "Uploaded $DMG_PATH to release v$APP_VERSION."
else
  echo "Created $DMG_PATH."
fi
