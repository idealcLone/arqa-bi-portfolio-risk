#!/usr/bin/env python3
"""
Сверка ДАШБОРДА с ИСХОДНЫМИ CSV напрямую, без БД в качестве посредника.

Зачем отдельно от independent_recompute.py: тот сверяет CSV с вьюхами в Postgres.
Но на дашборде лежат не вьюхи, а выгруженные JSON-файлы, и между вьюхой и файлом
есть ещё один шаг (скрипт выгрузки), на котором можно потерять строку, перепутать
колонку или выгрузить устаревший снимок. Здесь цепочка замыкается:

    data/*.csv  →  (пересчёт по определениям)  →  сравнение с dashboard/data/*.json

Проверяются ВСЕ файлы дашборда и все их числовые поля, включая производные доли
(share_of_portfolio, par30_share, par90_share, npl_share, provision_coverage).

Сравнение точное, в Decimal: JSON читается с parse_float=Decimal, иначе доли
теряют точность на 17-м знаке и проверка начинает врать (так и было, см. docs/ai_log.md).

Запуск:
    python3 checks/dashboard_vs_csv.py                      # локальные файлы dashboard/data
    python3 checks/dashboard_vs_csv.py --url https://...    # то, что реально отдаёт прод
"""
import argparse
import json
import os
import sys
import urllib.request
from decimal import Decimal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from independent_recompute import compute  # noqa: E402  — пересчёт из CSV, общий с проверкой SQL

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCAL_DIR = os.path.join(ROOT, "dashboard", "data")
FILES = ["metrics.json", "by_sector.json", "by_program.json", "top_groups.json", "by_dpd_bucket.json"]

failures = []


def load(name, base_url):
    if base_url:
        url = base_url.rstrip("/") + "/data/" + name
        with urllib.request.urlopen(url, timeout=30) as resp:
            if resp.status != 200:
                sys.exit(f"{url}: HTTP {resp.status}")
            raw = resp.read().decode("utf-8")
    else:
        raw = open(os.path.join(LOCAL_DIR, name), encoding="utf-8").read()
    return json.loads(raw, parse_float=Decimal)


# Деньги и счётчики сверяются ТОЧНО: это numeric(…, 2) и целые, расхождений быть не может.
# Доли — отношение двух numeric: Postgres возвращает ~20 значащих цифр, Python Decimal
# по умолчанию считает с 28, поэтому хвост за 20-м знаком различается всегда и ни о чём
# не говорит. Допуск 1e-18 строже любой бизнес-значимости (0,0000000000000001% портфеля)
# и при этом не ловит разницу представления.
SHARE_TOL = Decimal("1e-18")


def check(label, expected, actual, kind="exact"):
    """Ожидаемое — пересчёт из CSV, фактическое — значение из файла дашборда."""
    exp, act = Decimal(expected), Decimal(actual)
    if kind == "share":
        if abs(exp - act) > SHARE_TOL:
            failures.append(f"{label}: CSV={exp} дашборд={act} разница={act - exp}")
            return False
        return True
    if exp != act:
        failures.append(f"{label}: CSV={exp} дашборд={act} разница={act - exp}")
        return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", help="базовый URL дашборда (по умолчанию — локальные файлы)")
    args = ap.parse_args()
    where = args.url or "dashboard/data/*.json (локально)"

    print("=" * 78)
    print("СВЕРКА ДАШБОРДА С ИСХОДНЫМИ CSV (без БД)")
    print(f"источник истины: data/portfolio.csv + data/fx.csv")
    print(f"проверяется:     {where}")
    print("=" * 78)

    csv_totals, csv_sectors, csv_programs, csv_buckets = compute()
    ok_count = 0

    # ---------------------------------------------------------------- metrics.json
    metrics = {r["report_date"]: r for r in load("metrics.json", args.url)}
    if set(metrics) != set(csv_totals):
        failures.append(f"даты: CSV={sorted(csv_totals)} дашборд={sorted(metrics)}")
    for date in sorted(csv_totals):
        exp, got = csv_totals[date], metrics[date]
        pairs = [
            ("portfolio_kzt", exp["portfolio_kzt"]), ("par30_kzt", exp["par30_kzt"]),
            ("par90_kzt", exp["par90_kzt"]), ("npl_kzt", exp["npl_kzt"]),
            ("provisions_kzt", exp["provisions_kzt"]), ("loan_count", Decimal(exp["loan_count"])),
            ("par30_share", exp["par30_share"]), ("par90_share", exp["par90_share"]),
            ("npl_share", exp["npl_share"]),
            ("top10_exposure_kzt", exp["top10_exposure_kzt"]),
            ("top10_group_share", exp["top10_group_share"]),
            ("written_off_count", Decimal(exp["written_off_count"])),
            ("provision_coverage", exp["provisions_kzt"] / exp["portfolio_kzt"]),
        ]
        for field, expected in pairs:
            kind = "share" if field.endswith(("_share", "_coverage")) else "exact"
            ok_count += check(f"metrics.json {date} {field}", expected, got[field], kind)
        print(f"  [{'OK ' if not failures else '…'}] metrics.json {date}: {len(pairs)} полей")

    # ------------------------------------------------- by_sector.json / by_program.json
    for name, csv_dim, key in (("by_sector.json", csv_sectors, "sector"),
                               ("by_program.json", csv_programs, "program")):
        rows = load(name, args.url)
        seen = set()
        for r in rows:
            k = (r["report_date"], r[key])
            seen.add(k)
            if k not in csv_dim:
                failures.append(f"{name}: {k} есть на дашборде, нет в CSV")
                continue
            e = csv_dim[k]
            total = csv_totals[r["report_date"]]["portfolio_kzt"]
            for field, expected in (
                ("portfolio_kzt", e["portfolio"]), ("par30_kzt", e["par30"]),
                ("par90_kzt", e["par90"]), ("npl_kzt", e["npl"]),
                ("provisions_kzt", e["provisions"]), ("loan_count", e["loan_count"]),
                ("share_of_portfolio", e["portfolio"] / total),
                ("par30_share", e["par30"] / e["portfolio"]),
                ("par90_share", e["par90"] / e["portfolio"]),
                ("npl_share", e["npl"] / e["portfolio"]),
                ("provision_coverage", e["provisions"] / e["portfolio"]),
            ):
                kind = "share" if field.endswith(("_share", "_coverage", "_portfolio")) else "exact"
                ok_count += check(f"{name} {k} {field}", expected, r[field], kind)
        for k in csv_dim:
            if k not in seen:
                failures.append(f"{name}: {k} есть в CSV, нет на дашборде")
        print(f"  [{'OK ' if not failures else '…'}] {name}: {len(rows)} строк сверено построчно")

    # ---------------------------------------------------------- by_dpd_bucket.json
    rows = load("by_dpd_bucket.json", args.url)
    seen = set()
    for r in rows:
        k = (r["report_date"], r["dpd_bucket"])
        seen.add(k)
        if k not in csv_buckets:
            failures.append(f"by_dpd_bucket.json: {k} есть на дашборде, нет в CSV")
            continue
        e = csv_buckets[k]
        total = csv_totals[r["report_date"]]["portfolio_kzt"]
        for field, expected in (
            ("portfolio_kzt", e["portfolio"]), ("npl_kzt", e["npl"]),
            ("provisions_kzt", e["provisions"]), ("loan_count", e["loan_count"]),
            ("share_of_portfolio", e["portfolio"] / total),
        ):
            kind = "share" if field.endswith("_portfolio") else "exact"
            ok_count += check(f"by_dpd_bucket.json {k} {field}", expected, r[field], kind)
    for k in csv_buckets:
        if k not in seen:
            failures.append(f"by_dpd_bucket.json: {k} есть в CSV, нет на дашборде")
    print(f"  [{'OK ' if not failures else '…'}] by_dpd_bucket.json: {len(rows)} строк сверено построчно")

    # -------------------------------------------------------------- top_groups.json
    rows = load("top_groups.json", args.url)
    by_date = {}
    for r in rows:
        by_date.setdefault(r["report_date"], []).append(r)
    for date, got in sorted(by_date.items()):
        got.sort(key=lambda r: r["exposure_rank"])
        expected = csv_totals[date]["top10_groups"]
        if [g for g, _ in expected] != [r["group_id"] for r in got]:
            failures.append(f"top_groups.json {date}: состав/порядок топ-10 не совпал "
                            f"CSV={[g for g, _ in expected]} дашборд={[r['group_id'] for r in got]}")
            continue
        total = csv_totals[date]["portfolio_kzt"]
        for (g, exposure), r in zip(expected, got):
            ok_count += check(f"top_groups.json {date} {g} exposure_kzt", exposure, r["exposure_kzt"])
            ok_count += check(f"top_groups.json {date} {g} share_of_portfolio",
                              exposure / total, r["share_of_portfolio"], "share")
        print(f"  [{'OK ' if not failures else '…'}] top_groups.json {date}: 10 групп, состав и доли сверены")

    # ------------------------------------------------------------------- итог
    print("=" * 78)
    if failures:
        print(f"ДАШБОРД РАСХОДИТСЯ С CSV — расхождений: {len(failures)}")
        for f in failures[:40]:
            print("  ! " + f)
        print("=" * 78)
        sys.exit(1)
    print(f"ДАШБОРД СОВПАДАЕТ С CSV: сверено {ok_count} значений, расхождений 0")
    print("источник → дашборд проверен напрямую, без БД в качестве посредника")
    print("=" * 78)


if __name__ == "__main__":
    main()
