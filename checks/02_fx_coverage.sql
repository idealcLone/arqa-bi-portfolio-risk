-- Проверка 2: конвертация валют. Падает, если хоть один кредит остался без курса
-- или сконвертирован не по курсу на дату среза.
\set ON_ERROR_STOP on
do $$
declare
    v_missing   bigint;
    v_bad_kzt   bigint;
    v_bad_conv  bigint;
    v_wrong_day bigint;
    v_cur       text;
begin
    -- 2.1 нет кредита без курса (LEFT JOIN в витрине оставил бы NULL)
    select count(*) into v_missing from reporting.v_loan_snapshot where rate_kzt is null;
    if v_missing > 0 then
        select string_agg(distinct currency, ', ') into v_cur
        from reporting.v_loan_snapshot where rate_kzt is null;
        raise exception 'Кредитов без курса на дату среза: % (валюты: %)', v_missing, v_cur;
    end if;
    -- 2.2 тенге конвертируется ровно по курсу 1
    select count(*) into v_bad_kzt from reporting.v_loan_snapshot
     where currency = 'KZT' and (rate_kzt <> 1 or principal_kzt <> principal_outstanding);
    if v_bad_kzt > 0 then
        raise exception 'KZT-кредитов с курсом <> 1 или изменённой суммой: %', v_bad_kzt;
    end if;
    -- 2.3 каждый неKZT-кредит действительно пересчитан (курс > 0 и сумма изменилась)
    select count(*) into v_bad_conv from reporting.v_loan_snapshot
     where currency <> 'KZT'
       and (rate_kzt <= 0 or principal_kzt <> round(principal_outstanding * rate_kzt, 2));
    if v_bad_conv > 0 then
        raise exception 'НеKZT-кредитов с некорректной конвертацией: %', v_bad_conv;
    end if;
    -- 2.4 использован курс именно на дату среза, а не на какую-то другую дату
    select count(*) into v_wrong_day
    from reporting.v_loan_snapshot s
    join raw.fx f on upper(btrim(f.currency)) = s.currency and f.date = s.report_date
    where s.currency <> 'KZT' and s.rate_kzt <> f.rate_kzt;
    if v_wrong_day > 0 then
        raise exception 'Кредитов, где курс не совпал с fx.csv на дату среза: %', v_wrong_day;
    end if;

    raise notice 'OK 2: все кредиты сконвертированы по курсу на дату среза, кредитов без курса 0';
end $$;
