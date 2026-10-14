-- Проверка 3: аддитивность. Суммы по любому разрезу обязаны совпадать с итогом даты
-- до копейки — иначе где-то разные знаменатели или потерянные строки.
\set ON_ERROR_STOP on
do $$
declare
    r record;
begin
    -- 3.1 портфель: итог = Σ по отраслям = Σ по программам = Σ по бакетам DPD = Σ по группам
    for r in
        with t as (select report_date, portfolio_kzt, provisions_kzt, par30_kzt, par90_kzt, npl_kzt
                   from reporting.v_portfolio_metrics)
        select
            t.report_date,
            t.portfolio_kzt,
            (select sum(portfolio_kzt) from reporting.v_metrics_by_sector  s where s.report_date = t.report_date) as by_sector,
            (select sum(portfolio_kzt) from reporting.v_metrics_by_program p where p.report_date = t.report_date) as by_program,
            (select sum(portfolio_kzt) from reporting.v_metrics_by_dpd_bucket b where b.report_date = t.report_date) as by_bucket,
            (select sum(exposure_kzt)  from reporting.v_group_exposure g where g.report_date = t.report_date)     as by_group,
            t.provisions_kzt,
            (select sum(provisions_kzt) from reporting.v_metrics_by_dpd_bucket b where b.report_date = t.report_date) as prov_by_bucket,
            (select sum(provisions_kzt) from reporting.v_metrics_by_sector  s where s.report_date = t.report_date)    as prov_by_sector,
            t.par30_kzt,
            (select sum(par30_kzt) from reporting.v_metrics_by_sector s where s.report_date = t.report_date) as par30_by_sector,
            t.par90_kzt,
            (select sum(par90_kzt) from reporting.v_metrics_by_program p where p.report_date = t.report_date) as par90_by_program,
            t.npl_kzt,
            (select sum(npl_kzt) from reporting.v_metrics_by_sector s where s.report_date = t.report_date) as npl_by_sector
        from t
    loop
        if r.portfolio_kzt <> r.by_sector then
            raise exception '% портфель: итог % <> Σ по отраслям %', r.report_date, r.portfolio_kzt, r.by_sector;
        end if;
        if r.portfolio_kzt <> r.by_program then
            raise exception '% портфель: итог % <> Σ по программам %', r.report_date, r.portfolio_kzt, r.by_program;
        end if;
        if r.portfolio_kzt <> r.by_bucket then
            raise exception '% портфель: итог % <> Σ по бакетам DPD %', r.report_date, r.portfolio_kzt, r.by_bucket;
        end if;
        if r.portfolio_kzt <> r.by_group then
            raise exception '% портфель: итог % <> Σ по группам %', r.report_date, r.portfolio_kzt, r.by_group;
        end if;
        if r.provisions_kzt <> r.prov_by_bucket then
            raise exception '% провизии: итог % <> Σ по бакетам %', r.report_date, r.provisions_kzt, r.prov_by_bucket;
        end if;
        if r.provisions_kzt <> r.prov_by_sector then
            raise exception '% провизии: итог % <> Σ по отраслям %', r.report_date, r.provisions_kzt, r.prov_by_sector;
        end if;
        if r.par30_kzt <> r.par30_by_sector then
            raise exception '% PAR30: итог % <> Σ по отраслям %', r.report_date, r.par30_kzt, r.par30_by_sector;
        end if;
        if r.par90_kzt <> r.par90_by_program then
            raise exception '% PAR90: итог % <> Σ по программам %', r.report_date, r.par90_kzt, r.par90_by_program;
        end if;
        if r.npl_kzt <> r.npl_by_sector then
            raise exception '% NPL: итог % <> Σ по отраслям %', r.report_date, r.npl_kzt, r.npl_by_sector;
        end if;
        raise notice 'OK 3: % — портфель и все метрики аддитивны по отраслям, программам, бакетам и группам (%)',
            r.report_date, r.portfolio_kzt;
    end loop;

    -- 3.2 доли разрезов складываются в 1
    for r in
        select report_date, sum(share_of_portfolio) as s from reporting.v_metrics_by_sector group by report_date
        union all
        select report_date, sum(share_of_portfolio) from reporting.v_metrics_by_program group by report_date
    loop
        if abs(r.s - 1) > 1e-9 then
            raise exception '% сумма долей разреза = %, ожидалось 1', r.report_date, r.s;
        end if;
    end loop;
    raise notice 'OK 3.2: доли по отраслям и программам складываются в 1';
end $$;
