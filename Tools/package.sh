#!/usr/bin/env bash
# package.sh - M9-T2: build a distributable app and DMG.
#
# Unsigned output is the default. Set SIGNING_IDENTITY to a Developer ID identity
# and NOTARY_PROFILE to an xcrun notarytool keychain profile for signed notarization.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '[package] error: %s\n' "$*" >&2; exit 1; }
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
case "$DIST_DIR" in
  "$ROOT_DIR"/dist|"$ROOT_DIR"/dist/*) ;;
  *) fail "DIST_DIR must stay inside the repository dist directory" ;;
esac
OUTPUT_DIR="$DIST_DIR"
mkdir -p "$ROOT_DIR/.build"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/.build/package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
DIST_DIR="$STAGING_DIR"
APP_NAME="NeriPlayer"
APP_DIR="$DIST_DIR/$APP_NAME.app"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-27.0}"
VALIDATION_ROOT="${VALIDATION_ROOT:-}"
BUNDLE_ID="moe.ouom.NeriPlayer"
if [[ -n "$VALIDATION_ROOT" ]]; then
  [[ "$VALIDATION_ROOT" == /* ]] || fail "VALIDATION_ROOT must be an absolute temporary data directory"
  BUNDLE_ID="$BUNDLE_ID.validation"
fi

log() { printf '[package] %s\n' "$*"; }

command -v swift >/dev/null || fail "Swift toolchain is required"
command -v hdiutil >/dev/null || fail "hdiutil is required on macOS"
command -v python3 >/dev/null || fail "Python 3 is required for dependency compatibility checks"
mkdir -p "$DIST_DIR"

log "building $APP_NAME ($VERSION, build $BUILD_NUMBER)"
(cd "$ROOT_DIR" && swift build -c "$BUILD_CONFIG" --product "$APP_NAME")
BIN_DIR="$(cd "$ROOT_DIR" && swift build -c "$BUILD_CONFIG" --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"
[[ -x "$EXECUTABLE" ]] || fail "built executable not found: $EXECUTABLE"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_DIR/Contents/MacOS/$APP_NAME"
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>NeriPlayer</string>
  <key>CFBundleExecutable</key><string>NeriPlayer</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>NeriPlayer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>NeriPlayer commands</string>
    <key>CFBundleURLSchemes</key><array><string>neriplayer</string></array>
  </dict></array>
</dict></plist>
PLIST

if [[ -n "$VALIDATION_ROOT" ]]; then
  python3 - "$APP_DIR/Contents/Info.plist" "$VALIDATION_ROOT" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
info['NeriPlayerValidationRoot'] = sys.argv[2]
info['CFBundleDisplayName'] = 'NeriPlayer 验证'
info.pop('CFBundleURLTypes', None)
with open(sys.argv[1], 'wb') as destination:
    plistlib.dump(info, destination)
PY
fi

ICONSET="$DIST_DIR/AppIcon.iconset"
if command -v iconutil >/dev/null 2>&1; then
  swift "$ROOT_DIR/Tools/make-app-icon.swift" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
else
  log "iconutil unavailable; continuing without AppIcon.icns"
fi

# Copy libmpv and its Homebrew dylib dependencies into the app, then rewrite
# absolute Homebrew references to @rpath so the DMG is self-contained.
FRAMEWORKS="$APP_DIR/Contents/Frameworks"
COPIED_DYLIBS=()
has_copied_dylib() {
  local candidate="$1"
  local copied
  for copied in "${COPIED_DYLIBS[@]-}"; do
    [[ "$copied" == "$candidate" ]] && return 0
  done
  return 1
}
copy_dylib() {
  local source="$1"
  [[ -f "$source" ]] || return 0
  local name target dep dep_path
  name="$(basename "$source")"
  has_copied_dylib "$source" && return 0
  COPIED_DYLIBS+=("$source")
  target="$FRAMEWORKS/$name"
  [[ -f "$target" ]] || cp "$source" "$target"
  while read -r dep; do
    dep_path="${dep%% *}"
    [[ "$dep_path" == /* && -f "$dep_path" ]] || continue
    case "$dep_path" in
      /usr/lib/*|/System/Library/*|/System/iOSSupport/*) continue ;;
    esac
    copy_dylib "$dep_path"
    install_name_tool -change "$dep_path" "@rpath/$(basename "$dep_path")" "$target"
  done < <(otool -L "$source" | tail -n +2 | sed 's/^[[:space:]]*//')
  install_name_tool -id "@rpath/$name" "$target"
}
MPV_SOURCE="$ROOT_DIR/Vendor/mpv/lib/libmpv.dylib"
[[ -f "$MPV_SOURCE" ]] || fail "Vendor/mpv/lib/libmpv.dylib missing; run Tools/fetch-mpv.sh first"
copy_dylib "$MPV_SOURCE"
EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/$APP_NAME"
MPV_ID="$(otool -D "$MPV_SOURCE" | tail -n 1)"
if [[ -n "$MPV_ID" ]]; then
  install_name_tool -change "$MPV_ID" "@rpath/$(basename "$MPV_SOURCE")" "$EXECUTABLE_PATH"
fi
# The SwiftPM executable carries a build-machine rpath. Remove it and add the
# app-relative one so the packaged binary never resolves a developer path.
install_name_tool -delete_rpath "$ROOT_DIR/Vendor/mpv/lib" "$EXECUTABLE_PATH" 2>/dev/null || true
install_name_tool -add_rpath '@loader_path/../Frameworks' "$EXECUTABLE_PATH"

# Fail before signing/DMG creation if the closure cannot honor the declared target.
# `auto` is an explicit local-validation choice; normal packages target macOS 27.
python3 "$ROOT_DIR/Tools/check-app-compatibility.py" "$APP_DIR" \
  --minimum "$MIN_MACOS_VERSION" --write-minimum --report "$DIST_DIR/compatibility.json"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  log "ad-hoc signing app"
  codesign --force --deep --sign - "$APP_DIR"
else
  log "signing with $SIGNING_IDENTITY"
  find "$APP_DIR/Contents/Frameworks" -type f -name '*.dylib' -exec codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" {} +
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
if [[ "$SIGNING_IDENTITY" != "-" && -n "$NOTARY_PROFILE" ]]; then
  log "submitting DMG for notarization"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  xcrun stapler staple "$DMG_PATH"
else
  log "notarization skipped (set SIGNING_IDENTITY and NOTARY_PROFILE to enable)"
fi
# Only publish local products after all checks succeed. Existing app/DMG versions
# are kept beside the new ones, so a failed build never destroys the last usable app.
mkdir -p "$OUTPUT_DIR"
for product in "$APP_DIR" "$DMG_PATH" "$DIST_DIR/compatibility.json"; do
  destination="$OUTPUT_DIR/$(basename "$product")"
  if [[ -e "$destination" ]]; then
    mv "$destination" "$destination.previous-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  mv "$product" "$destination"
done
log "created $OUTPUT_DIR/$(basename "$DMG_PATH")"
