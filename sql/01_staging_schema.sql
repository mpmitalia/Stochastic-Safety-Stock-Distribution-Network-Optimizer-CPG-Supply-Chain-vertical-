-- ============================================================
-- Project A: Stochastic Safety-Stock & Distribution Optimizer
-- Staging + Dimensional Schema for the DataCo Smart Supply
-- Chain dataset (Kaggle: shashwatwork/dataco-smart-supply-
-- chain-for-big-data-analysis)
-- Target: MySQL / SQL Server compatible (minor tweaks noted)
-- ============================================================

-- ------------------------------------------------------------
-- 1. RAW STAGING TABLE
-- Load the CSV in with NO transformation — this is your
-- "as received from the client" layer. Every integrity check
-- in 02_integrity_checks.sql runs against this table first.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS stg_dataco_raw;

CREATE TABLE stg_dataco_raw (
    row_id                      INT AUTO_INCREMENT PRIMARY KEY,   -- SQL Server: INT IDENTITY(1,1)
    order_type                  VARCHAR(50),
    days_for_shipping_real      INT,
    days_for_shipment_scheduled INT,
    benefit_per_order           DECIMAL(12,2),
    sales_per_customer          DECIMAL(12,2),
    delivery_status             VARCHAR(50),
    late_delivery_risk          TINYINT,
    category_id                 INT,
    category_name               VARCHAR(100),
    customer_city                VARCHAR(100),
    customer_country             VARCHAR(100),
    customer_id                  INT,
    customer_segment             VARCHAR(50),
    customer_state                VARCHAR(50),
    department_id                 INT,
    department_name               VARCHAR(100),
    latitude                       DECIMAL(9,6),
    longitude                      DECIMAL(9,6),
    market                         VARCHAR(50),
    order_city                     VARCHAR(100),
    order_country                  VARCHAR(100),
    order_customer_id              INT,
    order_date                     DATETIME,
    order_id                       INT,
    order_item_cardprod_id         INT,
    order_item_discount            DECIMAL(12,2),
    order_item_discount_rate       DECIMAL(6,4),
    order_item_id                  INT,
    order_item_product_price       DECIMAL(12,2),
    order_item_profit_ratio        DECIMAL(6,4),
    order_item_quantity             INT,
    sales                            DECIMAL(12,2),
    order_item_total                 DECIMAL(12,2),
    order_profit_per_order           DECIMAL(12,2),
    order_region                     VARCHAR(50),
    order_state                      VARCHAR(50),
    order_status                     VARCHAR(50),
    product_card_id                  INT,
    product_category_id              INT,
    product_name                     VARCHAR(255),
    product_price                    DECIMAL(12,2),
    product_status                   TINYINT,
    shipping_date                    DATETIME,
    shipping_mode                    VARCHAR(50)
);
-- NOTE: this is a trimmed column list (the real CSV has ~50 columns,
-- including PII like customer name/email/password — DROP those on
-- load, do not stage them; they add zero value to the model and
-- create an unnecessary data-handling liability).

-- ------------------------------------------------------------
-- 2. DIMENSIONAL MODEL (clean layer, built FROM stg_dataco_raw
--    after integrity checks + fixes have been applied)
-- ------------------------------------------------------------
DROP TABLE IF EXISTS dim_date;
CREATE TABLE dim_date (
    date_key      INT PRIMARY KEY,        -- YYYYMMDD
    full_date     DATE NOT NULL,
    week_number   INT,
    month_number  INT,
    quarter       INT,
    year          INT,
    is_holiday    TINYINT DEFAULT 0
);

DROP TABLE IF EXISTS dim_region;
CREATE TABLE dim_region (
    region_key    INT AUTO_INCREMENT PRIMARY KEY,
    order_region  VARCHAR(50) NOT NULL,
    market        VARCHAR(50),
    UNIQUE (order_region)
);

DROP TABLE IF EXISTS dim_sku;
CREATE TABLE dim_sku (
    sku_key            INT AUTO_INCREMENT PRIMARY KEY,
    product_card_id     INT NOT NULL,
    product_name         VARCHAR(255),
    category_id           INT,
    category_name         VARCHAR(100),
    unit_cost              DECIMAL(12,2),   -- derived from product_price, see Task notes
    sku_velocity_class      VARCHAR(20),    -- 'fast' | 'medium' | 'slow' — set after profiling
    UNIQUE (product_card_id)
);

-- fact_demand: the grain is (sku, region, week) — this IS your
-- "SKU-warehouse" grain, with order_region standing in for warehouse
DROP TABLE IF EXISTS fact_demand;
CREATE TABLE fact_demand (
    demand_key     INT AUTO_INCREMENT PRIMARY KEY,
    date_key        INT NOT NULL,
    sku_key          INT NOT NULL,
    region_key        INT NOT NULL,
    demand_qty         INT NOT NULL,
    FOREIGN KEY (date_key)   REFERENCES dim_date(date_key),
    FOREIGN KEY (sku_key)    REFERENCES dim_sku(sku_key),
    FOREIGN KEY (region_key) REFERENCES dim_region(region_key)
);

-- fact_lead_time: derived from (days_for_shipping_real - days_for_shipment_scheduled)
-- per order, aggregated to (sku, region) — this is your lead-time
-- VARIABILITY input for the distribution fitting in step 3 of the project
DROP TABLE IF EXISTS fact_lead_time;
CREATE TABLE fact_lead_time (
    lead_time_key      INT AUTO_INCREMENT PRIMARY KEY,
    sku_key              INT NOT NULL,
    region_key             INT NOT NULL,
    scheduled_days           INT,
    actual_days               INT,
    lead_time_deviation        INT,          -- actual - scheduled
    FOREIGN KEY (sku_key)    REFERENCES dim_sku(sku_key),
    FOREIGN KEY (region_key) REFERENCES dim_region(region_key)
);

-- ------------------------------------------------------------
-- 3. ASSUMPTION / PARAMETER TABLE
-- Every synthetic number you introduce (holding_cost_pct,
-- service_level_target, total_budget) goes HERE, in one place,
-- clearly separated from real data — never hard-coded inline
-- in your Python. This table is what you point to in the README
-- when someone asks "what's real vs. assumed here?"
-- ------------------------------------------------------------
DROP TABLE IF EXISTS dim_model_assumptions;
CREATE TABLE dim_model_assumptions (
    assumption_key     VARCHAR(50) PRIMARY KEY,
    assumption_value    DECIMAL(14,4),
    assumption_basis      VARCHAR(255)   -- one sentence justification, e.g. "20% = industry-typical annual holding cost"
);

INSERT INTO dim_model_assumptions VALUES
    ('holding_cost_pct_annual', 0.20, 'Industry-typical FMCG/retail annual holding cost as % of unit cost (15-25% range)'),
    ('default_service_level',   0.95, 'Standard 95% service level target for mid-tier regions'),
    ('priority_service_level',  0.99, 'Elevated 99% target for top-3 regions by order volume'),
    ('total_budget_multiplier', 1.10, 'Total safety-stock budget = 110% of current estimated safety-stock spend (baseline + 10% headroom)');
