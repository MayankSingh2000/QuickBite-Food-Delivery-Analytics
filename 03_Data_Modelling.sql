/* =====================================================================
   QuickBite Food Delivery Analytics
   03_Data_Modelling.sql

   Builds the dw star schema from the clean tables. The dw tables are dropped
   and rebuilt on every run, so the script can be re-run safely.

   Steps
   0.   Column check of the clean tables
   1.   Create the dw schema and drop any earlier version
   2.   dw.dim_date (2023-01-01 to 2026-12-31)
   3.   dw.dim_customer
   4.   dw.dim_restaurant
   5.   dw.dim_partner
   6.   dw.dim_promo
   7.   dw.fact_orders (52,325 rows)
   8.   dw.fact_deliveries (48,012 rows)
   9.   dw.fact_reviews (22,122 rows)
   10.  Indexes on the join and filter columns

   Checks VM1 to VM9 compare the model with the clean tables. Design
   decisions are documented in the step they apply to.
   ===================================================================== */
 
USE QuickBite;
GO
 
-- ---------------------------------------------------------------------
-- 0. Column check (read-only): confirms that the clean tables contain the columns used below
-- ---------------------------------------------------------------------
SELECT TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'clean' AND TABLE_NAME NOT LIKE 'map[_]%'
ORDER BY TABLE_NAME, ORDINAL_POSITION;
GO
 
-- ---------------------------------------------------------------------
-- 1. Schema dw; drop any earlier version (facts first, then dimensions)
--    Unknown members: every dimension has a row with key -1 ('Unknown'; 'No promo' in dim_promo). The 156 orders of
--    unknown customers and the 104 orders of unknown restaurants are kept and point to it. Orders without a promo
--    point to dim_promo key -1.
--    clean.order_items is not part of the star (the brief lists three facts); it stays in the clean schema.
-- ---------------------------------------------------------------------
IF SCHEMA_ID('dw') IS NULL EXEC('CREATE SCHEMA dw');
GO
 
DROP TABLE IF EXISTS dw.fact_reviews;
DROP TABLE IF EXISTS dw.fact_deliveries;
DROP TABLE IF EXISTS dw.fact_orders;
DROP TABLE IF EXISTS dw.dim_promo;
DROP TABLE IF EXISTS dw.dim_partner;
DROP TABLE IF EXISTS dw.dim_restaurant;
DROP TABLE IF EXISTS dw.dim_customer;
DROP TABLE IF EXISTS dw.dim_date;
GO
 
-- ---------------------------------------------------------------------
-- 2. dw.dim_date: one row per calendar day, 2023-01-01 to 2026-12-31 (1,461 days)
--    date_key is the day written as a number, e.g. 20250131. day_of_week_number: Monday = 1.
--    Names are written out with CHOOSE so the result does not depend on the server language.
--    season: Winter = Dec to Feb, Summer = Mar to May, Monsoon = Jun to Sep, Post-monsoon = Oct to Nov
--    (assumption: typical Indian climate; used for the weather question, Q4).
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_date (
    date_key            INT          NOT NULL CONSTRAINT PK_dim_date PRIMARY KEY,
    full_date           DATE         NOT NULL,
    year_number         SMALLINT     NOT NULL,
    quarter_number      TINYINT      NOT NULL,
    month_number        TINYINT      NOT NULL,
    month_name          VARCHAR(10)  NOT NULL,
    year_month          CHAR(7)      NOT NULL,
    month_start         DATE         NOT NULL,
    day_of_month        TINYINT      NOT NULL,
    day_of_week_number  TINYINT      NOT NULL,
    day_name            VARCHAR(10)  NOT NULL,
    is_weekend          BIT          NOT NULL,
    season              VARCHAR(15)  NOT NULL
);
GO
 
WITH d AS (
    SELECT CAST('2023-01-01' AS DATE) AS dt
    UNION ALL
    SELECT DATEADD(DAY, 1, dt) FROM d WHERE dt < '2026-12-31'
)
INSERT INTO dw.dim_date (date_key, full_date, year_number, quarter_number, month_number, month_name, year_month,
                         month_start, day_of_month, day_of_week_number, day_name, is_weekend, season)
SELECT CAST(CONVERT(CHAR(8), d.dt, 112) AS INT),
       d.dt,
       YEAR(d.dt),
       DATEPART(QUARTER, d.dt),
       MONTH(d.dt),
       CHOOSE(MONTH(d.dt), 'January', 'February', 'March', 'April', 'May', 'June',
                           'July', 'August', 'September', 'October', 'November', 'December'),
       CONVERT(CHAR(7), d.dt, 120),
       DATEFROMPARTS(YEAR(d.dt), MONTH(d.dt), 1),
       DAY(d.dt),
       w.dow,
       CHOOSE(w.dow, 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'),
       CASE WHEN w.dow IN (6, 7) THEN 1 ELSE 0 END,
       CASE WHEN MONTH(d.dt) IN (12, 1, 2) THEN 'Winter'
            WHEN MONTH(d.dt) IN (3, 4, 5)  THEN 'Summer'
            WHEN MONTH(d.dt) IN (6, 7, 8, 9) THEN 'Monsoon'
            ELSE 'Post-monsoon' END
FROM d
CROSS APPLY (SELECT (DATEDIFF(DAY, '19000101', d.dt) % 7) + 1 AS dow) AS w
OPTION (MAXRECURSION 2000);
GO
 
-- ---------------------------------------------------------------------
-- 3. dw.dim_customer (6,000 customers + the Unknown member)
--    email and phone are not carried into the model (not needed for analysis, and personal data).
--    is_shared_phone (accounts that share a phone number) is kept because it supports the promo-abuse question (Q8).
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_customer (
    customer_key                INT            NOT NULL CONSTRAINT PK_dim_customer PRIMARY KEY,
    customer_id                 VARCHAR(30)    NOT NULL CONSTRAINT UQ_dim_customer_id UNIQUE,
    customer_name               NVARCHAR(200)  NULL,
    gender                      VARCHAR(20)    NULL,
    age                         INT            NULL,
    city                        VARCHAR(50)    NULL,
    signup_channel              VARCHAR(50)    NULL,
    signup_date                 DATE           NULL,
    is_shared_phone             BIT            NOT NULL,
    is_signup_after_first_order BIT            NOT NULL
);
GO
 
INSERT INTO dw.dim_customer (customer_key, customer_id, customer_name, gender, age, city, signup_channel, signup_date, is_shared_phone, is_signup_after_first_order)
VALUES (-1, 'UNKNOWN', 'Unknown customer', 'Unknown', NULL, 'Unknown', 'Unknown', NULL, 0, 0);
 
INSERT INTO dw.dim_customer (customer_key, customer_id, customer_name, gender, age, city, signup_channel, signup_date, is_shared_phone, is_signup_after_first_order)
SELECT ROW_NUMBER() OVER (ORDER BY customer_id), customer_id, customer_name, gender, age, city, signup_channel, signup_date, is_shared_phone, is_signup_after_first_order
FROM clean.customers;
GO
 
-- ---------------------------------------------------------------------
-- 4. dw.dim_restaurant (320 restaurants + the Unknown member)
--    commission_pct is a percentage (18 means 18%), as in the data dictionary. commission_missing = 1 for the 7 restaurants
--    without a commission and for the Unknown member.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_restaurant (
    restaurant_key   INT            NOT NULL CONSTRAINT PK_dim_restaurant PRIMARY KEY,
    restaurant_id    VARCHAR(30)    NOT NULL CONSTRAINT UQ_dim_restaurant_id UNIQUE,
    restaurant_name  NVARCHAR(200)  NULL,
    cuisine          VARCHAR(50)    NULL,
    tier             VARCHAR(30)    NULL,
    city             VARCHAR(50)    NULL,
    area             VARCHAR(100)   NULL,
    commission_pct   DECIMAL(5,2)   NULL,
    commission_missing BIT          NOT NULL,
    onboarded_date   DATE           NULL
);
GO
 
INSERT INTO dw.dim_restaurant (restaurant_key, restaurant_id, restaurant_name, cuisine, tier, city, area, commission_pct, commission_missing, onboarded_date)
VALUES (-1, 'UNKNOWN', 'Unknown restaurant', 'Unknown', 'Unknown', 'Unknown', 'Unknown', NULL, 1, NULL);
 
INSERT INTO dw.dim_restaurant (restaurant_key, restaurant_id, restaurant_name, cuisine, tier, city, area, commission_pct, commission_missing, onboarded_date)
SELECT ROW_NUMBER() OVER (ORDER BY restaurant_id), restaurant_id, restaurant_name, cuisine, tier, city, area, commission_pct, commission_missing, onboarded_date
FROM clean.restaurants;
GO
 
-- ---------------------------------------------------------------------
-- 5. dw.dim_partner (450 partners + the Unknown member)
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_partner (
    partner_key      INT            NOT NULL CONSTRAINT PK_dim_partner PRIMARY KEY,
    partner_id       VARCHAR(30)    NOT NULL CONSTRAINT UQ_dim_partner_id UNIQUE,
    partner_name     NVARCHAR(200)  NULL,
    city             VARCHAR(50)    NULL,
    vehicle_type     VARCHAR(30)    NULL,
    employment_type  VARCHAR(30)    NULL,
    joined_date      DATE           NULL
);
GO
 
INSERT INTO dw.dim_partner (partner_key, partner_id, partner_name, city, vehicle_type, employment_type, joined_date)
VALUES (-1, 'UNKNOWN', 'Unknown partner', 'Unknown', 'Unknown', 'Unknown', NULL);
 
INSERT INTO dw.dim_partner (partner_key, partner_id, partner_name, city, vehicle_type, employment_type, joined_date)
SELECT ROW_NUMBER() OVER (ORDER BY partner_id), partner_id, partner_name, city, vehicle_type, employment_type, joined_date
FROM clean.delivery_partners;
GO
 
-- ---------------------------------------------------------------------
-- 6. dw.dim_promo (7 promotions + the 'No promo' member with key -1)
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_promo (
    promo_key        INT            NOT NULL CONSTRAINT PK_dim_promo PRIMARY KEY,
    promo_code       VARCHAR(30)    NOT NULL CONSTRAINT UQ_dim_promo_code UNIQUE,
    promo_type       VARCHAR(30)    NULL,
    discount_value   DECIMAL(10,2)  NULL,
    max_discount     DECIMAL(10,2)  NULL,
    min_order_value  DECIMAL(10,2)  NULL,
    start_date       DATE           NULL,
    end_date         DATE           NULL,
    eligibility      VARCHAR(200)   NULL
);
GO
 
INSERT INTO dw.dim_promo (promo_key, promo_code, promo_type, discount_value, max_discount, min_order_value, start_date, end_date, eligibility)
VALUES (-1, 'NO PROMO', 'None', NULL, NULL, NULL, NULL, NULL, 'No promo applied');
 
INSERT INTO dw.dim_promo (promo_key, promo_code, promo_type, discount_value, max_discount, min_order_value, start_date, end_date, eligibility)
SELECT ROW_NUMBER() OVER (ORDER BY promo_code), promo_code, promo_type, discount_value, max_discount, min_order_value, start_date, end_date, eligibility
FROM clean.promotions;
GO
 
-- ---------------------------------------------------------------------
-- 7. dw.fact_orders: one row per order (52,325)
--    Measures are filled for Delivered orders only (NULL on every other order) and follow data_dictionary.md:
--      gmv               = total_amount
--      commission_amount = subtotal x commission_pct / 100
--      net_revenue       = commission_amount + delivery_fee - discount_amount   (what QuickBite earns before paying the partner)
--      contribution      = net_revenue - partner_payout
--    Assumption: the brief does not define net revenue, so the definition above is used.
--    A measure stays NULL where an input is unknown, instead of being guessed:
--      * commission_amount, net_revenue and contribution are NULL for delivered orders of an unknown restaurant and of the
--        7 restaurants whose commission is missing (log #25, commission_missing = 1)
--      * partner_payout and contribution are NULL where the payout is missing (log #41)
--    Averages in the analysis therefore leave out those orders, and the counts are reported next to them.
--    Refunded orders carry no revenue measures; the refunded amount is kept in refunded_amount so the cost of
--    refunds can be shown separately.
--    Flags from the cleaning phase are kept as columns, so any analysis can include or exclude those rows and report
--    how many were left out.
-- ---------------------------------------------------------------------
CREATE TABLE dw.fact_orders (
    order_id                  VARCHAR(30)    NOT NULL CONSTRAINT PK_fact_orders PRIMARY KEY,
    date_key                  INT            NOT NULL CONSTRAINT FK_fact_orders_date       FOREIGN KEY REFERENCES dw.dim_date (date_key),
    order_datetime            DATETIME2(0)   NOT NULL,
    order_hour                TINYINT        NOT NULL,
    customer_key              INT            NOT NULL CONSTRAINT FK_fact_orders_customer   FOREIGN KEY REFERENCES dw.dim_customer (customer_key),
    restaurant_key            INT            NOT NULL CONSTRAINT FK_fact_orders_restaurant FOREIGN KEY REFERENCES dw.dim_restaurant (restaurant_key),
    promo_key                 INT            NOT NULL CONSTRAINT FK_fact_orders_promo      FOREIGN KEY REFERENCES dw.dim_promo (promo_key),
    order_status              VARCHAR(40)    NOT NULL,
    payment_method            VARCHAR(30)    NULL,
    order_platform            VARCHAR(30)    NULL,
    delivery_city             VARCHAR(50)    NULL,
    is_delivered              BIT            NOT NULL,
    is_cancelled              BIT            NOT NULL,
    cancellation_type         VARCHAR(15)    NULL,
    is_refunded               BIT            NOT NULL,
    subtotal                  DECIMAL(12,2)  NULL,
    discount_amount           DECIMAL(12,2)  NULL,
    delivery_fee              DECIMAL(12,2)  NULL,
    total_amount              DECIMAL(12,2)  NULL,
    gmv                       DECIMAL(12,2)  NULL,
    commission_amount         DECIMAL(12,2)  NULL,
    net_revenue               DECIMAL(12,2)  NULL,
    partner_payout            DECIMAL(12,2)  NULL,
    contribution              DECIMAL(12,2)  NULL,
    refunded_amount           DECIMAL(12,2)  NULL,
    is_orphan_customer        BIT            NOT NULL,
    is_orphan_restaurant      BIT            NOT NULL,
    ordered_before_onboarding BIT            NOT NULL
);
GO
 
INSERT INTO dw.fact_orders (order_id, date_key, order_datetime, order_hour, customer_key, restaurant_key, promo_key,
                            order_status, payment_method, order_platform, delivery_city,
                            is_delivered, is_cancelled, cancellation_type, is_refunded,
                            subtotal, discount_amount, delivery_fee, total_amount,
                            gmv, commission_amount, net_revenue, partner_payout, contribution, refunded_amount,
                            is_orphan_customer, is_orphan_restaurant, ordered_before_onboarding)
SELECT o.order_id,
       CAST(CONVERT(CHAR(8), o.order_datetime, 112) AS INT),
       o.order_datetime,
       DATEPART(HOUR, o.order_datetime),
       ISNULL(c.customer_key, -1),
       ISNULL(r.restaurant_key, -1),
       ISNULL(p.promo_key, -1),
       o.order_status,
       o.payment_method,
       o.order_platform,
       o.delivery_city,
       x.is_delivered,
       CASE WHEN o.order_status IN ('Cancelled by Customer', 'Cancelled by Restaurant', 'Cancelled - No Partner') THEN 1 ELSE 0 END,
       CASE o.order_status WHEN 'Cancelled by Customer'   THEN 'Customer'
                           WHEN 'Cancelled by Restaurant' THEN 'Restaurant'
                           WHEN 'Cancelled - No Partner'  THEN 'No partner' END,
       CASE WHEN o.order_status = 'Refunded' THEN 1 ELSE 0 END,
       o.subtotal, o.discount_amount, o.delivery_fee, o.total_amount,
       CASE WHEN x.is_delivered = 1 THEN o.total_amount END,
       x.commission_amount,
       CASE WHEN x.is_delivered = 1 THEN x.commission_amount + o.delivery_fee - o.discount_amount END,
       CASE WHEN x.is_delivered = 1 THEN d.partner_payout END,
       CASE WHEN x.is_delivered = 1 THEN x.commission_amount + o.delivery_fee - o.discount_amount - d.partner_payout END,
       CASE WHEN o.order_status = 'Refunded' THEN o.total_amount END,
       o.is_orphan_customer, o.is_orphan_restaurant, o.ordered_before_onboarding
FROM clean.orders AS o
LEFT JOIN dw.dim_customer   AS c ON c.customer_id   = o.customer_id
LEFT JOIN dw.dim_restaurant AS r ON r.restaurant_id = o.restaurant_id
LEFT JOIN dw.dim_promo      AS p ON p.promo_code    = o.promo_code
LEFT JOIN clean.deliveries  AS d ON d.order_id      = o.order_id
CROSS APPLY (SELECT CASE WHEN o.order_status = 'Delivered' THEN 1 ELSE 0 END AS is_delivered,
                    CASE WHEN o.order_status = 'Delivered'
                         THEN CAST(o.subtotal * r.commission_pct / 100.0 AS DECIMAL(12,2)) END AS commission_amount) AS x;
GO
 
-- ---------------------------------------------------------------------
-- 8. dw.fact_deliveries: one row per delivery (48,012; only Delivered and Refunded orders have one)
--    The keys of the order (date, hour, restaurant) are copied so delivery questions need only one join.
--    SLA: delivery_minutes = delivered_time - order_datetime; delay_minutes = delivery_minutes - promised_minutes.
--    is_sla_breach = delay_minutes > 1 minute. The 1-minute tolerance is there because some order timestamps have
--    no seconds (log #49, up to 58 seconds of drift), so a strict "delay > 0" would count a few false breaches.
--    is_sla_breach is NULL when the delivery time or promised time is unknown.
-- ---------------------------------------------------------------------
CREATE TABLE dw.fact_deliveries (
    delivery_id             VARCHAR(30)    NOT NULL CONSTRAINT PK_fact_deliveries PRIMARY KEY,
    order_id                VARCHAR(30)    NOT NULL CONSTRAINT FK_fact_deliveries_order      FOREIGN KEY REFERENCES dw.fact_orders (order_id),
    date_key                INT            NOT NULL CONSTRAINT FK_fact_deliveries_date       FOREIGN KEY REFERENCES dw.dim_date (date_key),
    order_hour              TINYINT        NOT NULL,
    partner_key             INT            NOT NULL CONSTRAINT FK_fact_deliveries_partner    FOREIGN KEY REFERENCES dw.dim_partner (partner_key),
    restaurant_key          INT            NOT NULL CONSTRAINT FK_fact_deliveries_restaurant FOREIGN KEY REFERENCES dw.dim_restaurant (restaurant_key),
    pickup_time             DATETIME2(0)   NULL,
    delivered_time          DATETIME2(0)   NULL,
    promised_minutes        INT            NULL,
    distance_km             DECIMAL(6,2)   NULL,
    partner_payout          DECIMAL(8,2)   NULL,
    delivery_minutes        DECIMAL(8,2)   NULL,
    delay_minutes           DECIMAL(8,2)   NULL,
    is_sla_breach           BIT            NULL,
    partner_tenure_days     INT            NULL,
    delivered_time_missing  BIT            NOT NULL,
    delivered_before_pickup BIT            NOT NULL,
    distance_invalid        BIT            NOT NULL,
    promised_invalid        BIT            NOT NULL,
    payout_missing          BIT            NOT NULL
);
GO
 
DECLARE @sla_tolerance_minutes DECIMAL(4,1) = 1.0;   -- see design decision 4
 
INSERT INTO dw.fact_deliveries (delivery_id, order_id, date_key, order_hour, partner_key, restaurant_key,
                                pickup_time, delivered_time, promised_minutes, distance_km, partner_payout,
                                delivery_minutes, delay_minutes, is_sla_breach, partner_tenure_days,
                                delivered_time_missing, delivered_before_pickup, distance_invalid, promised_invalid, payout_missing)
SELECT d.delivery_id,
       d.order_id,
       fo.date_key,
       fo.order_hour,
       ISNULL(pt.partner_key, -1),
       fo.restaurant_key,
       d.pickup_time,
       d.delivered_time,
       d.promised_minutes,
       d.distance_km,
       d.partner_payout,
       m.delivery_minutes,
       m.delivery_minutes - d.promised_minutes,
       CASE WHEN m.delivery_minutes IS NULL OR d.promised_minutes IS NULL THEN NULL
            WHEN m.delivery_minutes - d.promised_minutes > @sla_tolerance_minutes THEN 1 ELSE 0 END,
       DATEDIFF(DAY, pt.joined_date, CAST(fo.order_datetime AS DATE)),
       d.delivered_time_missing, d.delivered_before_pickup, d.distance_invalid, d.promised_invalid, d.payout_missing
FROM clean.deliveries AS d
JOIN dw.fact_orders   AS fo ON fo.order_id   = d.order_id
LEFT JOIN dw.dim_partner AS pt ON pt.partner_id = d.partner_id
CROSS APPLY (SELECT CASE WHEN d.delivered_time IS NOT NULL
                         THEN CAST(DATEDIFF(SECOND, fo.order_datetime, d.delivered_time) / 60.0 AS DECIMAL(8,2)) END AS delivery_minutes) AS m;
GO
 
-- ---------------------------------------------------------------------
-- 9. dw.fact_reviews: one row per review (22,122)
--    date_key is NULL when the review date was invalid (log #45); the rating is kept.
-- ---------------------------------------------------------------------
CREATE TABLE dw.fact_reviews (
    review_id            VARCHAR(30)    NOT NULL CONSTRAINT PK_fact_reviews PRIMARY KEY,
    order_id             VARCHAR(30)    NOT NULL CONSTRAINT FK_fact_reviews_order      FOREIGN KEY REFERENCES dw.fact_orders (order_id),
    date_key             INT            NULL     CONSTRAINT FK_fact_reviews_date       FOREIGN KEY REFERENCES dw.dim_date (date_key),
    customer_key         INT            NOT NULL CONSTRAINT FK_fact_reviews_customer   FOREIGN KEY REFERENCES dw.dim_customer (customer_key),
    restaurant_key       INT            NOT NULL CONSTRAINT FK_fact_reviews_restaurant FOREIGN KEY REFERENCES dw.dim_restaurant (restaurant_key),
    rating               TINYINT        NULL,
    rating_invalid       BIT            NOT NULL,
    review_date_invalid  BIT            NOT NULL,
    review_text          NVARCHAR(MAX)  NULL
);
GO
 
INSERT INTO dw.fact_reviews (review_id, order_id, date_key, customer_key, restaurant_key, rating, rating_invalid, review_date_invalid, review_text)
SELECT r.review_id,
       r.order_id,
       CASE WHEN r.review_date IS NULL THEN NULL ELSE CAST(CONVERT(CHAR(8), r.review_date, 112) AS INT) END,
       fo.customer_key,
       fo.restaurant_key,
       r.rating,
       r.rating_invalid,
       r.review_date_invalid,
       r.review_text
FROM clean.reviews  AS r
JOIN dw.fact_orders AS fo ON fo.order_id = r.order_id;
GO
 
-- ---------------------------------------------------------------------
-- 10. Indexes on the columns used to join and filter (primary keys already have one)
--     fact_deliveries and fact_reviews have exactly one row per order, so their order_id index is unique.
-- ---------------------------------------------------------------------
CREATE INDEX IX_fact_orders_date       ON dw.fact_orders (date_key);
CREATE INDEX IX_fact_orders_customer   ON dw.fact_orders (customer_key);
CREATE INDEX IX_fact_orders_restaurant ON dw.fact_orders (restaurant_key);
CREATE INDEX IX_fact_orders_status     ON dw.fact_orders (order_status);
CREATE UNIQUE INDEX UX_fact_deliveries_order ON dw.fact_deliveries (order_id);
CREATE INDEX IX_fact_deliveries_partner      ON dw.fact_deliveries (partner_key);
CREATE INDEX IX_fact_deliveries_restaurant   ON dw.fact_deliveries (restaurant_key);
CREATE UNIQUE INDEX UX_fact_reviews_order    ON dw.fact_reviews (order_id);
CREATE INDEX IX_fact_reviews_restaurant      ON dw.fact_reviews (restaurant_key);
GO
 
-- ---------------------------------------------------------------------
-- MODEL CHECKS: compare each result with the expected value
-- ---------------------------------------------------------------------
 
-- VM1. Row count of every dw table (the column match should be 1 on every row)
SELECT 'dw.dim_date' AS table_name,       COUNT(*) AS row_count, 1461   AS expected, CASE WHEN COUNT(*) = 1461   THEN 1 ELSE 0 END AS match FROM dw.dim_date        UNION ALL
SELECT 'dw.dim_customer',                 COUNT(*),              6001,                CASE WHEN COUNT(*) = 6001   THEN 1 ELSE 0 END             FROM dw.dim_customer    UNION ALL
SELECT 'dw.dim_restaurant',               COUNT(*),              321,                 CASE WHEN COUNT(*) = 321    THEN 1 ELSE 0 END             FROM dw.dim_restaurant  UNION ALL
SELECT 'dw.dim_partner',                  COUNT(*),              451,                 CASE WHEN COUNT(*) = 451    THEN 1 ELSE 0 END             FROM dw.dim_partner     UNION ALL
SELECT 'dw.dim_promo',                    COUNT(*),              8,                   CASE WHEN COUNT(*) = 8      THEN 1 ELSE 0 END             FROM dw.dim_promo       UNION ALL
SELECT 'dw.fact_orders',                  COUNT(*),              52325,               CASE WHEN COUNT(*) = 52325  THEN 1 ELSE 0 END             FROM dw.fact_orders     UNION ALL
SELECT 'dw.fact_deliveries',              COUNT(*),              48012,               CASE WHEN COUNT(*) = 48012  THEN 1 ELSE 0 END             FROM dw.fact_deliveries UNION ALL
SELECT 'dw.fact_reviews',                 COUNT(*),              22122,               CASE WHEN COUNT(*) = 22122  THEN 1 ELSE 0 END             FROM dw.fact_reviews;
GO
 
-- VM2. Unknown members and promo matching (expected 156, 104, 43,183 and 0)
SELECT SUM(CASE WHEN customer_key   = -1 THEN 1 ELSE 0 END) AS unknown_customer_orders,
       SUM(CASE WHEN restaurant_key = -1 THEN 1 ELSE 0 END) AS unknown_restaurant_orders,
       SUM(CASE WHEN promo_key      = -1 THEN 1 ELSE 0 END) AS no_promo_orders,
       (SELECT COUNT(*) FROM clean.orders WHERE promo_code IS NOT NULL)
         - SUM(CASE WHEN promo_key <> -1 THEN 1 ELSE 0 END) AS promo_codes_not_matched
FROM dw.fact_orders;
GO
 
-- VM3. Totals must equal the clean tables (each pair must be identical; delivered orders expected 47,065)
SELECT (SELECT SUM(total_amount) FROM clean.orders)                                   AS clean_total_amount,
       SUM(total_amount)                                                              AS model_total_amount,
       (SELECT SUM(total_amount) FROM clean.orders WHERE order_status = 'Delivered')  AS clean_gmv,
       SUM(gmv)                                                                       AS model_gmv,
       SUM(CAST(is_delivered AS INT))                                                 AS delivered_orders
FROM dw.fact_orders;
GO
 
-- VM4. Commission is stored as a percentage, not a fraction (expected lowest 12 to 14, highest 28, 7 restaurants with a missing commission)
SELECT MIN(commission_pct) AS min_commission_pct,
       MAX(commission_pct) AS max_commission_pct,
       AVG(commission_pct) AS avg_commission_pct,
       SUM(CAST(commission_missing AS INT)) AS restaurants_without_commission
FROM dw.dim_restaurant
WHERE restaurant_key <> -1;
GO
 
-- VM5. Measure logic on fact_orders
--      The first two columns must be identical: a delivered order has no commission exactly when its restaurant is unknown
--      or one of the 7 restaurants without a commission. delivered_without_payout at most 478; the last two columns expected 0.
SELECT SUM(CASE WHEN f.is_delivered = 1 AND f.commission_amount IS NULL THEN 1 ELSE 0 END) AS delivered_without_commission,
       SUM(CASE WHEN f.is_delivered = 1 AND r.commission_missing = 1    THEN 1 ELSE 0 END) AS delivered_at_restaurants_without_commission,
       SUM(CASE WHEN f.is_delivered = 1 AND f.partner_payout IS NULL    THEN 1 ELSE 0 END) AS delivered_without_payout,
       SUM(CASE WHEN f.contribution IS NOT NULL
                 AND ABS(f.contribution - (f.net_revenue - f.partner_payout)) > 0.01 THEN 1 ELSE 0 END) AS contribution_mismatch,
       SUM(CASE WHEN f.is_delivered = 0
                 AND (f.gmv IS NOT NULL OR f.net_revenue IS NOT NULL OR f.contribution IS NOT NULL) THEN 1 ELSE 0 END) AS measures_on_undelivered
FROM dw.fact_orders     AS f
JOIN dw.dim_restaurant  AS r ON r.restaurant_key = f.restaurant_key;
GO
 
-- VM6. Eyeball test: 10 random delivered orders with every component of the contribution
SELECT TOP 10 f.order_id, f.subtotal, r.commission_pct, f.commission_amount,
       f.delivery_fee, f.discount_amount, f.net_revenue, f.partner_payout, f.contribution
FROM dw.fact_orders AS f
JOIN dw.dim_restaurant AS r ON r.restaurant_key = f.restaurant_key
WHERE f.is_delivered = 1
ORDER BY NEWID();
GO
 
-- VM7. Delivery measures (expected: delivery_minutes_null 192 = 180 missing + 12 before pickup, negative_minutes 0,
--      average delivery time and breach share are for you to read: write them in the results block)
SELECT COUNT(*)                                                         AS deliveries,
       SUM(CASE WHEN delivery_minutes IS NULL THEN 1 ELSE 0 END)        AS delivery_minutes_null,
       SUM(CASE WHEN delivery_minutes < 0 THEN 1 ELSE 0 END)            AS negative_minutes,
       MIN(delivery_minutes)                                            AS min_minutes,
       AVG(delivery_minutes)                                            AS avg_minutes,
       MAX(delivery_minutes)                                            AS max_minutes,
       CAST(100.0 * SUM(CASE WHEN is_sla_breach = 1 THEN 1 ELSE 0 END)
                  / NULLIF(SUM(CASE WHEN is_sla_breach IS NOT NULL THEN 1 ELSE 0 END), 0) AS DECIMAL(5,2)) AS sla_breach_pct
FROM dw.fact_deliveries;
GO
 
-- VM8. Reviews (expected 22,122 reviews, 20 without a date, 30 without a rating, 0 ratings outside 1 to 5)
SELECT COUNT(*)                                                                      AS reviews,
       SUM(CASE WHEN date_key IS NULL THEN 1 ELSE 0 END)                             AS date_missing,
       SUM(CASE WHEN rating IS NULL THEN 1 ELSE 0 END)                               AS rating_missing,
       SUM(CASE WHEN rating IS NOT NULL AND rating NOT BETWEEN 1 AND 5 THEN 1 ELSE 0 END) AS bad_ratings
FROM dw.fact_reviews;
GO
 
-- VM9. The star join works: GMV by month through dim_date adds up to the total (expected 18 months, the two GMV numbers identical)
SELECT COUNT(*)           AS months,
       SUM(m.gmv)         AS gmv_by_month_sum,
       (SELECT SUM(gmv) FROM dw.fact_orders) AS gmv_total
FROM (SELECT d.year_month, SUM(f.gmv) AS gmv
      FROM dw.fact_orders AS f
      JOIN dw.dim_date    AS d ON d.date_key = f.date_key
      GROUP BY d.year_month) AS m;
GO
 
