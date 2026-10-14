#!/usr/bin/env python3
"""
Генерация числовых блоков README из БД.

Правило проекта: ни одна цифра в README не вбивается руками. Скрипт выполняет запросы
к reporting.* и подставляет готовые таблицы между маркерами <!-- AUTO:имя --> … <!-- /AUTO:имя -->.
Запускается из run.sh, поэтому README всегда соответствует последнему прогону пайплайна.
Зависимости: стандартная библиотека + psql.
"""
import os
import re
import subprocess
import sys
from decimal import Decimal

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.md")


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


def money(v, digits=2):
    """1234567.89 -> '1 234 567,89'"""
    q = Decimal(v).quantize(Decimal("1." + "0" * digits)) if digits else Decimal(v).quantize(Decimal(1))
    s = f"{q:,.{digits}f}"
    return s.replace(",", " ").replace(".", ",")


def bn(v):
    return money(Decimal(v) / Decimal(1e9), 1)


def pct(v, digits=2):
    return money(Decimal(v) * 100, digits) + "%"


def pp(v, digits=2):
    """v — значение УЖЕ в процентных пунктах (разницу долей передавать как (b - a) * 100)."""
    val = Decimal(v)
    sign = "+" if val > 0 else ("−" if val < 0 else "")
    return f"{sign}{money(abs(val), digits)} п.п."


def signed_bn(v):
    val = Decimal(v)
    sign = "+" if val > 0 else ("−" if val < 0 else "")
    return f"{sign}{bn(abs(val))}"


def block_headline():
    rows = psql("""
        select report_date::text, portfolio_kzt, par30_share, par90_share, npl_share,
               provisions_kzt, provision_coverage, top10_group_share, loan_count,
               written_off_count, written_off_kzt, usd_rate_kzt, usd_share
        from reporting.v_portfolio_metrics order by report_date
    """)
    chg = psql("""
        -- колонки *_chg_pp УЖЕ в процентных пунктах, делить на 100 не нужно
        select portfolio_kzt_chg, par30_share_chg_pp, par90_share_chg_pp,
               npl_share_chg_pp, provisions_kzt_chg, top10_group_share_chg_pp,
               loan_count_chg
        from reporting.v_portfolio_metrics where portfolio_kzt_chg is not null
    """)[0]
    a, b = rows[0], rows[1]
    lines = [
        "| Показатель | 01.09.2026 | 01.10.2026 | Изменение |",
        "|---|---:|---:|---:|",
        f"| Портфель (без списанных) | {money(a[1])} ₸ | {money(b[1])} ₸ | {signed_bn(chg[0])} млрд ₸ |",
        f"| — то же, млрд ₸ | {bn(a[1])} | {bn(b[1])} | {signed_bn(chg[0])} |",
        f"| PAR30 | {pct(a[2])} | {pct(b[2])} | {pp(chg[1])} |",
        f"| PAR90 | {pct(a[3])} | {pct(b[3])} | {pp(chg[2])} |",
        f"| NPL | {pct(a[4])} | {pct(b[4])} | {pp(chg[3])} |",
        f"| Провизии | {money(a[5])} ₸ | {money(b[5])} ₸ | {signed_bn(chg[4])} млрд ₸ |",
        f"| Покрытие провизиями (провизии / портфель) | {pct(a[6])} | {pct(b[6])} | "
        f"{pp((Decimal(b[6]) - Decimal(a[6])) * 100)} |",
        f"| Концентрация: топ-10 групп | {pct(a[7])} | {pct(b[7])} | {pp(chg[5])} |",
        f"| Кредитов в портфеле | {money(a[8], 0)} | {money(b[8], 0)} | {'+' if int(chg[6])>0 else '−'}{money(abs(int(chg[6])), 0)} |",
        f"| Списано (вне портфеля) | {money(a[9], 0)} шт. / {bn(a[10])} млрд ₸ | "
        f"{money(b[9], 0)} шт. / {bn(b[10])} млрд ₸ | — |",
        f"| Курс USD на дату среза | {money(a[11])} ₸ | {money(b[11])} ₸ | "
        f"{signed_bn(Decimal(0))if False else '+' + money(Decimal(b[11]) - Decimal(a[11])) + ' ₸'} |",
        f"| Доля валютного (USD) портфеля | {pct(a[12])} | {pct(b[12])} | "
        f"{pp((Decimal(b[12]) - Decimal(a[12])) * 100)} |",
    ]
    return "\n".join(lines)


def block_sector():
    rows = psql("""
        select sector, portfolio_kzt, share_of_portfolio, par30_share, npl_share, provisions_kzt, loan_count
        from reporting.v_metrics_by_sector where report_date = '2026-10-01'
        order by portfolio_kzt desc
    """)
    out = ["| Отрасль | Портфель, млрд ₸ | Доля портфеля | PAR30 | NPL | Провизии, млрд ₸ | Кредитов |",
           "|---|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        out.append(f"| {r[0]} | {bn(r[1])} | {pct(r[2])} | {pct(r[3])} | {pct(r[4])} | {bn(r[5])} | {r[6]} |")
    return "\n".join(out)


def block_program():
    rows = psql("""
        select program, portfolio_kzt, share_of_portfolio, par30_share, npl_share, provisions_kzt, loan_count
        from reporting.v_metrics_by_program where report_date = '2026-10-01'
        order by portfolio_kzt desc
    """)
    out = ["| Программа | Портфель, млрд ₸ | Доля портфеля | PAR30 | NPL | Провизии, млрд ₸ | Кредитов |",
           "|---|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        out.append(f"| {r[0]} | {bn(r[1])} | {pct(r[2])} | {pct(r[3])} | {pct(r[4])} | {bn(r[5])} | {r[6]} |")
    return "\n".join(out)


def block_top_groups():
    rows = psql("""
        select exposure_rank, group_id, exposure_kzt, share_of_portfolio, loan_count, borrower_count
        from reporting.v_top_groups where report_date = '2026-10-01' order by exposure_rank
    """)
    total = psql("select top10_exposure_kzt, top10_group_share from reporting.v_portfolio_metrics where report_date='2026-10-01'")[0]
    out = ["| # | Группа | Экспозиция, млрд ₸ | Доля портфеля | Кредитов | Заёмщиков |",
           "|---:|---|---:|---:|---:|---:|"]
    for r in rows:
        out.append(f"| {r[0]} | {r[1]} | {bn(r[2])} | {pct(r[3])} | {r[4]} | {r[5]} |")
    out.append(f"| | **Итого топ-10** | **{bn(total[0])}** | **{pct(total[1])}** | | |")
    return "\n".join(out)


def block_npl_bridge():
    # Один проход по витрине с условной агрегацией вместо self-join двух её копий:
    # self-join заставлял планировщик выбирать способ соединения, и в CI выбор оказывался
    # катастрофическим (шаг висел минутами). Здесь витрина читается ровно один раз.
    r = psql("""
        with per_loan as (
            select
                loan_id,
                coalesce(sum(npl_kzt) filter (where report_date = '2026-09-01'), 0) as n9,
                coalesce(sum(npl_kzt) filter (where report_date = '2026-10-01'), 0) as n10,
                bool_or(is_npl         and report_date = '2026-09-01') as i9,
                bool_or(is_npl         and report_date = '2026-10-01') as i10,
                bool_or(is_written_off and report_date = '2026-10-01') as w10
            from reporting.v_loan_snapshot
            where report_date in ('2026-09-01', '2026-10-01')
            group by loan_id
        )
        select sum(n9),
               coalesce(sum(n9)  filter (where i9 and w10), 0),
               coalesce(sum(n9)  filter (where i9 and not i10 and not w10), 0),
               coalesce(sum(n10) filter (where not i9 and i10), 0),
               coalesce(sum(n10 - n9) filter (where i9 and i10 and not w10), 0),
               sum(n10)
        from per_loan
    """)[0]
    start, to_wo, cured, new_npl, residual, end = (Decimal(x) for x in r)
    check = start - to_wo - cured + new_npl + residual - end
    out = [
        "| Фактор | Сумма, млрд ₸ |",
        "|---|---:|",
        f"| NPL на 01.09.2026 | {bn(start)} |",
        f"| − ушли в списание | −{bn(to_wo)} |",
        f"| − вышли из NPL (просрочка закрыта, реструктуризация снята) | −{bn(cured)} |",
        f"| + новые NPL | +{bn(new_npl)} |",
        f"| ± изменение остатков по оставшимся в NPL (амортизация + курс) | {signed_bn(residual)} |",
        f"| **NPL на 01.10.2026** | **{bn(end)}** |",
        f"| *невязка моста* | *{money(check)} ₸* |",
    ]
    return "\n".join(out)


def block_comparability():
    # Один проход по витрине: кредиты с переходом written_off 1 → 0 и показатели 01.10
    # с ними и без них считаются в одной агрегации (см. комментарий в block_npl_bridge).
    r = psql("""
        with per_loan as (
            select
                loan_id,
                bool_or(is_written_off and report_date = '2026-09-01') as wo9,
                bool_or(is_written_off and report_date = '2026-10-01') as wo10,
                coalesce(sum(principal_kzt_active) filter (where report_date = '2026-10-01'), 0) as p10,
                coalesce(sum(npl_kzt)              filter (where report_date = '2026-10-01'), 0) as n10,
                coalesce(sum(par30_kzt)            filter (where report_date = '2026-10-01'), 0) as p30,
                coalesce(sum(par90_kzt)            filter (where report_date = '2026-10-01'), 0) as p90
            from reporting.v_loan_snapshot
            where report_date in ('2026-09-01', '2026-10-01')
            group by loan_id
        ),
        marked as (
            select per_loan.*, (wo9 and not wo10) as returned_from_wo from per_loan
        )
        select
            count(*) filter (where returned_from_wo),
            coalesce(sum(p10) filter (where returned_from_wo), 0),
            coalesce(sum(n10) filter (where returned_from_wo), 0),
            sum(p10),
            coalesce(sum(p10) filter (where not returned_from_wo), 0),
            coalesce(sum(n10) filter (where not returned_from_wo), 0),
            coalesce(sum(p30) filter (where not returned_from_wo), 0),
            coalesce(sum(p90) filter (where not returned_from_wo), 0)
        from marked
    """)[0]
    cnt = int(r[0])
    amount, npl_part, portfolio = Decimal(r[1]), Decimal(r[2]), Decimal(r[3])
    comp_p, comp_n, comp_30, comp_90 = (Decimal(x) for x in r[4:8])
    rep = psql("""
        select npl_share, par30_share, par90_share
        from reporting.v_portfolio_metrics where report_date = '2026-10-01'
    """)[0]
    fx = psql("""
        select m9.usd_principal_usd, m9.usd_rate_kzt, m10.usd_principal_usd, m10.usd_rate_kzt,
               round(m10.usd_principal_usd * (m10.usd_rate_kzt - m9.usd_rate_kzt), 2),
               m10.usd_portfolio_kzt - m9.usd_portfolio_kzt
        from reporting.v_portfolio_metrics m9, reporting.v_portfolio_metrics m10
        where m9.report_date = '2026-09-01' and m10.report_date = '2026-10-01'
    """)[0]
    out = [
        "| Фактор сопоставимости | Значение |",
        "|---|---:|",
        f"| Кредитов с переходом `written_off` 1 → 0 (01.09 → 01.10) | {cnt} |",
        f"| Их остаток в портфеле на 01.10 | {money(amount)} ₸ ({pct(amount / portfolio)} портфеля) |",
        f"| Из них попадает в NPL | {money(npl_part)} ₸ |",
        f"| Портфель на 01.10 без них (сопоставимая база) | {money(comp_p)} ₸ |",
        f"| Валютный остаток, USD: 01.09 → 01.10 | {money(fx[0])} → {money(fx[2])} |",
        f"| Курс USD: 01.09 → 01.10 | {money(fx[1])} → {money(fx[3])} ₸ (+{pct(Decimal(fx[3]) / Decimal(fx[1]) - 1)}) |",
        f"| Курсовой эффект на USD-портфель (переоценка остатка 01.10) | +{money(fx[4])} ₸ |",
        f"| Фактическое изменение USD-портфеля в ₸ | {signed_bn(fx[5])} млрд ₸ |",
        f"| NPL на 01.10: отчётный → без вернувшихся | {pct(rep[0])} → **{pct(comp_n / comp_p)}** "
        f"({pp((comp_n / comp_p - Decimal(rep[0])) * 100)}) |",
        f"| PAR30 на 01.10: отчётный → без вернувшихся | {pct(rep[1])} → {pct(comp_30 / comp_p)} "
        f"({pp((comp_30 / comp_p - Decimal(rep[1])) * 100)}) |",
        f"| PAR90 на 01.10: отчётный → без вернувшихся | {pct(rep[2])} → {pct(comp_90 / comp_p)} "
        f"({pp((comp_90 / comp_p - Decimal(rep[2])) * 100)}) |",
    ]
    return "\n".join(out)


BLOCKS = {
    "headline": block_headline,
    "sector": block_sector,
    "program": block_program,
    "top_groups": block_top_groups,
    "npl_bridge": block_npl_bridge,
    "comparability": block_comparability,
}


def main():
    import time
    text = open(README, encoding="utf-8").read()
    timings = []
    for name, fn in BLOCKS.items():
        start, end = f"<!-- AUTO:{name} -->", f"<!-- /AUTO:{name} -->"
        if start not in text or end not in text:
            sys.exit(f"README.md: нет маркеров для блока {name}")
        t0 = time.monotonic()
        body = fn()
        timings.append((name, time.monotonic() - t0))
        text = re.sub(
            re.escape(start) + r".*?" + re.escape(end),
            start + "\n" + body + "\n" + end,
            text, flags=re.S)
    open(README, "w", encoding="utf-8").write(text)
    print(f"README.md: обновлено блоков с цифрами — {len(BLOCKS)} (все значения из reporting.*)")
    print("  время по блокам: " + ", ".join(f"{n} {t:.2f}с" for n, t in timings))


if __name__ == "__main__":
    main()
