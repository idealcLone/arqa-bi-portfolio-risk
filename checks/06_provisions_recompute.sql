-- Проверка 6: провизии пересчитаны независимо (без хелпер-колонки provision_kzt)
-- и сверены с итогом, плюс разложение по ставкам.
\set ON_ERROR_STOP on
do $$
declare
    r record;
begin
    for r in
        with independent as (
            select
                s.report_date,
                sum(round(s.principal_kzt *
                    case
                        when s.days_past_due > 90 or s.restructured = 1 then 0.50
                        when s.days_past_due > 30                       then 0.10
                        else                                                 0.01
                    end, 2)) as provisions_kzt
            from reporting.v_loan_snapshot s
            where s.written_off = 0
            group by s.report_date
        )
        select m.report_date, m.provisions_kzt as view_kzt, i.provisions_kzt as independent_kzt
        from reporting.v_portfolio_metrics m
        join independent i on i.report_date = m.report_date
    loop
        if r.view_kzt <> r.independent_kzt then
            raise exception '% провизии: вьюха % <> независимый пересчёт %',
                r.report_date, r.view_kzt, r.independent_kzt;
        end if;
        raise notice 'OK 6: % провизии % ₸ подтверждены независимым пересчётом', r.report_date, r.view_kzt;
    end loop;

    -- 6.1 разложение провизий по ставкам складывается в итог
    for r in
        select
            s.report_date,
            sum(s.provision_kzt) as total,
            sum(s.provision_kzt) filter (where s.provision_rate = 0.50) as npl_part,
            sum(s.provision_kzt) filter (where s.provision_rate = 0.10) as mid_part,
            sum(s.provision_kzt) filter (where s.provision_rate = 0.01) as low_part
        from reporting.v_loan_snapshot s
        group by s.report_date
    loop
        if r.total <> coalesce(r.npl_part,0) + coalesce(r.mid_part,0) + coalesce(r.low_part,0) then
            raise exception '% провизии по ставкам не складываются в итог', r.report_date;
        end if;
        raise notice 'OK 6.1: % провизии по ставкам: 50%%=% / 10%%=% / 1%%=%',
            r.report_date, r.npl_part, r.mid_part, r.low_part;
    end loop;
end $$;
