#!/usr/bin/env bash
# Проверка идемпотентности: пайплайн прогоняется дважды, и выгрузка дашборда
# обязана совпасть байт в байт. Падает, если второй прогон что-то изменил.
set -euo pipefail
cd "$(dirname "$0")/.."

SNAP=$(mktemp -d)
cp dashboard/data/*.json "$SNAP"/ 2>/dev/null || true

echo "--- Прогон пайплайна №1 ---"
./run.sh >/dev/null
mkdir -p "$SNAP/run1" && cp dashboard/data/*.json "$SNAP/run1"/

echo "--- Прогон пайплайна №2 (тот же вход, те же команды) ---"
./run.sh >/dev/null
mkdir -p "$SNAP/run2" && cp dashboard/data/*.json "$SNAP/run2"/

if diff -r "$SNAP/run1" "$SNAP/run2" >/dev/null; then
  echo "ИДЕМПОТЕНТНО: выгрузки после двух полных прогонов идентичны"
  for f in "$SNAP/run1"/*.json; do
    printf '  %-22s sha256 %s\n' "$(basename "$f")" "$(shasum -a 256 "$f" | cut -c1-16)"
  done
else
  echo "НЕ ИДЕМПОТЕНТНО: второй прогон изменил выгрузку" >&2
  diff -r "$SNAP/run1" "$SNAP/run2" >&2
  exit 1
fi
