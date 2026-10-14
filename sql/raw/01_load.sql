-- Идемпотентная загрузка CSV: TRUNCATE + \copy в одной транзакции.
-- Повторный запуск даёт ровно то же содержимое, частичной загрузки не бывает.
\set ON_ERROR_STOP on
begin;

truncate table raw.portfolio;
truncate table raw.fx;

\copy raw.portfolio (report_date, loan_id, borrower_id, group_id, sector, program, currency, issue_date, maturity_date, principal_outstanding, days_past_due, restructured, written_off) from 'data/portfolio.csv' with (format csv, header true)
\copy raw.fx (date, currency, rate_kzt) from 'data/fx.csv' with (format csv, header true)

commit;

-- Контроль загрузки: ожидаем ровно то, что насчитал профилировщик.
do $$
declare
    v_portfolio bigint;
    v_fx        bigint;
begin
    select count(*) into v_portfolio from raw.portfolio;
    select count(*) into v_fx from raw.fx;
    if v_portfolio <> 4060 then
        raise exception 'raw.portfolio: загружено % строк, ожидалось 4060', v_portfolio;
    end if;
    if v_fx <> 42 then
        raise exception 'raw.fx: загружено % строк, ожидалось 42', v_fx;
    end if;
    raise notice 'raw загружен: portfolio=% строк, fx=% строк', v_portfolio, v_fx;
end $$;
