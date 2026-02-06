#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Ghostty Dev"
APP_DST="/Applications/${APP_NAME}.app"
APP_SRC="${ROOT_DIR}/macos/build/ReleaseLocal/Ghostty.app"
ICON_SRC="${ROOT_DIR}/macos/Assets.xcassets/AppIconImage.imageset/macOS-AppIcon-1024px.png"

if ! command -v zig >/dev/null 2>&1; then
  echo "zig not found in PATH"
  exit 1
fi

if ! command -v /usr/bin/sips >/dev/null 2>&1; then
  echo "sips not found (required for icon generation)"
  exit 1
fi

if ! command -v /usr/bin/iconutil >/dev/null 2>&1; then
  echo "iconutil not found (required for icon generation)"
  exit 1
fi

echo "Building release app (Apple silicon only)..."
zig build install -Doptimize=ReleaseFast -Demit-macos-app=true -Dxcframework-target=native

if [[ ! -d "${APP_SRC}" ]]; then
  echo "App bundle not found at: ${APP_SRC}"
  exit 1
fi

echo "Installing to ${APP_DST}..."
rm -rf "${APP_DST}"
cp -R "${APP_SRC}" "${APP_DST}"

echo "Updating Info.plist..."
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.ghostty.dev" "${APP_DST}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "${APP_DST}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" "${APP_DST}/Contents/Info.plist"

if [[ ! -f "${ICON_SRC}" ]]; then
  echo "Icon source not found at: ${ICON_SRC}"
  exit 1
fi

echo "Generating dev icon..."
TMP_DIR="$(mktemp -d)"
ICONSET_DIR="${TMP_DIR}/DevIcon.iconset"
ICON_BASE="${TMP_DIR}/DevIconBase.png"
mkdir -p "${ICONSET_DIR}"

if command -v /usr/bin/osascript >/dev/null 2>&1; then
  ICON_SRC_ENV="${ICON_SRC}" ICON_BASE_ENV="${ICON_BASE}" /usr/bin/osascript -l JavaScript <<'JXA'
ObjC.import('Cocoa');
ObjC.import('QuartzCore');
ObjC.import('stdlib');

const src = $.getenv('ICON_SRC_ENV');
const dst = $.getenv('ICON_BASE_ENV');
if (!src || !dst) $.exit(2);

const url = $.NSURL.fileURLWithPath(src);
const image = $.CIImage.imageWithContentsOfURL(url);
if (!image) $.exit(1);

const filter = $.CIFilter.filterWithName('CIHueAdjust');
filter.setValueForKey(image, 'inputImage');
filter.setValueForKey(1.1, 'inputAngle'); // radians: hue rotation

const output = filter.valueForKey('outputImage');
const rep = $.NSCIImageRep.imageRepWithCIImage(output);
const nsimg = $.NSImage.alloc.initWithSize(rep.size);
nsimg.addRepresentation(rep);

const tiff = nsimg.TIFFRepresentation;
const bitmap = $.NSBitmapImageRep.imageRepWithData(tiff);
// JXA bridge expects a JS object for properties, not an NSDictionary.
const png = bitmap.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, {});
const ok = png.writeToURLAtomically($.NSURL.fileURLWithPath(dst), true);
if (!ok) $.exit(1);
$.exit(0);
JXA
else
  cp "${ICON_SRC}" "${ICON_BASE}"
fi

/usr/bin/sips -z 16 16 "${ICON_BASE}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "${ICON_BASE}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "${ICON_BASE}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "${ICON_BASE}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "${ICON_BASE}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "${ICON_BASE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "${ICON_BASE}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "${ICON_BASE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "${ICON_BASE}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
/usr/bin/sips -z 1024 1024 "${ICON_BASE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null

/usr/bin/iconutil -c icns "${ICONSET_DIR}" -o "${TMP_DIR}/DevIcon.icns"
cp "${TMP_DIR}/DevIcon.icns" "${APP_DST}/Contents/Resources/AppIcon.icns"

echo "Fixing ownership and clearing quarantine..."
if [[ -w "${APP_DST}" ]]; then
  /usr/sbin/chown -R "${USER}":staff "${APP_DST}" || true
  /usr/bin/xattr -dr com.apple.quarantine "${APP_DST}" || true
  /usr/bin/xattr -dr com.apple.provenance "${APP_DST}" || true
else
  if command -v sudo >/dev/null 2>&1; then
    sudo /usr/sbin/chown -R "${USER}":staff "${APP_DST}" || true
    sudo /usr/bin/xattr -dr com.apple.quarantine "${APP_DST}" || true
    sudo /usr/bin/xattr -dr com.apple.provenance "${APP_DST}" || true
  fi
fi

echo "Ad-hoc signing app bundle..."
/usr/bin/codesign --force --deep --sign - "${APP_DST}"

echo "Installed ${APP_NAME} with dev icon."
