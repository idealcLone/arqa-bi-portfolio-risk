-- Сквозная сверка отдельных кредитов: сырьё → витрина → вклад в метрики.
-- Кредиты выбираются по ХАРАКТЕРИСТИКАМ (дубль строки, USD, реструктуризация с DPD=0,
-- списание, бакет 31–90), а не по жёстко вбитым id: проверка остаётся осмысленной,
-- если данные обновятся. Кейсы взаимоисключающие, поэтому один кредит не попадает в два.
\set ON_ERROR_STOP on
\pset border 2

-- Один раз выбираем кейсы во временную вьюху (живёт только в этой сессии psql).
create temporary view spot_cases as
with c as (
    select 'дубль строки в raw'                    as case_name, 1 as ord,
           (select btrim(loan_id)
              from raw.portfolio
             group by report_date, btrim(loan_id)
            having count(*) > 1
             order by btrim(loan_id)
             limit 1) as loan_id
    union all
    select 'валютный (USD) кредит, без аномалий', 2,
           (select loan_id from reporting.v_loan_snapshot
             where currency = 'USD' and report_date = '2026-10-01'
               and not is_written_off and restructured = 0 and days_past_due = 0
             order by principal_kzt desc limit 1)
    union all
    select 'реструктуризация с DPD = 0 → NPL, 50%', 3,
           (select loan_id from reporting.v_loan_snapshot
             where restructured = 1 and days_past_due = 0 and report_date = '2026-10-01'
               and currency = 'KZT'
             order by principal_kzt desc limit 1)
    union all
    select 'списанный кредит (вне портфеля)', 4,
           (select loan_id from reporting.v_loan_snapshot
             where is_written_off and report_date = '2026-10-01'
             order by principal_kzt desc limit 1)
    union all
    select 'просрочка 31–90 → ставка 10%', 5,
           (select loan_id from reporting.v_loan_snapshot
             where dpd_bucket = '31–90' and not is_npl and report_date = '2026-10-01'
             order by principal_kzt desc limit 1)
)
select case_name, ord, loan_id from c;

-- Страховка от самой частой ошибки такой проверки: один кредит в двух кейсах
-- размножил бы строки при join и выглядел бы как «дубль в витрине».
do $$
declare v_dup int;
begin
    select count(*) into v_dup from (
        select loan_id from spot_cases group by loan_id having count(*) > 1) q;
    if v_dup > 0 then
        raise exception 'Кейсы пересекаются: % кредитов выбрано больше одного раза', v_dup;
    end if;
end $$;

\echo ''
\echo '=== 0. Выбранные кейсы ==='
select ord as "№", case_name as "Кейс", loan_id as "Кредит" from spot_cases order by ord;

\echo ''
\echo '=== 1. Сырые строки (raw.portfolio), как есть в CSV ==='
select r.report_date, r.loan_id, r.group_id, r.currency, r.principal_outstanding,
       r.days_past_due as dpd, r.restructured as restr, r.written_off as w_off,
       count(*) over (partition by r.report_date, btrim(r.loan_id)) as "строк в raw"
from raw.portfolio r
join spot_cases c on c.loan_id = btrim(r.loan_id)
order by r.loan_id, r.report_date;

\echo ''
\echo '=== 2. Строки витрины: дедупликация, курс, флаги, ставка, провизии ==='
select s.report_date, s.loan_id, s.currency, s.principal_outstanding, s.rate_kzt,
       s.principal_kzt, s.dpd_bucket, s.is_par30, s.is_par90, s.is_npl,
       s.provision_rate, s.provision_kzt, s.principal_kzt_active, s.npl_kzt
from reporting.v_loan_snapshot s
join spot_cases c on c.loan_id = s.loan_id
order by s.loan_id, s.report_date;

\echo ''
\echo '=== 3. Арифметика построчно: пересчёт из определений ==='
select
    s.report_date, s.loan_id,
    s.principal_outstanding || ' × ' || s.rate_kzt || ' = '
        || round(s.principal_outstanding * s.rate_kzt, 2)            as "остаток × курс",
    s.principal_kzt                                                   as "в витрине",
    case when round(s.principal_outstanding * s.rate_kzt, 2) = s.principal_kzt
         then 'совпало' else 'РАСХОЖДЕНИЕ' end                        as "конвертация",
    round(s.principal_kzt * s.provision_rate, 2)                      as "остаток × ставка",
    s.provision_kzt                                                   as "провизии в витрине",
    case when s.is_written_off and s.provision_kzt = 0 then 'списан → 0'
         when round(s.principal_kzt * s.provision_rate, 2) = s.provision_kzt then 'совпало'
         else 'РАСХОЖДЕНИЕ' end                                       as "провизии"
from reporting.v_loan_snapshot s
join spot_cases c on c.loan_id = s.loan_id
order by s.loan_id, s.report_date;

\echo ''
\echo '=== 4. Вклад кредита в метрики среза 01.10.2026 ==='
select
    s.loan_id, c.case_name as "Кейс",
    s.principal_kzt_active                                           as "вклад в портфель, ₸",
    round(100 * s.principal_kzt_active / m.portfolio_kzt, 6)         as "% портфеля",
    s.npl_kzt                                                        as "вклад в NPL, ₸",
    round(100 * s.npl_kzt / nullif(m.npl_kzt, 0), 6)                 as "% NPL",
    s.provision_kzt                                                  as "вклад в провизии, ₸"
from reporting.v_loan_snapshot s
join spot_cases c on c.loan_id = s.loan_id
join reporting.v_portfolio_metrics m on m.report_date = s.report_date
where s.report_date = '2026-10-01'
order by c.ord;

-- Итоговый ассерт: ни одной строки с расхождением арифметики среди выбранных кейсов,
-- и ни одного кредита, попавшего в витрину дважды.
do $$
declare v_bad int; v_dup int;
begin
    select count(*) into v_bad
    from reporting.v_loan_snapshot s
    join spot_cases c on c.loan_id = s.loan_id
    where round(s.principal_outstanding * s.rate_kzt, 2) <> s.principal_kzt
       or (not s.is_written_off and round(s.principal_kzt * s.provision_rate, 2) <> s.provision_kzt)
       or (s.is_written_off and s.provision_kzt <> 0);
    if v_bad > 0 then
        raise exception 'Сквозная сверка: расхождений в арифметике — %', v_bad;
    end if;

    select count(*) into v_dup from (
        select s.report_date, s.loan_id
        from reporting.v_loan_snapshot s
        join spot_cases c on c.loan_id = s.loan_id
        group by s.report_date, s.loan_id having count(*) > 1) q;
    if v_dup > 0 then
        raise exception 'Сквозная сверка: кредит встречается в витрине дважды — % случаев', v_dup;
    end if;
    raise notice 'OK 7: сквозная сверка кейсов пройдена (конвертация, ставки, дедупликация)';
end $$;
