#!/usr/bin/env python3
"""
Валидация семантической модели против БД: модель — это конфиг, и он не должен
разъезжаться с витриной. Падает, если:
  - source-вьюхи нет в БД;
  - колонка измерения/меры отсутствует в источнике;
  - тип меры не из {sum, avg, count};
  - мера типа sum/avg стоит на нечисловой колонке;
  - у dimension/measure нет label (дашборд подписывается из модели).
Дополнительно сверяет, что меры, посчитанные ЧЕРЕЗ МОДЕЛЬ, совпадают с v_portfolio_metrics.
"""
import os
import subprocess
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_PATH = os.path.join(ROOT, "semantic", "portfolio.yml")
ALLOWED_TYPES = {"sum", "avg", "count"}
NUMERIC_TYPES = {"numeric", "integer", "bigint", "smallint", "double precision", "real"}


def psql(query):
    env = dict(os.environ)
    env.setdefault("PGPASSWORD", env.get("POSTGRES_PASSWORD", ""))
    cmd = ["psql", "-X", "-q", "-A", "-t", "-F", "\t", "-v", "ON_ERROR_STOP=1",
           "-h", env.get("POSTGRES_HOST", "localhost"), "-p", env.get("POSTGRES_PORT", "55432"),
           "-U", env.get("POSTGRES_USER", "arqa"), "-d", env.get("POSTGRES_DB", "arqa"), "-c", query]
    out = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if out.returncode != 0:
        sys.exit("psql: " + out.stderr.strip())
    return [l.split("\t") for l in out.stdout.strip().split("\n") if l.strip()]


def main():
    model = yaml.safe_load(open(MODEL_PATH, encoding="utf-8"))
    errors = []

    source = model.get("source", "")
    if "." not in source:
        sys.exit(f"source должен быть вида schema.view, получено: {source!r}")
    schema, view = source.split(".", 1)

    rows = psql(f"""
        select column_name, data_type
        from information_schema.columns
        where table_schema = '{schema}' and table_name = '{view}'
    """)
    if not rows:
        sys.exit(f"Источник {source} не найден в БД — подними пайплайн (make all)")
    columns = {r[0]: r[1] for r in rows}

    for kind in ("dimensions", "measures"):
        for item in model.get(kind, []):
            name, col = item.get("name"), item.get("column")
            if not item.get("label"):
                errors.append(f"{kind}.{name}: нет label")
            if col not in columns:
                errors.append(f"{kind}.{name}: колонки {col!r} нет в {source}")
                continue
            if kind == "measures":
                mtype = item.get("type")
                if mtype not in ALLOWED_TYPES:
                    errors.append(f"measures.{name}: тип {mtype!r} вне {sorted(ALLOWED_TYPES)}")
                elif mtype in ("sum", "avg") and columns[col] not in NUMERIC_TYPES:
                    errors.append(f"measures.{name}: {mtype} по нечисловой колонке {col} ({columns[col]})")
                if not item.get("format"):
                    errors.append(f"measures.{name}: нет format")

    if errors:
        print("ОШИБКИ СЕМАНТИЧЕСКОЙ МОДЕЛИ:")
        for e in errors:
            print("  ! " + e)
        sys.exit(1)

    # Меры, собранные по модели, обязаны совпасть с готовой вьюхой метрик.
    by_name = {m["name"]: m for m in model["measures"]}
    pairs = [("portfolio_kzt", "portfolio_kzt"), ("par30_kzt", "par30_kzt"),
             ("par90_kzt", "par90_kzt"), ("npl_kzt", "npl_kzt"),
             ("provisions_kzt", "provisions_kzt"), ("loan_count", "loan_count")]
    select_parts = ", ".join(
        f"{by_name[m]['type']}({by_name[m]['column']}) as {m}" for m, _ in pairs)
    model_rows = psql(f"select report_date::text, {select_parts} from {source} group by report_date order by report_date")
    view_cols = ", ".join(v for _, v in pairs)
    view_rows = psql(f"select report_date::text, {view_cols} from reporting.v_portfolio_metrics order by report_date")

    print(f"Семантическая модель {model['model']} над {source}: "
          f"{len(model['dimensions'])} измерений, {len(model['measures'])} мер — структура валидна")
    bad = 0
    for mrow, vrow in zip(model_rows, view_rows):
        for i, (mname, vname) in enumerate(pairs, start=1):
            mv, vv = mrow[i].strip(), vrow[i].strip()
            if float(mv) != float(vv):
                print(f"  ! {mrow[0]} {mname}: по модели {mv} <> по вьюхе {vv}")
                bad += 1
        print(f"  [OK ] {mrow[0]}: меры по модели совпали с reporting.v_portfolio_metrics "
              f"({', '.join(m for m, _ in pairs)})")
    if bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
