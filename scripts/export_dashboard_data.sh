#!/usr/bin/env bash
# Выгрузка данных дашборда из вьюх reporting в dashboard/data/*.json.
# В спеках Vega-Lite нет ни одного числа — все цифры приезжают только отсюда.
# Вывод детерминирован (сортировка + jsonb_pretty, без таймстемпов), поэтому
# повторный прогон не создаёт diff, а CI может сверять закоммиченный JSON с пересчитанным.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
export PGPASSWORD="$POSTGRES_PASSWORD"
PSQL=(psql -X -q -A -t -v ON_ERROR_STOP=1 -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB")

mkdir -p dashboard/data

dump() {  # dump <файл> <SQL, возвращающий одну строку jsonb>
  local out="dashboard/data/$1"; shift
  "${PSQL[@]}" -c "$1" > "$out"
  # Пустой или битый результат — это ошибка выгрузки, а не «пустой дашборд»
  if [ ! -s "$out" ] || [ "$(head -c 2 "$out")" = "" ]; then
    echo "ОШИБКА: $out пуст" >&2; exit 1
  fi
  printf '  %-22s %6s строк JSON\n' "$1" "$(wc -l < "$out" | tr -d ' ')" >/dev/null
  echo "  dashboard/data/$(basename "$out") — $(wc -c < "$out" | tr -d ' ') байт"
}

dump metrics.json "
  select jsonb_pretty(jsonb_agg(to_jsonb(t) order by t.report_date))
  from (
    select
      report_date::text                      as report_date,
      to_char(report_date, 'DD.MM.YYYY')     as report_date_label,
      loan_count, borrower_count, group_count,
      portfolio_kzt, par30_kzt, par90_kzt, npl_kzt, provisions_kzt,
      par30_share, par90_share, npl_share, provision_coverage,
      top10_exposure_kzt, top10_group_share,
      written_off_count, written_off_kzt,
      usd_portfolio_kzt, usd_principal_usd, usd_share, usd_rate_kzt,
      past_maturity_kzt,
      portfolio_kzt_chg, provisions_kzt_chg, loan_count_chg,
      par30_share_chg_pp, par90_share_chg_pp, npl_share_chg_pp, top10_group_share_chg_pp
    from reporting.v_portfolio_metrics
  ) t"

dump by_sector.json "
  select jsonb_pretty(jsonb_agg(to_jsonb(t) order by t.report_date, t.portfolio_kzt desc))
  from (
    select report_date::text as report_date, to_char(report_date, 'DD.MM.YYYY') as report_date_label, sector, loan_count,
           portfolio_kzt, par30_kzt, par90_kzt, npl_kzt, provisions_kzt,
           share_of_portfolio, par30_share, par90_share, npl_share, provision_coverage
    from reporting.v_metrics_by_sector
  ) t"

dump by_program.json "
  select jsonb_pretty(jsonb_agg(to_jsonb(t) order by t.report_date, t.portfolio_kzt desc))
  from (
    select report_date::text as report_date, to_char(report_date, 'DD.MM.YYYY') as report_date_label, program, loan_count,
           portfolio_kzt, par30_kzt, par90_kzt, npl_kzt, provisions_kzt,
           share_of_portfolio, par30_share, par90_share, npl_share, provision_coverage
    from reporting.v_metrics_by_program
  ) t"

dump top_groups.json "
  select jsonb_pretty(jsonb_agg(to_jsonb(t) order by t.report_date, t.exposure_rank))
  from (
    select report_date::text as report_date, to_char(report_date, 'DD.MM.YYYY') as report_date_label, exposure_rank, group_id,
           exposure_kzt, loan_count, borrower_count, share_of_portfolio
    from reporting.v_top_groups
  ) t"

dump by_dpd_bucket.json "
  select jsonb_pretty(jsonb_agg(to_jsonb(t) order by t.report_date, t.dpd_bucket_order))
  from (
    select report_date::text as report_date, to_char(report_date, 'DD.MM.YYYY') as report_date_label, dpd_bucket, dpd_bucket_order,
           loan_count, portfolio_kzt, npl_kzt, provisions_kzt, share_of_portfolio
    from reporting.v_metrics_by_dpd_bucket
  ) t"

echo "Выгружено из reporting.* в dashboard/data/"
