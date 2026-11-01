#!/usr/bin/env bash
# Только для CI (GitHub-раннер macOS, SIP выключен): разрешаем запись экрана,
# чтобы снять видео демо-режима. На обычном Маке этот скрипт не нужен и не запускается.
set -uo pipefail

if [[ "${CI:-}" != "true" ]]; then
  echo "Скрипт предназначен только для CI" >&2
  exit 1
fi

NOW=$(date +%s)
CLIENTS=(/usr/sbin/screencapture /bin/bash /bin/zsh /bin/sh)
while IFS= read -r path; do
  [[ -n "$path" ]] && CLIENTS+=("$path")
done < <(ps -axo comm= | grep -Ei 'provisioner|Runner\.(Worker|Listener)' | sort -u)

for DB in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
  [[ -f "$DB" ]] || continue
  for client in "${CLIENTS[@]}"; do
    sudo sqlite3 "$DB" "INSERT OR REPLACE INTO access VALUES('kTCCServiceScreenCapture','$client',1,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,$NOW,NULL,NULL,'UNUSED',0);" \
      && echo "granted: $client ($DB)" || echo "skip: $client ($DB)"
  done
done
