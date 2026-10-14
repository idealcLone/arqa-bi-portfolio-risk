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

create schema if not exists raw;

drop table if exists raw.portfolio;
create table raw.portfolio (
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

drop table if exists raw.fx;
create table raw.fx (
    date     date           not null,
    currency text           not null,
    rate_kzt numeric(20, 6) not null
);
comment on table raw.fx is 'Сырой fx.csv 1:1: дневные курсы к тенге';
