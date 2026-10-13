{{ config(
    materialized='table',
    partition_by={"field": "price_date", "data_type": "date"},
    cluster_by=["ticker"]
) }}

with prices as (
    select
        price_date,
        ticker,
        open,
        high,
        low,
        close,
        adjusted_close,
        coalesce(adjusted_close, close) as return_price,
        volume,
        _source_file_name,
        _ingested_at
    from {{ ref('stg_market_prices') }}
),

with_previous_close as (
    select
        *,
        lag(return_price) over (
            partition by ticker
            order by price_date
        ) as previous_close
    from prices
)

select
    price_date,
    ticker,
    open,
    high,
    low,
    close,
    adjusted_close,
    previous_close,
    safe_divide(return_price - previous_close, previous_close) as daily_return,
    safe_divide(return_price - previous_close, previous_close) * 100 as daily_return_pct,
    volume,
    _source_file_name,
    _ingested_at
from with_previous_close

