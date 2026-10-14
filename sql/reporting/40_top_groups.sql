-- Концентрация: топ-N (по умолчанию 10) групп связанных заёмщиков внутри каждой даты.
-- Ранжирование по KZT-экспозиции; знаменатель доли — весь непросписанный портфель этой даты,
-- то есть тот же, что у PAR30/PAR90/NPL.
create or replace view reporting.v_group_exposure as
with base as (
    select
        s.report_date,
        s.group_id,
        sum(s.principal_kzt_active) as exposure_kzt,
        count(*) filter (where not s.is_written_off) as loan_count,
        count(distinct s.borrower_id) filter (where not s.is_written_off) as borrower_count
    from reporting.v_loan_snapshot s
    group by s.report_date, s.group_id
    having sum(s.principal_kzt_active) > 0   -- группы, целиком состоящие из списаний, в портфеле не участвуют
),
total as (
    select
        report_date,
        sum(exposure_kzt) as portfolio_kzt
    from base
    group by report_date
)
select
    b.report_date,
    b.group_id,
    b.exposure_kzt,
    b.loan_count,
    b.borrower_count,
    b.exposure_kzt / t.portfolio_kzt as share_of_portfolio,
    row_number() over (
        partition by b.report_date
        order by b.exposure_kzt desc, b.group_id   -- group_id добивает сортировку, чтобы ранг был детерминирован
    ) as exposure_rank
from base b
join total t on t.report_date = b.report_date;

comment on view reporting.v_group_exposure is
    'Экспозиция и доля каждой группы связанных заёмщиков по датам, с рангом';

create or replace view reporting.v_top_groups as
select
    g.report_date,
    g.exposure_rank,
    g.group_id,
    g.exposure_kzt,
    g.loan_count,
    g.borrower_count,
    g.share_of_portfolio
from reporting.v_group_exposure g
cross join reporting.v_params prm
where g.exposure_rank <= prm.top_groups_n
order by g.report_date, g.exposure_rank;

comment on view reporting.v_top_groups is
    'Топ-10 групп связанных заёмщиков на каждую дату: экспозиция и доля в портфеле';
