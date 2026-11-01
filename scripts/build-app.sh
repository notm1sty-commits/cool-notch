#!/usr/bin/env bash
# Собирает «Cool Notch.app», а также CoolNotch.zip и CoolNotch.dmg в .build/app/
# Использование: ./scripts/build-app.sh   (нужен macOS с Xcode или Command Line Tools)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Cool Notch"
EXECUTABLE="CoolNotch"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUT_DIR=".build/app"
APP_DIR="$OUT_DIR/$APP_NAME.app"

ARCH_FLAGS=(--arch arm64 --arch x86_64)
if [[ "${UNIVERSAL:-1}" != "1" ]]; then
  ARCH_FLAGS=()
fi

echo "▸ Сборка $APP_NAME $VERSION ($BUILD_NUMBER)"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$OUT_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "▸ Помощник MediaBridge (системный «Что играет»)"
mkdir -p "$APP_DIR/Contents/Frameworks"
BRIDGE_ARCHS=(-arch arm64 -arch x86_64)
if [[ "${UNIVERSAL:-1}" != "1" ]]; then
  BRIDGE_ARCHS=()
fi
clang -dynamiclib -fobjc-arc -fmodules -O2 -Wall \
  ${BRIDGE_ARCHS[@]+"${BRIDGE_ARCHS[@]}"} -mmacosx-version-min=14.0 \
  -framework Foundation \
  -install_name "@rpath/libCoolNotchMediaBridge.dylib" \
  -o "$APP_DIR/Contents/Frameworks/libCoolNotchMediaBridge.dylib" \
  Helpers/MediaBridge/MediaBridge.m
codesign --force --sign - "$APP_DIR/Contents/Frameworks/libCoolNotchMediaBridge.dylib"
cp Resources/media-bridge.pl "$APP_DIR/Contents/Resources/media-bridge.pl"

# Картинки для демо-режима (--demo), около 200 КБ.
cp -R Resources/Demo "$APP_DIR/Contents/Resources/Demo"

echo "▸ Иконка"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "▸ Подпись (ad-hoc)"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --verbose "$APP_DIR"

echo "▸ Архивы"
ditto -c -k --keepParent "$APP_DIR" "$OUT_DIR/CoolNotch.zip"

DMG_STAGE="$(mktemp -d)"
cp -R "$APP_DIR" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$OUT_DIR/CoolNotch.dmg" >/dev/null

echo "✓ Готово: $APP_DIR"
echo "  $OUT_DIR/CoolNotch.dmg"
