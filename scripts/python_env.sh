# Подключается через `source`. Определяет PY — интерпретатор python3, в котором есть pyyaml
# (нужен только для валидации семантической модели; независимый пересчёт работает на stdlib).
# Если такого нет — поднимает локальный .venv и ставит туда pyyaml.
pick_python() {
  local cand
  for cand in "${PYTHON:-}" python3 python3.12 python3.11 /usr/bin/python3; do
    [ -n "$cand" ] || continue
    command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -c "import yaml" >/dev/null 2>&1; then echo "$cand"; return 0; fi
  done
  # pyyaml нигде нет — ставим в локальное окружение проекта
  local venv=".venv"
  if [ ! -x "$venv/bin/python" ]; then
    echo "    pyyaml не найден — создаю $venv" >&2
    python3 -m venv "$venv" >&2
  fi
  "$venv/bin/python" -c "import yaml" >/dev/null 2>&1 || "$venv/bin/pip" install -q pyyaml >&2
  echo "$venv/bin/python"
}
PY="$(pick_python)"
