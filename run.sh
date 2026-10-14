#!/usr/bin/env bash
# Единая точка входа: БД → схемы → загрузка CSV → вьюхи → проверки → выгрузка JSON для дашборда.
# Идемпотентно: повторный запуск проходит без ошибок и даёт идентичный результат.
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
export PGPASSWORD="$POSTGRES_PASSWORD"
PSQL=(psql -v ON_ERROR_STOP=1 -q -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB")

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "1/6 Поднимаю PostgreSQL 16 (docker compose)"
docker compose up -d --wait

step "2/6 Схема raw"
"${PSQL[@]}" -f sql/raw/00_schema.sql

step "3/6 Загрузка CSV (TRUNCATE + \\copy в транзакции)"
"${PSQL[@]}" -f sql/raw/01_load.sql

step "4/6 Вьюхи reporting (CREATE OR REPLACE)"
for f in sql/reporting/*.sql; do
  echo "    $f"
  "${PSQL[@]}" -f "$f"
done

step "5/6 Проверки (падают громко при расхождении)"
for f in checks/*.sql; do
  echo "    $f"
  "${PSQL[@]}" -f "$f"
done
echo "    checks/independent_recompute.py (независимый пересчёт из CSV)"
python3 checks/independent_recompute.py

step "6/6 Выгрузка данных дашборда из вьюх"
./scripts/export_dashboard_data.sh

printf '\n\033[1;32mГотово.\033[0m Дашборд: cd dashboard && python3 -m http.server 8000\n'
