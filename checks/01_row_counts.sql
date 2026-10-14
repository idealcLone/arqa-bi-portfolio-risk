-- Проверка 1: объёмы и дедупликация. Падает, если витрина потеряла или размножила строки.
\set ON_ERROR_STOP on
do $$
declare
    v_raw          bigint;
    v_raw_keys     bigint;
    v_mart         bigint;
    v_mart_keys    bigint;
    v_dates        bigint;
    v_nulls        bigint;
begin
    select count(*) into v_raw from raw.portfolio;
    select count(*) into v_raw_keys from (select distinct report_date, btrim(loan_id) from raw.portfolio) q;
    select count(*) into v_mart from reporting.v_loan_snapshot;
    select count(*) into v_mart_keys from (select distinct report_date, loan_id from reporting.v_loan_snapshot) q;
    select count(distinct report_date) into v_dates from reporting.v_loan_snapshot;

    -- 1.1 витрина = по одной строке на уникальный ключ raw
    if v_mart <> v_raw_keys then
        raise exception 'Строк в витрине (%) не равно числу уникальных ключей raw (%)', v_mart, v_raw_keys;
    end if;
    -- 1.2 ключ витрины уникален
    if v_mart <> v_mart_keys then
        raise exception 'Ключ (report_date, loan_id) в витрине не уникален: % строк, % ключей', v_mart, v_mart_keys;
    end if;
    -- 1.3 удалено ровно столько дублей, сколько нашёл профилировщик (docs/data_quality.md A1)
    if v_raw - v_mart <> 60 then
        raise exception 'Удалено % дублей, ожидалось 60', v_raw - v_mart;
    end if;
    -- 1.4 обе даты среза на месте
    if v_dates <> 2 then
        raise exception 'Дат среза в витрине: %, ожидалось 2', v_dates;
    end if;
    -- 1.5 ни одного NULL в ключевых и денежных колонках
    select count(*) into v_nulls
    from reporting.v_loan_snapshot
    where report_date is null or loan_id is null or group_id is null or sector is null
       or program is null or currency is null or principal_kzt is null
       or provision_rate is null or dpd_bucket is null or rate_kzt is null;
    if v_nulls > 0 then
        raise exception 'NULL в обязательных колонках витрины: % строк', v_nulls;
    end if;

    raise notice 'OK 1: raw=% строк (% ключей) → витрина=% строк, удалено % дублей, дат %',
        v_raw, v_raw_keys, v_mart, v_raw - v_mart, v_dates;
end $$;
