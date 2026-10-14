#!/usr/bin/env bash
# Единая точка входа: БД → схемы → загрузка CSV → вьюхи → проверки → выгрузка JSON для дашборда.
# Идемпотентно: повторный запуск проходит без ошибок и даёт идентичный результат.
set -euo pipefail
cd "$(dirname "$0")"

. ./scripts/load_env.sh        # .env, не затирая переменные окружения (важно для CI)
. ./scripts/python_env.sh      # определяет $PY (python3 с pyyaml)
PSQL=(psql -v ON_ERROR_STOP=1 -q -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB")

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "1/9 Поднимаю PostgreSQL 16 (docker compose)"
docker compose up -d --wait

step "2/9 Схема raw"
"${PSQL[@]}" -f sql/raw/00_schema.sql

step "3/9 Загрузка CSV (TRUNCATE + \\copy в транзакции)"
"${PSQL[@]}" -f sql/raw/01_load.sql

step "4/9 Вьюхи reporting (CREATE OR REPLACE)"
for f in sql/reporting/*.sql; do
  echo "    $f"
  "${PSQL[@]}" -f "$f"
done

step "5/9 Проверки (падают громко при расхождении)"
for f in checks/*.sql; do
  echo "    $f"
  "${PSQL[@]}" -f "$f"
done
echo "    checks/independent_recompute.py (независимый пересчёт из CSV)"
"$PY" checks/independent_recompute.py

step "6/9 Валидация семантической модели против витрины"
"$PY" scripts/validate_semantic.py

step "7/9 Выгрузка данных дашборда из вьюх"
./scripts/export_dashboard_data.sh

step "8/9 Сверка выгрузки дашборда с исходными CSV (без БД в цепочке)"
"$PY" checks/dashboard_vs_csv.py

step "9/9 Подстановка актуальных цифр в README"
"$PY" scripts/render_readme.py

printf '\n\033[1;32mГотово.\033[0m Дашборд: cd dashboard && python3 -m http.server 8000\n'
