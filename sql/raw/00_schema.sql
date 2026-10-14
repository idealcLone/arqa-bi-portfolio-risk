-- Схема raw: зеркало CSV, без какой-либо очистки.
-- Дубликаты, списанные кредиты и прочие аномалии ОСТАЮТСЯ здесь как есть —
-- вся очистка живёт в reporting.v_loan_snapshot, чтобы её можно было проверить.
--
-- Почему типизированные колонки, а не text-first:
-- профилировщик (scripts/profile_data.py) показал 0 непарсящихся значений во всех
-- колонках обоих файлов (даты, numeric, int). Типы здесь работают как бесплатный
-- ассерт на загрузке: если источник однажды приедет с мусором, \copy упадёт громко,
-- а не протащит мусор в витрину. Деньги и курсы — numeric, никогда float.
-- Первичных ключей нет сознательно: в raw ключ (report_date, loan_id) НЕ уникален.
--
-- Идемпотентность: CREATE TABLE IF NOT EXISTS, а не DROP + CREATE.
-- DROP здесь ломает повторный прогон — на таблицах висят вьюхи reporting
-- (а DROP ... CASCADE снёс бы весь слой отчётности из-за перезагрузки данных).
-- Данные обновляются TRUNCATE + \copy в sql/raw/01_load.sql.
-- Если структура таблиц изменилась, блок проверки ниже скажет об этом явно,
-- и пересоздать БД нужно командой `make down && make all`.

create schema if not exists raw;

create table if not exists raw.portfolio (
    report_date           date           not null,
    loan_id               text           not null,
    borrower_id           text           not null,
    group_id              text           not null,
    sector                text           not null,
    program               text           not null,
    currency              text           not null,
    issue_date            date           not null,
    maturity_date         date           not null,
    principal_outstanding numeric(20, 2) not null,
    days_past_due         integer        not null,
    restructured          smallint       not null,
    written_off           smallint       not null
);
comment on table raw.portfolio is 'Сырой portfolio.csv 1:1, включая 60 полных дублей строк';

create table if not exists raw.fx (
    date     date           not null,
    currency text           not null,
    rate_kzt numeric(20, 6) not null
);
comment on table raw.fx is 'Сырой fx.csv 1:1: дневные курсы к тенге';

-- Контракт структуры: существующая таблица должна совпадать с DDL выше.
-- Иначе загрузка молча поехала бы по другим колонкам.
do $$
declare
    v_portfolio text;
    v_fx        text;
    v_expected_portfolio constant text :=
        'report_date:date,loan_id:text,borrower_id:text,group_id:text,sector:text,'
        'program:text,currency:text,issue_date:date,maturity_date:date,'
        'principal_outstanding:numeric,days_past_due:integer,restructured:smallint,written_off:smallint';
    v_expected_fx constant text := 'date:date,currency:text,rate_kzt:numeric';
begin
    select string_agg(column_name || ':' || data_type, ',' order by ordinal_position)
      into v_portfolio
      from information_schema.columns
     where table_schema = 'raw' and table_name = 'portfolio';

    select string_agg(column_name || ':' || data_type, ',' order by ordinal_position)
      into v_fx
      from information_schema.columns
     where table_schema = 'raw' and table_name = 'fx';

    if v_portfolio is distinct from v_expected_portfolio then
        raise exception E'Структура raw.portfolio отличается от DDL.\nВ БД:  %\nЖдали: %\nПересоздай БД: make down && make all', v_portfolio, v_expected_portfolio;
    end if;
    if v_fx is distinct from v_expected_fx then
        raise exception E'Структура raw.fx отличается от DDL.\nВ БД:  %\nЖдали: %\nПересоздай БД: make down && make all', v_fx, v_expected_fx;
    end if;
    raise notice 'OK: структура raw.portfolio и raw.fx соответствует DDL';
end $$;
