{{ config(materialized='view') }}

with source_rows as (
    select
        price_date,
        upper(trim(ticker)) as ticker,
        open,
        high,
        low,
        close,
        volume,
        adjusted_close,
        _source_file_key,
        _source_file_id,
        _source_file_name,
        _source_checksum,
        _source_modified_time,
        _ingested_at
    from {{ source('raw', 'market_prices') }}
    where price_date is not null
      and ticker is not null
      and trim(ticker) != ''
)

select *
from source_rows
qualify row_number() over (
    partition by price_date, ticker
    order by _ingested_at desc, _source_file_key desc
) = 1

