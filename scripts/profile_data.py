#!/usr/bin/env python3
"""Профилирование сырых CSV. Только stdlib. Ничего не меняет, только считает."""
import csv, collections, datetime, decimal, sys, re

PORT = 'data/portfolio.csv'
FX = 'data/fx.csv'

def load(path):
    with open(path, newline='', encoding='utf-8') as f:
        r = csv.DictReader(f)
        return r.fieldnames, [dict(x) for x in r]

pf_cols, pf = load(PORT)
fx_cols, fx = load(FX)
print(f"portfolio.csv: {len(pf)} строк данных, колонки: {pf_cols}")
print(f"fx.csv:        {len(fx)} строк данных, колонки: {fx_cols}")
print()

print("=== 1. Срезы (report_date) ===")
for d, c in sorted(collections.Counter(r['report_date'] for r in pf).items()):
    print(f"  {d!r}: {c}")
print()

print("=== 2. Пустые / NULL значения по колонкам ===")
for c in pf_cols:
    empt = sum(1 for r in pf if r[c] is None or r[c].strip() == '')
    nullish = sum(1 for r in pf if (r[c] or '').strip().lower() in ('null','none','nan','\\n'))
    ws = sum(1 for r in pf if r[c] is not None and r[c] != r[c].strip() and r[c].strip() != '')
    if empt or nullish or ws:
        print(f"  {c}: пусто={empt}, nullish={nullish}, с пробелами по краям={ws}")
print("  (колонки, не попавшие в список, — без пустых и пробелов)")
print()

print("=== 3. Полные дубликаты строк (все 13 колонок совпадают) ===")
full = collections.Counter(tuple(r[c] for c in pf_cols) for r in pf)
dups = {k: v for k, v in full.items() if v > 1}
print(f"  групп полных дублей: {len(dups)}; лишних строк: {sum(v-1 for v in dups.values())}")
for k, v in sorted(dups.items(), key=lambda x: x[0][1])[:12]:
    print(f"    {k[0]} {k[1]} x{v}  bal={k[9]} dpd={k[10]}")
print()

print("=== 4. Дубликаты ключа (report_date, loan_id) с РАЗНЫМИ значениями ===")
bykey = collections.defaultdict(list)
for i, r in enumerate(pf):
    bykey[(r['report_date'].strip(), r['loan_id'].strip())].append((i, r))
conf = {k: v for k, v in bykey.items() if len(v) > 1 and len({tuple(x[1][c] for c in pf_cols) for x in v}) > 1}
print(f"  конфликтующих ключей: {len(conf)}")
for k, v in sorted(conf.items())[:20]:
    print(f"  --- {k}")
    for i, r in v:
        diff = {c: r[c] for c in pf_cols if len({tuple(x[1][c] for c in pf_cols) for x in v}) and len({x[1][c] for x in v}) > 1}
        print(f"      csv_row={i+2} " + " ".join(f"{c}={r[c]!r}" for c in diff))
print()

print("=== 5. Ключи (report_date, loan_id) всего / уникальных ===")
print(f"  строк={len(pf)}, уникальных ключей={len(bykey)}, лишних строк={len(pf)-len(bykey)}")
print()

print("=== 6. Домены категориальных колонок (как есть, с кавычками) ===")
for c in ('currency','sector','program','restructured','written_off'):
    cnt = collections.Counter(r[c] for r in pf)
    print(f"  {c}: {len(cnt)} значений")
    for v, n in sorted(cnt.items(), key=lambda x: -x[1]):
        print(f"      {v!r}: {n}")
print()

print("=== 7. principal_outstanding: аномалии ===")
bad, neg, zero, nonnum = [], [], [], []
for r in pf:
    s = (r['principal_outstanding'] or '').strip()
    try:
        v = decimal.Decimal(s)
    except Exception:
        nonnum.append((r['report_date'], r['loan_id'], s)); continue
    if v < 0: neg.append((r['report_date'], r['loan_id'], s))
    elif v == 0: zero.append((r['report_date'], r['loan_id'], s))
print(f"  нечисловые: {len(nonnum)} {nonnum[:10]}")
print(f"  отрицательные: {len(neg)} {neg[:10]}")
print(f"  нулевые: {len(zero)} {zero[:10]}")
print()

print("=== 8. days_past_due: аномалии ===")
dpdbad, dpdneg = [], []
vals = []
for r in pf:
    s = (r['days_past_due'] or '').strip()
    try:
        v = int(s); vals.append(v)
    except Exception:
        dpdbad.append((r['report_date'], r['loan_id'], s)); continue
    if v < 0: dpdneg.append((r['report_date'], r['loan_id'], s))
print(f"  нечисловые: {len(dpdbad)} {dpdbad[:10]}")
print(f"  отрицательные: {len(dpdneg)} {dpdneg[:10]}")
print(f"  min={min(vals)} max={max(vals)}")
print(f"  распределение по бакетам: dpd=0:{sum(1 for v in vals if v==0)}, 1-30:{sum(1 for v in vals if 1<=v<=30)}, 31-90:{sum(1 for v in vals if 31<=v<=90)}, >90:{sum(1 for v in vals if v>90)}")
print()

print("=== 9. Списанные и реструктурированные ===")
print(f"  written_off=1: {sum(1 for r in pf if r['written_off'].strip()=='1')}")
print(f"  restructured=1: {sum(1 for r in pf if r['restructured'].strip()=='1')}")
print(f"  restructured=1 и dpd=0: {sum(1 for r in pf if r['restructured'].strip()=='1' and r['days_past_due'].strip()=='0')}")
print(f"  written_off=1 и остаток>0: {sum(1 for r in pf if r['written_off'].strip()=='1' and decimal.Decimal(r['principal_outstanding'] or 0)>0)}")
print(f"  written_off=1 и restructured=1: {sum(1 for r in pf if r['written_off'].strip()=='1' and r['restructured'].strip()=='1')}")
print()

print("=== 10. Даты ===")
def pd_(s):
    s=(s or '').strip()
    try: return datetime.date.fromisoformat(s)
    except Exception: return None
baddates=collections.Counter()
past_mat=[]
issue_after_mat=[]
issue_future=[]
for r in pf:
    rd, idt, mdt = pd_(r['report_date']), pd_(r['issue_date']), pd_(r['maturity_date'])
    for name, v, raw in (('report_date',rd,r['report_date']),('issue_date',idt,r['issue_date']),('maturity_date',mdt,r['maturity_date'])):
        if v is None: baddates[(name, raw)] += 1
    if rd and mdt and mdt < rd and decimal.Decimal(r['principal_outstanding'] or 0) > 0:
        past_mat.append((r['report_date'], r['loan_id'], r['maturity_date'], r['days_past_due'], r['written_off']))
    if idt and mdt and idt > mdt: issue_after_mat.append((r['loan_id'], r['issue_date'], r['maturity_date']))
    if rd and idt and idt > rd: issue_future.append((r['report_date'], r['loan_id'], r['issue_date']))
print(f"  непарсящиеся даты: {dict(baddates)}")
print(f"  просрочен срок (maturity < report_date) с остатком>0: {len(past_mat)}")
for x in past_mat[:10]: print(f"      {x}")
print(f"  issue_date > maturity_date: {len(issue_after_mat)} {issue_after_mat[:5]}")
print(f"  issue_date > report_date: {len(issue_future)} {issue_future[:5]}")
print()

print("=== 11. Сопоставимость срезов по loan_id ===")
s9 = {r['loan_id'].strip() for r in pf if r['report_date'].strip()=='2026-09-01'}
s10 = {r['loan_id'].strip() for r in pf if r['report_date'].strip()=='2026-10-01'}
print(f"  уникальных loan_id 09-01: {len(s9)}, 10-01: {len(s10)}")
print(f"  только в 09-01 (ушли): {len(s9-s10)}  пример: {sorted(s9-s10)[:5]}")
print(f"  только в 10-01 (новые): {len(s10-s9)}  пример: {sorted(s10-s9)[:5]}")
print()

print("=== 12. Консистентность атрибутов кредита между срезами ===")
attrs=collections.defaultdict(set)
for r in pf:
    k=r['loan_id'].strip()
    attrs[k].add((r['borrower_id'].strip(), r['group_id'].strip(), r['sector'].strip(), r['program'].strip(), r['currency'].strip().upper(), r['issue_date'].strip(), r['maturity_date'].strip()))
incon={k:v for k,v in attrs.items() if len(v)>1}
print(f"  кредитов с разными атрибутами между срезами: {len(incon)}")
for k,v in list(incon.items())[:5]: print(f"      {k}: {v}")
print()

print("=== 13. loan_id -> несколько borrower_id / group_id; borrower -> несколько групп ===")
b2g=collections.defaultdict(set)
for r in pf: b2g[r['borrower_id'].strip()].add(r['group_id'].strip())
print(f"  заёмщиков в >1 группе: {sum(1 for v in b2g.values() if len(v)>1)}")
print(f"  всего заёмщиков: {len(b2g)}, всего групп: {len({r['group_id'].strip() for r in pf})}")
print()

print("=== 14. fx.csv ===")
print(f"  строк: {len(fx)}")
fxc=collections.Counter(r['currency'] for r in fx)
print(f"  валюты: {dict(fxc)}")
fxdates=sorted({r['date'] for r in fx})
print(f"  диапазон дат: {fxdates[0]} .. {fxdates[-1]}, уникальных дат: {len(fxdates)}")
fxkey=collections.Counter((r['date'],r['currency'].strip().upper()) for r in fx)
fxdup={k:v for k,v in fxkey.items() if v>1}
print(f"  дубли (date,currency): {len(fxdup)} {list(fxdup.items())[:10]}")
if fxdup:
    for k in list(fxdup)[:10]:
        print(f"      {k}: " + ", ".join(r['rate_kzt'] for r in fx if (r['date'],r['currency'].strip().upper())==k))
badrate=[r for r in fx if not re.fullmatch(r'-?\d+(\.\d+)?', (r['rate_kzt'] or '').strip())]
print(f"  нечисловые/пустые курсы: {len(badrate)} {[(r['date'],r['currency'],r['rate_kzt']) for r in badrate][:10]}")
nonpos=[r for r in fx if re.fullmatch(r'-?\d+(\.\d+)?', (r['rate_kzt'] or '').strip()) and decimal.Decimal(r['rate_kzt'])<=0]
print(f"  курсы <= 0: {len(nonpos)} {[(r['date'],r['currency'],r['rate_kzt']) for r in nonpos][:10]}")
print("  все строки fx.csv:")
for r in fx: print(f"      {r['date']} {r['currency']!r} {r['rate_kzt']}")
print()

print("=== 15. Покрытие валют курсами на даты срезов ===")
need=collections.Counter((r['report_date'].strip(), r['currency'].strip().upper()) for r in pf)
have={(r['date'].strip(), r['currency'].strip().upper()) for r in fx}
for (d,c),n in sorted(need.items()):
    status='KZT (курс не нужен)' if c=='KZT' else ('ЕСТЬ' if (d,c) in have else '>>> НЕТ КУРСА <<<')
    print(f"  {d} {c}: {n} кредитов — {status}")
