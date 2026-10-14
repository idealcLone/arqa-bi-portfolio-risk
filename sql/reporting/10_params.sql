-- Единственное место, где живут числовые параметры бизнес-правил.
-- Любое изменение порога или ставки провизий делается здесь и автоматически
-- расходится по всем вьюхам (конфиг вместо кода).
create schema if not exists reporting;

create or replace view reporting.v_params as
select
    30::integer          as dpd_par30_threshold,  -- PAR30: days_past_due СТРОГО больше 30
    90::integer          as dpd_par90_threshold,  -- PAR90 и NPL: days_past_due СТРОГО больше 90
    0.01::numeric(10, 6) as provision_rate_dpd_0_30,   -- 1%  — просрочка до 30 дней
    0.10::numeric(10, 6) as provision_rate_dpd_31_90,  -- 10% — просрочка 31–90 дней
    0.50::numeric(10, 6) as provision_rate_npl,        -- 50% — NPL (приоритет над бакетом DPD)
    10::integer          as top_groups_n,              -- концентрация: топ-10 групп
    '2026-09-01'::date   as base_report_date;          -- база для расчёта изменений

comment on view reporting.v_params is
    'Пороги DPD, ставки провизий, размер топа групп и базовая дата сравнения. Одна строка.';
