#!/usr/bin/env bash
# Единая точка входа: БД → схемы → загрузка CSV → вьюхи → проверки → выгрузка JSON для дашборда.
# Идемпотентно: повторный запуск проходит без ошибок и даёт идентичный результат.
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
export PGPASSWORD="$POSTGRES_PASSWORD"
. ./scripts/python_env.sh      # определяет $PY (python3 с pyyaml)
PSQL=(psql -v ON_ERROR_STOP=1 -q -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB")

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "1/8 Поднимаю PostgreSQL 16 (docker compose)"
docker compose up -d --wait

step "2/8 Схема raw"
"${PSQL[@]}" -f sql/raw/00_schema.sql

step "3/8 Загрузка CSV (TRUNCATE + \\copy в транзакции)"
"${PSQL[@]}" -f sql/raw/01_load.sql

step "4/8 Вьюхи reporting (CREATE OR REPLACE)"
for f in sql/reporting/*.sql; do
  echo "    $f"
  "${PSQL[@]}" -f "$f"
done

step "5/8 Проверки (падают громко при расхождении)"
for f in checks/*.sql; do
  echo "    $f"
  "${PSQL[@]}" -f "$f"
done
echo "    checks/independent_recompute.py (независимый пересчёт из CSV)"
"$PY" checks/independent_recompute.py

step "6/8 Валидация семантической модели против витрины"
"$PY" scripts/validate_semantic.py

step "7/8 Выгрузка данных дашборда из вьюх"
./scripts/export_dashboard_data.sh

step "8/8 Подстановка актуальных цифр в README"
"$PY" scripts/render_readme.py

printf '\n\033[1;32mГотово.\033[0m Дашборд: cd dashboard && python3 -m http.server 8000\n'
