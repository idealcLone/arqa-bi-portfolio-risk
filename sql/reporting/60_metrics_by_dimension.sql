-- Разрезы по отрасли и по программе. Набор метрик тот же, что в v_portfolio_metrics,
-- и считается из тех же хелпер-колонок витрины — поэтому суммы по разрезам
-- обязаны совпадать с итогом по дате до копейки (проверяется в checks/).
--
-- Внимание на знаменатели: внутри разреза доли (par30_share и т.п.) считаются
-- от портфеля ЭТОГО разреза (так читается «PAR30 отрасли»), а share_of_portfolio —
-- вес разреза в общем портфеле даты. Оба знаменателя помечены в именах колонок.
create or replace view reporting.v_metrics_by_sector as
with agg as (
    select
        s.report_date,
        s.sector                                     as sector,
        count(*) filter (where not s.is_written_off) as loan_count,
        sum(s.principal_kzt_active)                  as portfolio_kzt,
        sum(s.par30_kzt)                             as par30_kzt,
        sum(s.par90_kzt)                             as par90_kzt,
        sum(s.npl_kzt)                               as npl_kzt,
        sum(s.provision_kzt)                         as provisions_kzt
    from reporting.v_loan_snapshot s
    group by s.report_date, s.sector
),
total as (
    select report_date, sum(portfolio_kzt) as total_portfolio_kzt
    from agg
    group by report_date
)
select
    a.report_date,
    a.sector,
    a.loan_count,
    a.portfolio_kzt,
    a.par30_kzt,
    a.par90_kzt,
    a.npl_kzt,
    a.provisions_kzt,
    a.portfolio_kzt / t.total_portfolio_kzt as share_of_portfolio,  -- вес отрасли в портфеле даты
    a.par30_kzt / a.portfolio_kzt           as par30_share,          -- доли внутри отрасли
    a.par90_kzt / a.portfolio_kzt           as par90_share,
    a.npl_kzt   / a.portfolio_kzt           as npl_share,
    a.provisions_kzt / a.portfolio_kzt      as provision_coverage
from agg a
join total t on t.report_date = a.report_date
order by a.report_date, a.portfolio_kzt desc;

comment on view reporting.v_metrics_by_sector is
    'Метрики портфеля по отраслям и датам; доли внутри отрасли + вес отрасли в портфеле';

create or replace view reporting.v_metrics_by_program as
with agg as (
    select
        s.report_date,
        s.program                                    as program,
        count(*) filter (where not s.is_written_off) as loan_count,
        sum(s.principal_kzt_active)                  as portfolio_kzt,
        sum(s.par30_kzt)                             as par30_kzt,
        sum(s.par90_kzt)                             as par90_kzt,
        sum(s.npl_kzt)                               as npl_kzt,
        sum(s.provision_kzt)                         as provisions_kzt
    from reporting.v_loan_snapshot s
    group by s.report_date, s.program
),
total as (
    select report_date, sum(portfolio_kzt) as total_portfolio_kzt
    from agg
    group by report_date
)
select
    a.report_date,
    a.program,
    a.loan_count,
    a.portfolio_kzt,
    a.par30_kzt,
    a.par90_kzt,
    a.npl_kzt,
    a.provisions_kzt,
    a.portfolio_kzt / t.total_portfolio_kzt as share_of_portfolio,
    a.par30_kzt / a.portfolio_kzt           as par30_share,
    a.par90_kzt / a.portfolio_kzt           as par90_share,
    a.npl_kzt   / a.portfolio_kzt           as npl_share,
    a.provisions_kzt / a.portfolio_kzt      as provision_coverage
from agg a
join total t on t.report_date = a.report_date
order by a.report_date, a.portfolio_kzt desc;

comment on view reporting.v_metrics_by_program is
    'Метрики портфеля по программам и датам';

-- Разрез по бакетам просрочки: нужен, чтобы сверить сумму провизий по бакетам с итогом
-- и показать на дашборде, из чего складываются провизии.
create or replace view reporting.v_metrics_by_dpd_bucket as
with agg as (
    select
        s.report_date,
        s.dpd_bucket,
        min(s.dpd_bucket_order)                      as dpd_bucket_order,
        count(*) filter (where not s.is_written_off) as loan_count,
        sum(s.principal_kzt_active)                  as portfolio_kzt,
        sum(s.npl_kzt)                               as npl_kzt,
        sum(s.provision_kzt)                         as provisions_kzt
    from reporting.v_loan_snapshot s
    group by s.report_date, s.dpd_bucket
),
total as (
    select report_date, sum(portfolio_kzt) as total_portfolio_kzt
    from agg
    group by report_date
)
select
    a.report_date,
    a.dpd_bucket,
    a.dpd_bucket_order,
    a.loan_count,
    a.portfolio_kzt,
    a.npl_kzt,
    a.provisions_kzt,
    a.portfolio_kzt / t.total_portfolio_kzt as share_of_portfolio
from agg a
join total t on t.report_date = a.report_date
order by a.report_date, a.dpd_bucket_order;

comment on view reporting.v_metrics_by_dpd_bucket is
    'Портфель и провизии по бакетам просрочки (0 / 1–30 / 31–90 / 90+) по датам';
