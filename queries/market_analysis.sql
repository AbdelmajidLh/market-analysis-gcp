-- Adapter le project_id et les noms de datasets à votre configuration.

-- 1. Dernière séance connue par ticker.
select
  ticker,
  max(price_date) as latest_price_date,
  array_agg(close order by price_date desc limit 1)[offset(0)] as latest_close
from `project-b2238b62-da1a-46fc-a02.market_analysis_marts.fct_daily_returns`
group by ticker
order by ticker;

-- 2. Performance mensuelle (les rendements sont des ratios: 0.05 = +5 %).
select
  ticker,
  month,
  monthly_return,
  average_daily_return,
  daily_return_volatility,
  total_volume,
  trading_days
from `project-b2238b62-da1a-46fc-a02.market_analysis_marts.mart_monthly_performance`
where month >= date_sub(date_trunc(current_date(), month), interval 12 month)
order by month desc, monthly_return desc;

-- 3. Classement des tickers sur les 30 dernières séances disponibles.
with recent as (
  select
    ticker,
    price_date,
    daily_return,
    row_number() over (partition by ticker order by price_date desc) as day_rank
  from `project-b2238b62-da1a-46fc-a02.market_analysis_marts.fct_daily_returns`
  where price_date >= date_sub(current_date(), interval 45 day)
)
select
  ticker,
  countif(daily_return is not null) as observations,
  exp(sum(ln(1 + daily_return))) - 1 as compounded_return,
  stddev_samp(daily_return) as daily_volatility
from recent
where day_rank <= 30
  and daily_return > -1
group by ticker
order by compounded_return desc;

-- 4. Jours à forte variation pour revue.
select
  price_date,
  ticker,
  close,
  previous_close,
  daily_return_pct,
  volume
from `project-b2238b62-da1a-46fc-a02.market_analysis_marts.fct_daily_returns`
where price_date >= date_sub(current_date(), interval 90 day)
  and abs(daily_return_pct) >= 5
order by abs(daily_return_pct) desc;

-- 5. Couverture de l'historique dans le modèle de staging.
select
  ticker,
  min(price_date) as first_date,
  max(price_date) as last_date,
  count(*) as rows_in_latest_version,
  countif(close is null) as missing_close,
  countif(volume is null) as missing_volume,
  max(_ingested_at) as last_ingestion
from `project-b2238b62-da1a-46fc-a02.market_analysis_marts.stg_market_prices`
group by ticker
order by ticker;

