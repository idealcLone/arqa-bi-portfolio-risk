#!/usr/bin/env bash
# Скриншот дашборда в docs/dashboard.png через headless Chrome.
# Страница открывается как file:// с --allow-file-access-from-files, чтобы fetch
# локальных JSON работал без поднятия сервера. Падает, если в консоли есть ошибки
# или если графики не отрисовались (маркер document.body.dataset.rendered).
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$CHROME" ]; then
  for c in "$(command -v google-chrome || true)" "$(command -v chromium || true)" "$(command -v chromium-browser || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && CHROME="$c" && break
  done
fi
if [ ! -x "$CHROME" ]; then
  echo "Не найден Chrome/Chromium. Укажи путь в CHROME_BIN." >&2; exit 1
fi

URL="file://$PWD/dashboard/index.html"
LOG="$(mktemp)"
mkdir -p docs

"$CHROME" --headless=new --disable-gpu --no-sandbox --allow-file-access-from-files \
  --enable-logging=stderr --v=0 --virtual-time-budget=15000 \
  --window-size=1400,2900 --screenshot="docs/dashboard.png" "$URL" 2>"$LOG" >/dev/null

ERRORS=$(grep -c 'CONSOLE.*ERROR' "$LOG" || true)
WARNS=$(grep -c 'CONSOLE.*WARN' "$LOG" || true)
if [ "$ERRORS" != "0" ]; then
  echo "В консоли дашборда есть ошибки:" >&2
  grep 'CONSOLE' "$LOG" | sed 's/.*CONSOLE:[0-9]*\] //' >&2
  exit 1
fi

# Контроль: страница действительно дорисовала графики, а не отдала пустые карточки
DOM="$(mktemp)"
"$CHROME" --headless=new --disable-gpu --no-sandbox --allow-file-access-from-files \
  --virtual-time-budget=15000 --dump-dom "$URL" 2>/dev/null > "$DOM"
if ! grep -q 'data-rendered="true"' "$DOM"; then
  echo "Дашборд не отрисовался (нет маркера data-rendered)" >&2; exit 1
fi
CANVAS=$(grep -o '<canvas' "$DOM" | wc -l | tr -d ' ')
if [ "$CANVAS" -lt 8 ]; then
  echo "Отрисовано только $CANVAS графиков из 8" >&2; exit 1
fi

echo "docs/dashboard.png сохранён ($(du -h docs/dashboard.png | cut -f1)); графиков: $CANVAS, ошибок в консоли: $ERRORS, предупреждений: $WARNS"
