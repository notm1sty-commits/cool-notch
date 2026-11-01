#!/usr/bin/env bash
# Собирает «Halo.app», а также Halo.zip и Halo.dmg в .build/app/
# Использование: ./scripts/build-app.sh   (нужен macOS с Xcode или Command Line Tools)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Halo"
EXECUTABLE="CoolNotch"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
# Постоянная подпись (например, самоподписанный сертификат) сохраняет разрешения macOS между обновлениями.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
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
codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/Frameworks/libCoolNotchMediaBridge.dylib"
cp Resources/media-bridge.pl "$APP_DIR/Contents/Resources/media-bridge.pl"

# Картинки для демо-режима (--demo), около 200 КБ.
cp -R Resources/Demo "$APP_DIR/Contents/Resources/Demo"

echo "▸ Иконка"
# Классическая .icns из PNG — её показывают macOS 14 и 15.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

# Иконка в стиле macOS 26 (светлая, тёмная, прозрачная и тонированная) — из документа Icon Composer
# Resources/AppIcon.icon. Собирает её только actool из Xcode 26; без него остаётся классическая.
find_xcode26() {
  local candidate version
  for candidate in /Applications/Xcode_26*.app /Applications/Xcode-26*.app /Applications/Xcode.app "$(xcode-select -p 2>/dev/null)/../.."; do
    [[ -x "$candidate/Contents/Developer/usr/bin/actool" ]] || continue
    version="$("$candidate/Contents/Developer/usr/bin/xcodebuild" -version 2>/dev/null | awk 'NR==1 {print $2}')"
    if [[ "${version%%.*}" =~ ^[0-9]+$ ]] && (( ${version%%.*} >= 26 )); then
      (cd "$candidate" && pwd)
      return 0
    fi
  done
  return 1
}
if XCODE26="$(find_xcode26)"; then
  ICON_OUT="$(mktemp -d)"
  if DEVELOPER_DIR="$XCODE26/Contents/Developer" xcrun actool Resources/AppIcon.icon \
       --compile "$ICON_OUT" \
       --output-format human-readable-text --warnings --errors \
       --output-partial-info-plist "$ICON_OUT/partial.plist" \
       --app-icon AppIcon --include-all-app-icons \
       --enable-on-demand-resources NO --development-region en \
       --target-device mac --platform macosx --minimum-deployment-target 14.0 \
     && [[ -f "$ICON_OUT/Assets.car" ]]; then
    cp "$ICON_OUT/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP_DIR/Contents/Info.plist"
    echo "  иконка macOS 26 собрана ($(basename "$XCODE26"))"
  else
    echo "  ⚠︎ actool не справился — остаётся классическая иконка"
  fi
else
  echo "  Xcode 26 не найден — только классическая иконка"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "▸ Подпись (ad-hoc)"
else
  echo "▸ Подпись: $SIGN_IDENTITY"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --verbose "$APP_DIR"

echo "▸ Архивы"
ditto -c -k --keepParent "$APP_DIR" "$OUT_DIR/Halo.zip"

echo "▸ Установщик (DMG)"
DMG="$OUT_DIR/Halo.dmg"
DMG_STAGE="$(mktemp -d)"
cp -R "$APP_DIR" "$DMG_STAGE/"
DMG_BACKGROUND="$(mktemp -d)/background.tiff"
tiffutil -cathidpicheck Resources/DMG/background.png Resources/DMG/background@2x.png -out "$DMG_BACKGROUND" >/dev/null

# Красивое окно: фон со стрелкой, Halo слева, «Программы» справа. Нужен create-dmg (brew install create-dmg).
# Если его нет или Finder не ответил — обычный DMG с теми же файлами.
pretty_dmg() {
  command -v create-dmg >/dev/null || return 1
  rm -f "$DMG"
  create-dmg \
    --volname "$APP_NAME" \
    --volicon "$APP_DIR/Contents/Resources/AppIcon.icns" \
    --background "$DMG_BACKGROUND" \
    --window-pos 200 140 \
    --window-size 660 400 \
    --icon-size 128 \
    --text-size 13 \
    --icon "$APP_NAME.app" 170 190 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 490 190 \
    "$DMG" "$DMG_STAGE"
}
if ! pretty_dmg; then
  echo "  ⚠︎ create-dmg недоступен — простой DMG"
  rm -f "$DMG"
  ln -s /Applications "$DMG_STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
fi

echo "✓ Готово: $APP_DIR"
echo "  $OUT_DIR/Halo.dmg"
