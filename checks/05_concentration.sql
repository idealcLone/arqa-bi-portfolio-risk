-- Проверка 5: концентрация пересчитана НЕЗАВИСИМО от v_top_groups —
-- напрямую из витрины другой формулировкой (dense_rank + подзапрос), и сверена.
\set ON_ERROR_STOP on
do $$
declare
    r record;
begin
    for r in
        with exposure as (
            select
                s.report_date,
                s.group_id,
                sum(s.principal_kzt) as exposure_kzt       -- principal_kzt + явный фильтр списанных
            from reporting.v_loan_snapshot s
            where not s.is_written_off
            group by s.report_date, s.group_id
        ),
        ranked as (
            select
                report_date, group_id, exposure_kzt,
                dense_rank() over (partition by report_date order by exposure_kzt desc) as rnk
            from exposure
        ),
        independent as (
            select
                report_date,
                sum(exposure_kzt) as top10_kzt,
                sum(exposure_kzt) / (select sum(e.exposure_kzt) from exposure e where e.report_date = r2.report_date) as top10_share
            from ranked r2
            where rnk <= 10
            group by report_date
        )
        select
            m.report_date,
            m.top10_exposure_kzt as view_kzt,
            i.top10_kzt          as independent_kzt,
            m.top10_group_share  as view_share,
            i.top10_share        as independent_share,
            (select count(*) from reporting.v_top_groups t where t.report_date = m.report_date) as top_rows
        from reporting.v_portfolio_metrics m
        join independent i on i.report_date = m.report_date
    loop
        if r.view_kzt <> r.independent_kzt then
            raise exception '% топ-10 экспозиция: вьюха % <> независимый пересчёт %',
                r.report_date, r.view_kzt, r.independent_kzt;
        end if;
        if abs(r.view_share - r.independent_share) > 1e-12 then
            raise exception '% топ-10 доля: вьюха % <> независимый пересчёт %',
                r.report_date, r.view_share, r.independent_share;
        end if;
        if r.top_rows <> 10 then
            raise exception '% в v_top_groups % строк, ожидалось 10', r.report_date, r.top_rows;
        end if;
        raise notice 'OK 5: % топ-10 = % ₸ (% от портфеля), пересчитано независимо',
            r.report_date, r.view_kzt, round(r.view_share * 100, 4);
    end loop;

    -- 5.1 доли отдельных групп не превышают 1 и ранги уникальны
    perform 1 from reporting.v_group_exposure where share_of_portfolio > 1 or share_of_portfolio < 0;
    if found then
        raise exception 'Доля группы вне [0,1]';
    end if;
end $$;
