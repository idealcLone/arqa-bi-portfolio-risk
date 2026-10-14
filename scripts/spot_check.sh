#!/usr/bin/env bash
# Сквозная сверка отдельных кредитов: сырая строка → строка витрины → вклад в метрики.
# Кредиты выбираются по ХАРАКТЕРИСТИКАМ (дубль, USD, реструктуризация, списание, бакет 31–90),
# а не по жёстко вбитым id — чтобы проверка оставалась осмысленной при смене данных.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/load_env.sh
psql -X -q -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f checks/07_spot_checks.sql
