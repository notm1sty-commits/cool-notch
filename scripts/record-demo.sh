#!/usr/bin/env bash
# Записывает видео демо-режима Cool Notch (для CI). Результат — в папке preview/.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="preview"
mkdir -p "$OUT"
APP=".build/app/Cool Notch.app/Contents/MacOS/CoolNotch"
DURATION=40

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
k=$K; w=int($WW*k)//2*2; h=int(300*k)//2*2; x=int(($WX)*k); y=int(($WY)*k)
print(f'{w}:{h}:{x}:{y}')")
echo "crop=$CROP"

ffmpeg -y -loglevel error -i "$OUT/raw.mov" \
  -vf "crop=$CROP,scale='min(1640,iw)':-2:flags=lanczos,fps=60" \
  -c:v libx264 -pix_fmt yuv420p -crf 18 -preset slow -movflags +faststart \
  "$OUT/cool-notch-demo.mp4"

# Отдельные кадры ключевых моментов.
for t in 2 5 9 12 14 16 18 20 22 25 29 33; do
  ffmpeg -y -loglevel error -ss "$t" -i "$OUT/cool-notch-demo.mp4" -frames:v 1 "$OUT/frame-$(printf '%02d' "$t")s.png"
done

rm -f "$OUT/raw.mov"
ls -la "$OUT"
