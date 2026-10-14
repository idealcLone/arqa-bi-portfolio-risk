#!/usr/bin/env python3
"""
Независимый пересчёт метрик портфеля ПРЯМО из сырых CSV, без SQL-логики.

Написан от определений задания, а не переводом вьюх:
  портфель       = Σ principal_outstanding × курс на дату среза, без written_off = 1
  PAR30 / PAR90  = доля портфеля с dpd > 30 / dpd > 90
  NPL            = доля портфеля с dpd > 90 ИЛИ restructured = 1
  провизии       = остаток × (50% если NPL, иначе 10% при 31–90, иначе 1%)
  концентрация   = доля 10 крупнейших group_id в портфеле

Затем результат сравнивается с reporting.v_portfolio_metrics / v_metrics_by_sector /
v_metrics_by_program / v_top_groups. Любое расхождение больше допуска → exit code 1.

Зависимости: только стандартная библиотека + psql в PATH.
Единственное техническое соглашение, общее с SQL (не бизнес-логика):
округление денег до копейки на уровне строки, half-up, затем суммирование.
"""
import csv
import os
import subprocess
import sys
from collections import defaultdict
from decimal import Decimal, ROUND_HALF_UP

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORTFOLIO_CSV = os.path.join(ROOT, "data", "portfolio.csv")
FX_CSV = os.path.join(ROOT, "data", "fx.csv")

AMOUNT_TOL = Decimal("0.01")      # копейка
SHARE_TOL = Decimal("0.000000001")  # 1e-9 доли
TOP_N = 10

failures = []


def money(x: Decimal) -> Decimal:
    return x.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


# ---------------------------------------------------------------- сырые данные
def read_fx():
    rates = {}
    with open(FX_CSV, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            rates[(row["date"].strip(), row["currency"].strip().upper())] = Decimal(row["rate_kzt"].strip())
    return rates


def read_portfolio():
    """Дедупликация: один (report_date, loan_id) — первое вхождение."""
    seen = set()
    rows = []
    with open(PORTFOLIO_CSV, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            key = (row["report_date"].strip(), row["loan_id"].strip())
            if key in seen:
                continue
            seen.add(key)
            rows.append(row)
    return rows


def compute():
    rates = read_fx()
    rows = read_portfolio()

    totals = defaultdict(lambda: defaultdict(Decimal))
    counts = defaultdict(int)
    groups = defaultdict(lambda: defaultdict(Decimal))
    sectors = defaultdict(lambda: defaultdict(Decimal))
    programs = defaultdict(lambda: defaultdict(Decimal))

    for row in rows:
        date = row["report_date"].strip()
        currency = row["currency"].strip().upper()
        dpd = int(row["days_past_due"].strip())
        restructured = row["restructured"].strip() == "1"
        written_off = row["written_off"].strip() == "1"

        if written_off:                      # списанные не входят в портфель
            totals[date]["written_off_count"] += 1
            continue

        rate = Decimal(1) if currency == "KZT" else rates.get((date, currency))
        if rate is None:
            failures.append(f"нет курса {currency} на {date} (кредит {row['loan_id']})")
            continue

        kzt = money(Decimal(row["principal_outstanding"].strip()) * rate)

        is_par30 = dpd > 30
        is_par90 = dpd > 90
        is_npl = dpd > 90 or restructured

        if is_npl:
            prov_rate = Decimal("0.50")
        elif 31 <= dpd <= 90:
            prov_rate = Decimal("0.10")
        else:
            prov_rate = Decimal("0.01")
        prov = money(kzt * prov_rate)

        t = totals[date]
        t["portfolio"] += kzt
        t["par30"] += kzt if is_par30 else Decimal(0)
        t["par90"] += kzt if is_par90 else Decimal(0)
        t["npl"] += kzt if is_npl else Decimal(0)
        t["provisions"] += prov
        counts[date] += 1

        groups[date][row["group_id"].strip()] += kzt
        for store, key in ((sectors, row["sector"].strip()), (programs, row["program"].strip())):
            d = store[(date, key)]
            d["portfolio"] += kzt
            d["par30"] += kzt if is_par30 else Decimal(0)
            d["par90"] += kzt if is_par90 else Decimal(0)
            d["npl"] += kzt if is_npl else Decimal(0)
            d["provisions"] += prov

    result = {}
    for date, t in totals.items():
        top = sorted(groups[date].items(), key=lambda kv: (-kv[1], kv[0]))[:TOP_N]
        result[date] = {
            "loan_count": counts[date],
            "portfolio_kzt": t["portfolio"],
            "par30_kzt": t["par30"],
            "par90_kzt": t["par90"],
            "npl_kzt": t["npl"],
            "provisions_kzt": t["provisions"],
            "par30_share": t["par30"] / t["portfolio"],
            "par90_share": t["par90"] / t["portfolio"],
            "npl_share": t["npl"] / t["portfolio"],
            "top10_exposure_kzt": sum((v for _, v in top), Decimal(0)),
            "top10_group_share": sum((v for _, v in top), Decimal(0)) / t["portfolio"],
            "top10_groups": [(g, v) for g, v in top],
            "written_off_count": int(t["written_off_count"]),
        }
    return result, sectors, programs


# ------------------------------------------------------------------- БД
def psql(query):
    env = dict(os.environ)
    env.setdefault("PGPASSWORD", env.get("POSTGRES_PASSWORD", ""))
    cmd = [
        "psql", "-X", "-q", "-A", "-t", "-F", "\t", "-v", "ON_ERROR_STOP=1",
        "-h", env.get("POSTGRES_HOST", "localhost"),
        "-p", env.get("POSTGRES_PORT", "55432"),
        "-U", env.get("POSTGRES_USER", "arqa"),
        "-d", env.get("POSTGRES_DB", "arqa"),
        "-c", query,
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if out.returncode != 0:
        print(out.stderr, file=sys.stderr)
        sys.exit("psql недоступен — подними БД (make all) перед запуском проверки")
    return [line.split("\t") for line in out.stdout.strip().split("\n") if line.strip()]


# -------------------------------------------------------------- сравнение
def cmp_amount(label, expected: Decimal, actual: Decimal):
    if abs(expected - actual) > AMOUNT_TOL:
        failures.append(f"{label}: CSV={expected} SQL={actual} diff={actual - expected}")
    return abs(expected - actual) <= AMOUNT_TOL


def cmp_share(label, expected: Decimal, actual: Decimal):
    if abs(expected - actual) > SHARE_TOL:
        failures.append(f"{label}: CSV={expected} SQL={actual} diff={actual - expected}")


def main():
    py, py_sectors, py_programs = compute()

    print("=" * 78)
    print("НЕЗАВИСИМЫЙ ПЕРЕСЧЁТ ИЗ CSV (python, stdlib) ПРОТИВ reporting.v_* (SQL)")
    print("=" * 78)

    sql_rows = psql("""
        select report_date, loan_count, portfolio_kzt, par30_kzt, par90_kzt, npl_kzt,
               provisions_kzt, par30_share, par90_share, npl_share,
               top10_exposure_kzt, top10_group_share, written_off_count
        from reporting.v_portfolio_metrics order by report_date
    """)
    if len(sql_rows) != len(py):
        failures.append(f"число дат: CSV={len(py)} SQL={len(sql_rows)}")

    for r in sql_rows:
        date = r[0]
        exp = py.get(date)
        if exp is None:
            failures.append(f"дата {date} есть в SQL, но не в CSV-пересчёте")
            continue
        print(f"\n--- {date} " + "-" * 60)
        checks = [
            ("loan_count", Decimal(exp["loan_count"]), Decimal(r[1]), "count"),
            ("portfolio_kzt", exp["portfolio_kzt"], Decimal(r[2]), "amount"),
            ("par30_kzt", exp["par30_kzt"], Decimal(r[3]), "amount"),
            ("par90_kzt", exp["par90_kzt"], Decimal(r[4]), "amount"),
            ("npl_kzt", exp["npl_kzt"], Decimal(r[5]), "amount"),
            ("provisions_kzt", exp["provisions_kzt"], Decimal(r[6]), "amount"),
            ("par30_share", exp["par30_share"], Decimal(r[7]), "share"),
            ("par90_share", exp["par90_share"], Decimal(r[8]), "share"),
            ("npl_share", exp["npl_share"], Decimal(r[9]), "share"),
            ("top10_exposure_kzt", exp["top10_exposure_kzt"], Decimal(r[10]), "amount"),
            ("top10_group_share", exp["top10_group_share"], Decimal(r[11]), "share"),
            ("written_off_count", Decimal(exp["written_off_count"]), Decimal(r[12]), "count"),
        ]
        for name, e, a, kind in checks:
            before = len(failures)
            if kind == "share":
                cmp_share(f"{date} {name}", e, a)
                shown = f"{e:.10f}"
            elif kind == "count":
                if e != a:
                    failures.append(f"{date} {name}: CSV={e} SQL={a}")
                shown = f"{e:.0f}"
            else:
                cmp_amount(f"{date} {name}", e, a)
                shown = f"{e:,.2f}".replace(",", " ")
            mark = "OK " if len(failures) == before else "FAIL"
            print(f"  [{mark}] {name:<20} {shown}")

    # --- разрезы: отрасль и программа
    for view, dim, pydata in (
        ("reporting.v_metrics_by_sector", "sector", py_sectors),
        ("reporting.v_metrics_by_program", "program", py_programs),
    ):
        rows = psql(f"select report_date, {dim}, portfolio_kzt, par30_kzt, par90_kzt, npl_kzt, provisions_kzt from {view}")
        print(f"\n--- {view}: {len(rows)} строк " + "-" * 30)
        seen = set()
        for r in rows:
            key = (r[0], r[1])
            seen.add(key)
            exp = pydata.get(key)
            if exp is None:
                failures.append(f"{view}: {key} есть в SQL, нет в CSV-пересчёте")
                continue
            cmp_amount(f"{view} {key} portfolio_kzt", exp["portfolio"], Decimal(r[2]))
            cmp_amount(f"{view} {key} par30_kzt", exp["par30"], Decimal(r[3]))
            cmp_amount(f"{view} {key} par90_kzt", exp["par90"], Decimal(r[4]))
            cmp_amount(f"{view} {key} npl_kzt", exp["npl"], Decimal(r[5]))
            cmp_amount(f"{view} {key} provisions_kzt", exp["provisions"], Decimal(r[6]))
        for key in pydata:
            if key not in seen:
                failures.append(f"{view}: {key} есть в CSV-пересчёте, нет в SQL")
        print(f"  [{'OK ' if not failures else '…'}] суммы по разрезу сверены построчно")

    # --- состав топ-10 групп
    rows = psql("select report_date, exposure_rank, group_id, exposure_kzt from reporting.v_top_groups order by report_date, exposure_rank")
    sql_top = defaultdict(list)
    for r in rows:
        sql_top[r[0]].append((r[2], Decimal(r[3])))
    print("\n--- reporting.v_top_groups: состав и экспозиция " + "-" * 20)
    for date, expected in ((d, py[d]["top10_groups"]) for d in sorted(py)):
        got = sql_top.get(date, [])
        if [g for g, _ in expected] != [g for g, _ in got]:
            failures.append(f"{date} состав топ-10 групп: CSV={[g for g,_ in expected]} SQL={[g for g,_ in got]}")
        else:
            for (g, ev), (_, av) in zip(expected, got):
                cmp_amount(f"{date} группа {g} exposure", ev, av)
            print(f"  [OK ] {date}: {', '.join(g for g, _ in expected)}")

    print("\n" + "=" * 78)
    if failures:
        print(f"РАСХОЖДЕНИЙ: {len(failures)}")
        for f in failures:
            print("  ! " + f)
        print("=" * 78)
        sys.exit(1)
    print("ВСЁ СОШЛОСЬ: независимый пересчёт из CSV совпал с reporting.v_* "
          f"(допуск {AMOUNT_TOL} ₸ / {SHARE_TOL} доли)")
    print("=" * 78)


if __name__ == "__main__":
    main()
