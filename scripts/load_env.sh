# Подключается через `source`. Загружает .env, НЕ затирая переменные, которые уже заданы
# в окружении. Это важно для CI: там параметры подключения приходят из workflow,
# и слепой `. ./.env` подменял бы их значениями из .env.example (поймано CI: см. docs/ai_log.md).
load_env() {
  [ -f .env ] || cp .env.example .env
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    [ -n "$key" ] || continue
    # уже задано снаружи (CI, экспорт в шелле) — не трогаем
    if [ -z "${!key:-}" ]; then
      export "$key=$value"
    fi
  done < .env
  export PGPASSWORD="$POSTGRES_PASSWORD"
}
load_env
