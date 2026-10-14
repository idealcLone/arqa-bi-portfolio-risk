-- Проверка 4: внутренняя логика метрик. Это те инварианты, нарушение которых
-- означает ошибку в определениях (например, перепутанные пороги или знаменатели).
\set ON_ERROR_STOP on
do $$
declare
    r record;
    v_cnt bigint;
begin
    for r in select * from reporting.v_portfolio_metrics loop
        -- 4.1 PAR30 ⊇ PAR90 (dpd > 30 включает dpd > 90)
        if r.par30_kzt < r.par90_kzt then
            raise exception '% PAR30 (%) < PAR90 (%)', r.report_date, r.par30_kzt, r.par90_kzt;
        end if;
        -- 4.2 NPL ⊇ PAR90 (NPL = PAR90 ИЛИ реструктуризация)
        if r.npl_kzt < r.par90_kzt then
            raise exception '% NPL (%) < PAR90 (%)', r.report_date, r.npl_kzt, r.par90_kzt;
        end if;
        -- 4.3 все доли в [0, 1]
        if r.par30_share < 0 or r.par30_share > 1
           or r.par90_share < 0 or r.par90_share > 1
           or r.npl_share < 0 or r.npl_share > 1
           or r.top10_group_share < 0 or r.top10_group_share > 1
           or r.provision_coverage < 0 or r.provision_coverage > 1 then
            raise exception '% доля вне [0,1]: par30=% par90=% npl=% top10=% prov=%',
                r.report_date, r.par30_share, r.par90_share, r.npl_share,
                r.top10_group_share, r.provision_coverage;
        end if;
        -- 4.4 провизии не могут превышать портфель и не могут быть меньше 1% портфеля
        --     (минимальная ставка — 1%, значит провизии >= 1% портфеля всегда)
        if r.provisions_kzt > r.portfolio_kzt then
            raise exception '% провизии (%) больше портфеля (%)', r.report_date, r.provisions_kzt, r.portfolio_kzt;
        end if;
        if r.provisions_kzt < r.portfolio_kzt * 0.01 then
            raise exception '% провизии (%) меньше 1%% портфеля (%)', r.report_date, r.provisions_kzt, r.portfolio_kzt * 0.01;
        end if;
        -- 4.5 портфель и число кредитов положительны
        if r.portfolio_kzt <= 0 or r.loan_count <= 0 then
            raise exception '% портфель=% кредитов=%', r.report_date, r.portfolio_kzt, r.loan_count;
        end if;
        raise notice 'OK 4: % — PAR30 >= PAR90, NPL >= PAR90, доли в [0,1], провизии в границах', r.report_date;
    end loop;

    -- 4.6 ставка провизий строго соответствует бизнес-правилу (приоритет NPL)
    select count(*) into v_cnt
    from reporting.v_loan_snapshot
    where provision_rate <> case
            when is_npl then 0.50
            when days_past_due between 31 and 90 then 0.10
            when days_past_due <= 30 then 0.01
          end;
    if v_cnt > 0 then
        raise exception 'Кредитов с неверной ставкой провизий: %', v_cnt;
    end if;

    -- 4.7 реструктуризация с DPD = 0 обязана получить 50% (контрольный случай из задания)
    select count(*) into v_cnt
    from reporting.v_loan_snapshot
    where restructured = 1 and days_past_due = 0 and provision_rate <> 0.50;
    if v_cnt > 0 then
        raise exception 'Реструктуризаций с DPD=0 и ставкой <> 50%%: %', v_cnt;
    end if;
    select count(*) into v_cnt
    from reporting.v_loan_snapshot
    where restructured = 1 and days_past_due = 0 and not is_npl;
    if v_cnt > 0 then
        raise exception 'Реструктуризаций с DPD=0, не попавших в NPL: %', v_cnt;
    end if;

    -- 4.8 флаги согласованы с порогами
    select count(*) into v_cnt from reporting.v_loan_snapshot
     where is_par30 <> (days_past_due > 30)
        or is_par90 <> (days_past_due > 90)
        or is_npl   <> (days_past_due > 90 or restructured = 1);
    if v_cnt > 0 then
        raise exception 'Кредитов с флагами, не совпадающими с порогами: %', v_cnt;
    end if;

    -- 4.9 списанные не дают вклада ни в одну денежную меру
    select count(*) into v_cnt from reporting.v_loan_snapshot
     where is_written_off
       and (principal_kzt_active <> 0 or par30_kzt <> 0 or par90_kzt <> 0
            or npl_kzt <> 0 or provision_kzt <> 0 or active_loan_flag <> 0);
    if v_cnt > 0 then
        raise exception 'Списанных кредитов с ненулевым вкладом в меры: %', v_cnt;
    end if;

    -- 4.10 списанные вообще не попали в портфель метрик
    select count(*) into v_cnt
    from reporting.v_portfolio_metrics m
    where m.portfolio_kzt <> (
        select sum(principal_kzt) from reporting.v_loan_snapshot s
         where s.report_date = m.report_date and not s.is_written_off);
    if v_cnt > 0 then
        raise exception 'Портфель в метриках не равен сумме непросписанных кредитов витрины';
    end if;

    raise notice 'OK 4.6–4.10: ставки провизий, флаги PAR/NPL и исключение списанных корректны';
end $$;
