#!/usr/bin/env bash
# Собирает иконку в формате macOS 26 (светлая, тёмная, прозрачная, тонированная) из документа
# Icon Composer Resources/AppIcon.icon в Assets.car.
# Использование: ./scripts/build-icon.sh <папка для Assets.car>
# Нужны Xcode 26 и macOS 26: на более старой системе actool падает при отрисовке иконки.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:?укажи папку для Assets.car}"
mkdir -p "$OUT"

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

XCODE26="$(find_xcode26)" || { echo "Xcode 26 не найден" >&2; exit 1; }
echo "▸ Иконка macOS 26: $(basename "$XCODE26"), macOS $(sw_vers -productVersion)"
DEVELOPER_DIR="$XCODE26/Contents/Developer" xcrun actool Resources/AppIcon.icon \
  --compile "$OUT" \
  --output-format human-readable-text --warnings --errors \
  --output-partial-info-plist "$OUT/partial.plist" \
  --app-icon AppIcon --include-all-app-icons \
  --enable-on-demand-resources NO --development-region en \
  --target-device mac --platform macosx --minimum-deployment-target 14.0
[[ -f "$OUT/Assets.car" ]] || { echo "actool не создал Assets.car" >&2; exit 1; }
DEVELOPER_DIR="$XCODE26/Contents/Developer" xcrun assetutil --info "$OUT/Assets.car" | grep -E '"(Name|RenditionName|Appearance)"' | sort | uniq -c || true
echo "✓ $OUT/Assets.car"
