-- Нормализованные курсы к тенге: одна строка на (дата, валюта).
-- KZT в fx.csv отсутствует и не должен там быть — добавляем его как курс 1,
-- чтобы в витрине не было ветвления «если тенге, то не конвертировать».
create or replace view reporting.v_fx as
with fx_raw as (
    select
        f.date                      as rate_date,
        upper(btrim(f.currency))    as currency,
        f.rate_kzt,
        -- защита от дублей (date, currency): берём максимум по курсу детерминированно.
        -- На текущих данных дублей 0 (см. docs/data_quality.md A6), правило — страховка.
        row_number() over (
            partition by f.date, upper(btrim(f.currency))
            order by f.rate_kzt desc
        ) as rn
    from raw.fx f
    where f.rate_kzt > 0
)
select
    rate_date,
    currency,
    rate_kzt
from fx_raw
where rn = 1
union all
-- Тенге к тенге: курс 1 на каждую дату, встречающуюся в срезах портфеля.
select distinct
    p.report_date as rate_date,
    'KZT'::text   as currency,
    1::numeric    as rate_kzt
from raw.portfolio p;

comment on view reporting.v_fx is
    'Курсы к KZT, по одной строке на (дата, валюта), включая синтетический KZT = 1';
