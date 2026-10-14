-- Метрики портфеля: одна строка на дату среза + изменение к базовой дате (v_params.base_report_date).
-- Все доли считаются от ОДНОГО знаменателя — portfolio_kzt этой же даты (без списанных).
-- Изменения: для сумм — абсолютные (₸), для долей — в процентных пунктах (п.п.).
create or replace view reporting.v_portfolio_metrics as
with agg as (
    select
        s.report_date,
        count(*) filter (where not s.is_written_off)                         as loan_count,
        count(distinct s.borrower_id) filter (where not s.is_written_off)    as borrower_count,
        count(distinct s.group_id) filter (where not s.is_written_off)       as group_count,
        sum(s.principal_kzt_active)                                          as portfolio_kzt,
        sum(s.par30_kzt)                                                     as par30_kzt,
        sum(s.par90_kzt)                                                     as par90_kzt,
        sum(s.npl_kzt)                                                       as npl_kzt,
        sum(s.provision_kzt)                                                 as provisions_kzt,
        -- справочно: объём списанных (в портфель не входит)
        count(*) filter (where s.is_written_off)                             as written_off_count,
        sum(s.written_off_kzt)                                               as written_off_kzt,
        -- справочно: валютная структура (эффект FX на USD-кредитах)
        sum(s.principal_kzt_active) filter (where s.currency = 'USD')        as usd_portfolio_kzt,
        sum(s.principal_outstanding) filter (where s.currency = 'USD' and not s.is_written_off) as usd_principal_usd,
        -- справочно: кредиты с истёкшим сроком (аномалия A5, в метрики не влияет)
        sum(s.principal_kzt_active) filter (where s.is_past_maturity)        as past_maturity_kzt
    from reporting.v_loan_snapshot s
    group by s.report_date
),
top10 as (
    select
        report_date,
        sum(share_of_portfolio) as top10_group_share,
        sum(exposure_kzt)       as top10_exposure_kzt
    from reporting.v_top_groups
    group by report_date
),
metrics as (
    select
        a.report_date,
        a.loan_count,
        a.borrower_count,
        a.group_count,
        a.portfolio_kzt,
        a.par30_kzt,
        a.par90_kzt,
        a.npl_kzt,
        a.provisions_kzt,
        a.par30_kzt / a.portfolio_kzt       as par30_share,
        a.par90_kzt / a.portfolio_kzt       as par90_share,
        a.npl_kzt   / a.portfolio_kzt       as npl_share,
        a.provisions_kzt / a.portfolio_kzt  as provision_coverage,   -- провизии к портфелю
        t.top10_exposure_kzt,
        t.top10_group_share,
        a.written_off_count,
        a.written_off_kzt,
        a.usd_portfolio_kzt,
        a.usd_principal_usd,
        a.usd_portfolio_kzt / a.portfolio_kzt as usd_share,
        a.past_maturity_kzt,
        -- курс USD на дату среза (для объяснения FX-эффекта в README)
        (select f.rate_kzt from reporting.v_fx f
          where f.rate_date = a.report_date and f.currency = 'USD') as usd_rate_kzt
    from agg a
    join top10 t on t.report_date = a.report_date
),
base as (
    select
        m.portfolio_kzt      as base_portfolio_kzt,
        m.par30_share        as base_par30_share,
        m.par90_share        as base_par90_share,
        m.npl_share          as base_npl_share,
        m.provisions_kzt     as base_provisions_kzt,
        m.top10_group_share  as base_top10_group_share,
        m.loan_count         as base_loan_count
    from metrics m
    cross join reporting.v_params prm
    where m.report_date = prm.base_report_date
)
select
    m.report_date,
    m.loan_count,
    m.borrower_count,
    m.group_count,
    m.portfolio_kzt,
    m.par30_kzt,
    m.par90_kzt,
    m.npl_kzt,
    m.provisions_kzt,
    m.par30_share,
    m.par90_share,
    m.npl_share,
    m.provision_coverage,
    m.top10_exposure_kzt,
    m.top10_group_share,
    m.written_off_count,
    m.written_off_kzt,
    m.usd_portfolio_kzt,
    m.usd_principal_usd,
    m.usd_share,
    m.usd_rate_kzt,
    m.past_maturity_kzt,
    -- Изменения к базовой дате. На строке базовой даты — NULL (сравнивать не с чем).
    case when m.report_date = prm.base_report_date then null
         else m.portfolio_kzt - b.base_portfolio_kzt end        as portfolio_kzt_chg,
    case when m.report_date = prm.base_report_date then null
         else m.provisions_kzt - b.base_provisions_kzt end      as provisions_kzt_chg,
    case when m.report_date = prm.base_report_date then null
         else m.loan_count - b.base_loan_count end              as loan_count_chg,
    -- доли — в процентных пунктах
    case when m.report_date = prm.base_report_date then null
         else (m.par30_share - b.base_par30_share) * 100 end     as par30_share_chg_pp,
    case when m.report_date = prm.base_report_date then null
         else (m.par90_share - b.base_par90_share) * 100 end     as par90_share_chg_pp,
    case when m.report_date = prm.base_report_date then null
         else (m.npl_share - b.base_npl_share) * 100 end         as npl_share_chg_pp,
    case when m.report_date = prm.base_report_date then null
         else (m.top10_group_share - b.base_top10_group_share) * 100 end as top10_group_share_chg_pp
from metrics m
cross join reporting.v_params prm
cross join base b
order by m.report_date;

comment on view reporting.v_portfolio_metrics is
    'Сводные метрики на каждую дату среза + изменение к 2026-09-01 (₸ для сумм, п.п. для долей)';
