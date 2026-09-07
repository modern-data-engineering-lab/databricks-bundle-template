-- Gold layer: orders aggregated by region and value band.
CREATE OR REFRESH MATERIALIZED VIEW sales_by_region_band
AS
SELECT
    region,
    order_value_band,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM LIVE.orders_silver
GROUP BY region, order_value_band
