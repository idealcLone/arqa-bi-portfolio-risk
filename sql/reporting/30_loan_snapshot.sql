-- Очищенная витрина: одна строка на (report_date, loan_id).
--
-- Что делает:
--   1. дедупликация 60 полных дублей строк (docs/data_quality.md A1);
--   2. нормализация текстовых полей (trim, валюта в upper);
--   3. конвертация в тенге по курсу НА ДАТУ СРЕЗА;
--   4. единый CASE для бакета DPD и ставки провизий — приоритет у NPL;
--   5. хелпер-колонки *_kzt, из которых семантический слой собирает доли
--      как sum(par30_kzt) / sum(principal_kzt_active).
--
-- Списанные кредиты (written_off = 1) ОСТАЮТСЯ в витрине с флагом, но все денежные
-- хелпер-колонки у них = 0: так объём списаний измерим, но ни одна мера его не включает.
--
-- Округление: до копейки (2 знака) на уровне СТРОКИ, затем суммирование.
-- Тот же порядок повторён в независимом пересчёте checks/independent_recompute.py.
create or replace view reporting.v_loan_snapshot as
with p as (
    select
        p.report_date,
        btrim(p.loan_id)                as loan_id,
        btrim(p.borrower_id)            as borrower_id,
        btrim(p.group_id)               as group_id,
        btrim(p.sector)                 as sector,
        btrim(p.program)                as program,
        upper(btrim(p.currency))        as currency,
        p.issue_date,
        p.maturity_date,
        p.principal_outstanding,
        p.days_past_due,
        p.restructured,
        p.written_off,
        -- Детерминированная дедупликация: сортировка по всем значимым колонкам,
        -- поэтому результат не зависит от физического порядка строк в таблице.
        row_number() over (
            partition by p.report_date, btrim(p.loan_id)
            order by p.principal_outstanding desc,
                     p.days_past_due        desc,
                     p.written_off          desc,
                     p.restructured         desc,
                     p.maturity_date        desc,
                     p.issue_date           desc,
                     btrim(p.borrower_id),
                     btrim(p.group_id)
        ) as rn
    from raw.portfolio p
),
dedup as (
    select
        report_date, loan_id, borrower_id, group_id, sector, program, currency,
        issue_date, maturity_date, principal_outstanding, days_past_due,
        restructured, written_off
    from p
    where rn = 1
),
converted as (
    select
        d.report_date,
        d.loan_id,
        d.borrower_id,
        d.group_id,
        d.sector,
        d.program,
        d.currency,
        d.issue_date,
        d.maturity_date,
        d.principal_outstanding,
        d.days_past_due,
        d.restructured,
        d.written_off,
        f.rate_kzt,
        -- Курс строго на дату среза. INNER JOIN не используем: кредит без курса
        -- должен быть виден проверке checks/02_fx_coverage.sql, а не молча исчезнуть.
        round(d.principal_outstanding * f.rate_kzt, 2) as principal_kzt,
        (d.written_off = 1)                            as is_written_off,
        (d.days_past_due > prm.dpd_par30_threshold)    as is_par30,
        (d.days_past_due > prm.dpd_par90_threshold)    as is_par90,
        (d.days_past_due > prm.dpd_par90_threshold
            or d.restructured = 1)                     as is_npl,
        (d.maturity_date < d.report_date)              as is_past_maturity,
        prm.provision_rate_dpd_0_30,
        prm.provision_rate_dpd_31_90,
        prm.provision_rate_npl,
        prm.dpd_par30_threshold,
        prm.dpd_par90_threshold
    from dedup d
    cross join reporting.v_params prm
    left join reporting.v_fx f
           on f.rate_date = d.report_date
          and f.currency  = d.currency
),
classified as (
    select
        c.report_date,
        c.loan_id,
        c.borrower_id,
        c.group_id,
        c.sector,
        c.program,
        c.currency,
        c.issue_date,
        c.maturity_date,
        c.principal_outstanding,
        c.days_past_due,
        c.restructured,
        c.written_off,
        c.rate_kzt,
        c.principal_kzt,
        c.is_written_off,
        c.is_par30,
        c.is_par90,
        c.is_npl,
        c.is_past_maturity,
        -- ЕДИНСТВЕННОЕ место, где определяется ставка провизий.
        -- Приоритет NPL: реструктуризация с DPD = 0 получает 50%.
        case
            when c.is_npl                              then c.provision_rate_npl
            when c.days_past_due > c.dpd_par30_threshold then c.provision_rate_dpd_31_90
            else                                            c.provision_rate_dpd_0_30
        end as provision_rate,
        -- Бакет DPD — та же логика порогов, для разрезов и сверки сумм.
        case
            when c.days_past_due = 0                     then '0'
            when c.days_past_due <= c.dpd_par30_threshold then '1–30'
            when c.days_past_due <= c.dpd_par90_threshold then '31–90'
            else                                               '90+'
        end as dpd_bucket,
        case
            when c.days_past_due = 0                     then 1
            when c.days_past_due <= c.dpd_par30_threshold then 2
            when c.days_past_due <= c.dpd_par90_threshold then 3
            else                                               4
        end as dpd_bucket_order
    from converted c
)
select
    c.report_date,
    c.loan_id,
    c.borrower_id,
    c.group_id,
    c.sector,
    c.program,
    c.currency,
    c.issue_date,
    c.maturity_date,
    c.days_past_due,
    c.dpd_bucket,
    c.dpd_bucket_order,
    c.restructured,
    c.written_off,
    c.is_written_off,
    c.is_par30,
    c.is_par90,
    c.is_npl,
    c.is_past_maturity,
    c.principal_outstanding,
    c.rate_kzt,
    c.principal_kzt,
    c.provision_rate,
    -- Хелпер-колонки для семантического слоя (только sum/avg/count):
    -- у списанных все они = 0, поэтому любая мера автоматически исключает списания.
    case when c.is_written_off then 0 else c.principal_kzt end                                   as principal_kzt_active,
    case when c.is_written_off or not c.is_par30 then 0 else c.principal_kzt end                 as par30_kzt,
    case when c.is_written_off or not c.is_par90 then 0 else c.principal_kzt end                 as par90_kzt,
    case when c.is_written_off or not c.is_npl   then 0 else c.principal_kzt end                 as npl_kzt,
    case when c.is_written_off then 0 else round(c.principal_kzt * c.provision_rate, 2) end      as provision_kzt,
    case when c.is_written_off then c.principal_kzt else 0 end                                   as written_off_kzt,
    case when c.is_written_off then 0 else 1 end                                                 as active_loan_flag
from classified c;

comment on view reporting.v_loan_snapshot is
    'Очищенная витрина портфеля: 1 строка на (report_date, loan_id), FX в KZT, флаги PAR/NPL, провизии';
