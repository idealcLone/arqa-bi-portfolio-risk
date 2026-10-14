.DEFAULT_GOAL := help
SHELL := /bin/bash

help:  ## список целей
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

all: ## полный пайплайн: БД → raw → вьюхи → проверки → выгрузка JSON
	./run.sh

profile: ## профилирование сырых CSV (аномалии)
	. ./scripts/python_env.sh; "$$PY" scripts/profile_data.py

checks: ## только проверки (БД должна быть поднята)
	set -a; . ./.env; set +a; export PGPASSWORD=$$POSTGRES_PASSWORD; \
	for f in checks/*.sql; do echo "==> $$f"; psql -v ON_ERROR_STOP=1 -q -h $$POSTGRES_HOST -p $$POSTGRES_PORT -U $$POSTGRES_USER -d $$POSTGRES_DB -f $$f; done; \
	. ./scripts/python_env.sh; "$$PY" checks/independent_recompute.py

metrics: ## показать v_portfolio_metrics
	set -a; . ./.env; set +a; export PGPASSWORD=$$POSTGRES_PASSWORD; \
	psql -h $$POSTGRES_HOST -p $$POSTGRES_PORT -U $$POSTGRES_USER -d $$POSTGRES_DB -x -c "select * from reporting.v_portfolio_metrics"

serve: ## локальный просмотр дашборда
	cd dashboard && python3 -m http.server 8000

screenshot: ## скриншот дашборда в docs/dashboard.png
	./scripts/screenshot.sh

down: ## остановить и удалить БД
	docker compose down -v

.PHONY: help all profile checks metrics serve screenshot down
