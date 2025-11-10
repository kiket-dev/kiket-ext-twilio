{{
  config(
    materialized='incremental',
    unique_key=['delivery_date', 'message_type']
  )
}}

select
  date(sent_at) as delivery_date,
  message_type,
  count(*) as total_sent,
  count(case when status = 'delivered' then 1 end) as delivered_count,
  count(case when status = 'failed' then 1 end) as failed_count,
  count(distinct recipient) as unique_recipients,
  round(100.0 * count(case when status = 'delivered' then 1 end) / nullif(count(*), 0), 2) as delivery_rate_pct
from {{ source('twilio_deliveries', 'deliveries') }}
where sent_at is not null
{% if is_incremental() %}
  and sent_at >= (select max(delivery_date) - interval '7 days' from {{ this }})
{% endif %}
group by 1, 2
