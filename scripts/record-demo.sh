#!/usr/bin/env bash
# Записывает видео демо-режима Cool Notch (для CI). Результат — в папке preview/.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="preview"
mkdir -p "$OUT"
APP=".build/app/Cool Notch.app/Contents/MacOS/CoolNotch"
DURATION=62

# Информация об экране — пригодится, чтобы поднять разрешение записи.
(displayplacer list 2>/dev/null | head -60) > "$OUT/displays.txt" || true
system_profiler SPDisplaysDataType >> "$OUT/displays.txt" 2>/dev/null || true

# Поднимаем разрешение виртуального экрана (Retina-режимов у раннера нет, поэтому приложение
# в демо само рисует всё в двойном масштабе).
SCREEN_ID=$(displayplacer list 2>/dev/null | awk '/Persistent screen id:/ {print $4; exit}')
if [[ -n "${SCREEN_ID:-}" ]]; then
  displayplacer "id:$SCREEN_ID res:1920x1080 hz:60 color_depth:7 enabled:true scaling:off origin:(0,0) degree:0" || true
  sleep 2
fi

"$APP" --demo > "$OUT/app.log" 2>&1 &
APP_PID=$!
sleep 1.5

screencapture -x "$OUT/check.png" || true
screencapture -v -V "$DURATION" -x "$OUT/raw.mov" &
REC_PID=$!

wait "$REC_PID" || true
kill "$APP_PID" 2>/dev/null || true

cat "$OUT/app.log" || true
ls -la "$OUT"

WINDOW_LINE=$(grep -m1 '^DEMO_WINDOW' "$OUT/app.log" || true)
read -r _ WX WY WW WH SCALE SW SH <<<"$WINDOW_LINE"
echo "window: x=$WX y=$WY w=$WW h=$WH scale=$SCALE screen=${SW}x${SH}"

if [[ ! -s "$OUT/raw.mov" ]]; then
  echo "Видео не записалось" >&2
  exit 1
fi

# Размер кадра в пикселях берём из самого видео (на случай Retina).
VW=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$OUT/raw.mov")
K=$(python3 -c "print($VW / $SW)")
CROP=$(python3 -c "
k=$K; w=int($WW*k)//2*2; h=int($WH*300/360*k)//2*2; x=int(($WX)*k); y=int(($WY)*k)
print(f'{w}:{h}:{x}:{y}')")
echo "crop=$CROP"

ffmpeg -y -loglevel error -i "$OUT/raw.mov" \
  -vf "crop=$CROP,fps=60" \
  -c:v libx264 -pix_fmt yuv420p -crf 18 -preset slow -movflags +faststart \
  "$OUT/cool-notch-demo.mp4"

# Отдельные кадры ключевых моментов.
for t in 4 7 10 13 16 18 21 23 25 27 30 33 36 40 44 49 54; do
  ffmpeg -y -loglevel error -ss "$t" -i "$OUT/cool-notch-demo.mp4" -frames:v 1 "$OUT/frame-$(printf '%02d' "$t")s.png"
done

rm -f "$OUT/raw.mov"

# Окно первого запуска (разрешения) — отдельным снимком.
"$APP" --onboarding > "$OUT/onboarding.log" 2>&1 &
ONB_PID=$!
sleep 4
screencapture -x "$OUT/onboarding.png" || true
kill "$ONB_PID" 2>/dev/null || true
ls -la "$OUT"
