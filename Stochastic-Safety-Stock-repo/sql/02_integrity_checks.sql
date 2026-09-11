-- ============================================================
-- Project A: Data Integrity Checks
-- Run these against stg_dataco_raw BEFORE building the
-- dimensional model. Save the actual output (row counts,
-- flagged rows) — that output IS your "data quality problems
-- found" evidence for the README and interview.
-- ============================================================

-- ------------------------------------------------------------
-- CHECK 1: Row count + basic shape sanity check
-- ------------------------------------------------------------
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT order_id) AS distinct_orders,
       COUNT(DISTINCT product_card_id) AS distinct_products,
       COUNT(DISTINCT order_region) AS distinct_regions,
       MIN(order_date) AS earliest_order,
       MAX(order_date) AS latest_order
FROM stg_dataco_raw;

-- ------------------------------------------------------------
-- CHECK 2: NULL profiling across key columns
-- (Run once per column, or use a UNION ALL summary like this)
-- ------------------------------------------------------------
SELECT 'order_date' AS column_name, COUNT(*) AS null_count
FROM stg_dataco_raw WHERE order_date IS NULL
UNION ALL
SELECT 'shipping_date', COUNT(*)
FROM stg_dataco_raw WHERE shipping_date IS NULL
UNION ALL
SELECT 'order_item_quantity', COUNT(*)
FROM stg_dataco_raw WHERE order_item_quantity IS NULL
UNION ALL
SELECT 'product_price', COUNT(*)
FROM stg_dataco_raw WHERE product_price IS NULL
UNION ALL
SELECT 'days_for_shipment_scheduled', COUNT(*)
FROM stg_dataco_raw WHERE days_for_shipment_scheduled IS NULL
UNION ALL
SELECT 'days_for_shipping_real', COUNT(*)
FROM stg_dataco_raw WHERE days_for_shipping_real IS NULL
UNION ALL
SELECT 'order_region', COUNT(*)
FROM stg_dataco_raw WHERE order_region IS NULL OR order_region = '';

-- ------------------------------------------------------------
-- CHECK 3: Duplicate order-item rows
-- (order_item_id should be unique; flag any that aren't)
-- ------------------------------------------------------------
SELECT order_item_id, COUNT(*) AS occurrences
FROM stg_dataco_raw
GROUP BY order_item_id
HAVING COUNT(*) > 1
ORDER BY occurrences DESC;

-- ------------------------------------------------------------
-- CHECK 4: Orphaned / inconsistent product-category mapping
-- A product_card_id should map to exactly ONE category_name.
-- If it maps to more than one, that's the "inconsistent SKU
-- naming/category across source rows" issue to reconcile.
-- ------------------------------------------------------------
SELECT product_card_id, COUNT(DISTINCT category_name) AS distinct_categories
FROM stg_dataco_raw
GROUP BY product_card_id
HAVING COUNT(DISTINCT category_name) > 1;

-- ------------------------------------------------------------
-- CHECK 5: Implausible / outlier values
-- Negative or zero quantity, negative price, shipping before
-- ordering — all should be impossible but frequently aren't.
-- ------------------------------------------------------------
SELECT *
FROM stg_dataco_raw
WHERE order_item_quantity <= 0
   OR product_price < 0
   OR order_item_product_price < 0
   OR shipping_date < order_date;

-- ------------------------------------------------------------
-- CHECK 6: Lead-time deviation outliers
-- (actual - scheduled shipping days) — flag anything beyond
-- +/- 3 standard deviations per region; these are candidates
-- for the "lead-time shock" scenario later, not just noise.
-- ------------------------------------------------------------
WITH lt AS (
    SELECT
        order_region,
        (days_for_shipping_real - days_for_shipment_scheduled) AS lead_time_dev
    FROM stg_dataco_raw
    WHERE days_for_shipping_real IS NOT NULL
      AND days_for_shipment_scheduled IS NOT NULL
),
stats AS (
    SELECT
        order_region,
        AVG(lead_time_dev) AS mean_dev,
        STDDEV(lead_time_dev) AS std_dev          -- SQL Server: STDEV(lead_time_dev)
    FROM lt
    GROUP BY order_region
)
SELECT lt.order_region, lt.lead_time_dev, stats.mean_dev, stats.std_dev
FROM lt
JOIN stats ON lt.order_region = stats.order_region
WHERE ABS(lt.lead_time_dev - stats.mean_dev) > 3 * stats.std_dev;

-- ------------------------------------------------------------
-- CHECK 7: SKU-region pairs with demand but insufficient
-- lead-time observations to fit a distribution reliably
-- (fewer than 30 orders — a real modeling constraint you
-- should surface and handle explicitly, not silently drop)
-- ------------------------------------------------------------
SELECT product_card_id, order_region, COUNT(*) AS n_orders
FROM stg_dataco_raw
GROUP BY product_card_id, order_region
HAVING COUNT(*) < 30
ORDER BY n_orders ASC;

-- ------------------------------------------------------------
-- CHECK 8: Top stockout-risk proxy — using late_delivery_risk
-- as a stand-in signal until the real optimizer is built.
-- Ranks regions by their share of late-flagged orders using
-- a window function (this doubles as your "advanced SQL"
-- portfolio evidence, not just a cleaning query).
-- ------------------------------------------------------------
SELECT order_region,
       late_share,
       RANK() OVER (ORDER BY late_share DESC) AS risk_rank
FROM (
    SELECT
        order_region,
        AVG(CAST(late_delivery_risk AS DECIMAL(5,4))) AS late_share
    FROM stg_dataco_raw
    GROUP BY order_region
) region_risk;
