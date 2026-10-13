{{ config(
    materialized='table',
    partition_by={"field": "month", "data_type": "date"},
    cluster_by=["ticker"]
) }}

with monthly as (
    select
        ticker,
        date_trunc(price_date, month) as month,
        array_agg(coalesce(adjusted_close, close) order by price_date asc limit 1)[offset(0)] as first_close,
        array_agg(coalesce(adjusted_close, close) order by price_date desc limit 1)[offset(0)] as last_close,
        avg(daily_return) as average_daily_return,
        stddev_samp(daily_return) as daily_return_volatility,
        sum(volume) as total_volume,
        count(*) as trading_days
    from {{ ref('fct_daily_returns') }}
    group by ticker, month
)

select
    *,
    safe_divide(
        last_close - lag(last_close) over (partition by ticker order by month),
        lag(last_close) over (partition by ticker order by month)
    ) as monthly_return
from monthly
