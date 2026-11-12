/* =====================================================================
   QuickBite Food Delivery Analytics
   05_Reporting_Layer.sql

   Creates the rpt reporting layer on top of the dw star schema. CREATE OR
   ALTER replaces the objects, so the script can be re-run.

   Steps
   1.  Create the rpt schema
   2.  Create 12 views, one per headline query of 04_Data_Analysis_lean.sql
         vw_monthly_trend (Q1A)           vw_city_growth (Q1B)
         vw_city_economics (Q2E)          vw_cancellations_by_city (Q3B)
         vw_sla_by_city (Q4B)             vw_partner_capacity (Q5C)
         vw_restaurant_groups (Q6B)       vw_lateness_impact (Q7A)
         vw_promo_performance (Q8A)       vw_promo_abuse_check (Q8C)
         vw_channel_retention (Q9A)       vw_rfm_segments (Q10A)
   3.  Create 3 stored procedures
         usp_monthly_performance (@from_date, @to_date, @city)
         usp_cancellations (@from_date, @to_date, @city)
         usp_rfm_segments (@as_of_date)
   4.  Check query: compares the views with the Phase 5 results
   ===================================================================== */
 
USE QuickBite;
GO
 
-- 1. Create the rpt schema
IF SCHEMA_ID('rpt') IS NULL
    EXEC ('CREATE SCHEMA rpt');
GO
 
/* =====================================================================
   2. Views
   Definitions follow 04_Data_Analysis_lean.sql (see the Q1 section).
   Views have no ORDER BY (SQL Server does not allow it in a view); the caller sorts.
   ===================================================================== */
 
-- ---------------------------------------------------------------------
-- Q1A -> rpt.vw_monthly_trend
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_monthly_trend
AS
WITH monthly AS (
    SELECT d.month_start,
           d.year_month,
           COUNT(*)                                                                       AS orders,
           SUM(CAST(f.is_delivered AS INT))                                               AS delivered_orders,
           SUM(f.gmv)                                                                     AS gmv,
           SUM(f.net_revenue)                                                             AS net_revenue,
           CAST(100.0 * SUM(CASE WHEN f.is_delivered = 1 AND f.net_revenue IS NOT NULL THEN 1 ELSE 0 END)
                      / NULLIF(SUM(CAST(f.is_delivered AS INT)), 0) AS DECIMAL(5,2))      AS net_revenue_coverage_pct
    FROM dw.fact_orders AS f
    JOIN dw.dim_date    AS d ON d.date_key = f.date_key
    GROUP BY d.month_start, d.year_month
)
SELECT month_start,
       year_month,
       orders,
       CAST(100.0 * (orders - LAG(orders) OVER (ORDER BY month_start))
                  / NULLIF(LAG(orders) OVER (ORDER BY month_start), 0) AS DECIMAL(6,1))           AS orders_mom_pct,
       delivered_orders,
       gmv,
       CAST(100.0 * (gmv - LAG(gmv) OVER (ORDER BY month_start))
                  / NULLIF(LAG(gmv) OVER (ORDER BY month_start), 0) AS DECIMAL(6,1))              AS gmv_mom_pct,
       net_revenue,
       CAST(100.0 * (net_revenue - LAG(net_revenue) OVER (ORDER BY month_start))
                  / NULLIF(LAG(net_revenue) OVER (ORDER BY month_start), 0) AS DECIMAL(6,1))      AS net_revenue_mom_pct,
       net_revenue_coverage_pct
FROM monthly;
GO
 
-- ---------------------------------------------------------------------
-- Q1B -> rpt.vw_city_growth
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_city_growth
AS
WITH city_h1 AS (
    SELECT f.delivery_city,
           SUM(CASE WHEN d.year_number = 2025 THEN f.gmv END) AS gmv_h1_2025,
           SUM(CASE WHEN d.year_number = 2026 THEN f.gmv END) AS gmv_h1_2026
    FROM dw.fact_orders AS f
    JOIN dw.dim_date    AS d ON d.date_key = f.date_key
    WHERE d.month_number BETWEEN 1 AND 6
    GROUP BY f.delivery_city
)
SELECT delivery_city,
       gmv_h1_2025,
       gmv_h1_2026,
       gmv_h1_2026 - gmv_h1_2025                                                              AS gmv_increase,
       CAST(100.0 * (gmv_h1_2026 - gmv_h1_2025) / NULLIF(gmv_h1_2025, 0) AS DECIMAL(6,1))     AS growth_pct,
       CAST(100.0 * (gmv_h1_2026 - gmv_h1_2025)
                  / NULLIF(SUM(gmv_h1_2026 - gmv_h1_2025) OVER (), 0) AS DECIMAL(6,1))        AS share_of_total_increase_pct
FROM city_h1;
GO
 
-- ---------------------------------------------------------------------
-- Q2E -> rpt.vw_city_economics
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_city_economics
AS
SELECT f.delivery_city,
       COUNT(*)                                                    AS orders,
       CAST(AVG(f.subtotal)          AS DECIMAL(8,2))              AS avg_subtotal,
       CAST(AVG(f.commission_amount) AS DECIMAL(8,2))              AS avg_commission,
       CAST(AVG(f.delivery_fee)      AS DECIMAL(8,2))              AS avg_delivery_fee,
       CAST(AVG(f.discount_amount)   AS DECIMAL(8,2))              AS avg_discount,
       CAST(AVG(f.partner_payout)    AS DECIMAL(8,2))              AS avg_partner_payout,
       CAST(AVG(d.distance_km)       AS DECIMAL(6,2))              AS avg_distance_km,
       CAST(100.0 * SUM(CASE WHEN f.promo_key <> -1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_orders_with_promo,
       CAST(AVG(f.contribution)      AS DECIMAL(8,2))              AS avg_contribution
FROM dw.fact_orders          AS f
LEFT JOIN dw.fact_deliveries AS d ON d.order_id = f.order_id
WHERE f.contribution IS NOT NULL
GROUP BY f.delivery_city;
GO
 
-- ---------------------------------------------------------------------
-- Q3B -> rpt.vw_cancellations_by_city
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_cancellations_by_city
AS
SELECT delivery_city,
       COUNT(*)                                                                                   AS orders,
       SUM(CAST(is_cancelled AS INT))                                                             AS cancelled,
       CAST(100.0 * SUM(CAST(is_cancelled AS INT)) / COUNT(*) AS DECIMAL(5,2))                    AS cancellation_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'Customer'   THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS customer_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'Restaurant' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS restaurant_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'No partner' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS no_partner_rate
FROM dw.fact_orders
GROUP BY delivery_city;
GO
 
-- ---------------------------------------------------------------------
-- Q4B -> rpt.vw_sla_by_city
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_sla_by_city
AS
SELECT f.delivery_city,
       COUNT(*)                                                                          AS deliveries,
       CAST(100.0 * SUM(CAST(d.is_sla_breach AS INT)) / COUNT(*) AS DECIMAL(5,2))        AS breach_pct,
       CAST(AVG(d.delay_minutes) AS DECIMAL(6,2))                                        AS avg_delay_minutes,
       CAST(100.0 * SUM(CASE WHEN d.delay_minutes > 15 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS severe_delay_pct
FROM dw.fact_deliveries AS d
JOIN dw.fact_orders     AS f ON f.order_id = d.order_id
WHERE d.is_sla_breach IS NOT NULL
GROUP BY f.delivery_city;
GO
 
-- ---------------------------------------------------------------------
-- Q5C -> rpt.vw_partner_capacity
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_partner_capacity
AS
WITH demand AS (
    SELECT delivery_city,
           COUNT(*)                                                          AS orders,
           SUM(CASE WHEN cancellation_type = 'No partner' THEN 1 ELSE 0 END) AS no_partner_orders
    FROM dw.fact_orders
    GROUP BY delivery_city
),
supply AS (
    SELECT city, COUNT(*) AS partners
    FROM dw.dim_partner
    WHERE partner_key <> -1
    GROUP BY city
)
SELECT d.delivery_city,
       s.partners,
       d.orders,
       CAST(1.0 * d.orders / NULLIF(s.partners, 0) AS DECIMAL(8,1))               AS orders_per_partner,
       CAST(1.0 * d.orders / NULLIF(s.partners, 0) / 18 AS DECIMAL(8,1))          AS orders_per_partner_per_month,
       d.no_partner_orders,
       CAST(100.0 * d.no_partner_orders / d.orders AS DECIMAL(5,2))               AS no_partner_pct
FROM demand AS d
LEFT JOIN supply AS s ON s.city = d.delivery_city;
GO
 
-- ---------------------------------------------------------------------
-- Q6B -> rpt.vw_restaurant_groups
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_restaurant_groups
AS
WITH grp AS (
    SELECT restaurant_key,
           CASE WHEN COUNT(*) >= 100
                 AND 100.0 * SUM(CASE WHEN cancellation_type = 'Restaurant' THEN 1 ELSE 0 END) / COUNT(*) >= 10
                THEN 'High-cancellation restaurants (rate 10%+)' ELSE 'All other restaurants' END AS restaurant_group
    FROM dw.fact_orders
    WHERE restaurant_key <> -1
    GROUP BY restaurant_key
),
ord AS (
    SELECT g.restaurant_group,
           COUNT(DISTINCT g.restaurant_key)       AS restaurants,
           COUNT(*)                               AS orders,
           SUM(CAST(f.is_delivered AS INT))       AS delivered_orders,
           SUM(CAST(f.is_refunded  AS INT))       AS refunded_orders
    FROM dw.fact_orders AS f
    JOIN grp            AS g ON g.restaurant_key = f.restaurant_key
    GROUP BY g.restaurant_group
),
rev AS (
    SELECT g.restaurant_group,
           COUNT(r.rating)                         AS reviews,
           AVG(CAST(r.rating AS DECIMAL(4,2)))     AS avg_rating
    FROM dw.fact_reviews AS r
    JOIN grp             AS g ON g.restaurant_key = r.restaurant_key
    GROUP BY g.restaurant_group
),
del AS (
    SELECT g.restaurant_group,
           COUNT(*)                                AS deliveries_measured,
           SUM(CAST(d.is_sla_breach AS INT))       AS late_deliveries
    FROM dw.fact_deliveries AS d
    JOIN grp                AS g ON g.restaurant_key = d.restaurant_key
    WHERE d.is_sla_breach IS NOT NULL
    GROUP BY g.restaurant_group
)
SELECT ord.restaurant_group,
       ord.restaurants,
       ord.orders,
       rev.reviews,
       CAST(rev.avg_rating AS DECIMAL(4,2))                                                                   AS avg_rating,
       CAST(100.0 * del.late_deliveries / NULLIF(del.deliveries_measured, 0) AS DECIMAL(5,2))                 AS late_pct,
       CAST(100.0 * ord.refunded_orders / NULLIF(ord.delivered_orders + ord.refunded_orders, 0) AS DECIMAL(5,2)) AS refund_pct
FROM ord
JOIN rev ON rev.restaurant_group = ord.restaurant_group
JOIN del ON del.restaurant_group = ord.restaurant_group;
GO
 
-- ---------------------------------------------------------------------
-- Q7A -> rpt.vw_lateness_impact
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_lateness_impact
AS
SELECT b.lateness_band,
       COUNT(*)                                                                                   AS deliveries,
       COUNT(rv.rating)                                                                           AS reviews,
       CAST(AVG(CAST(rv.rating AS DECIMAL(4,2))) AS DECIMAL(4,2))                                 AS avg_rating,
       CAST(100.0 * SUM(CASE WHEN rv.rating <= 2 THEN 1 ELSE 0 END) / NULLIF(COUNT(rv.rating), 0) AS DECIMAL(5,2)) AS pct_ratings_1_or_2,
       SUM(CAST(f.is_refunded AS INT))                                                            AS refunds,
       CAST(100.0 * SUM(CAST(f.is_refunded AS INT)) / COUNT(*) AS DECIMAL(5,2))                   AS refund_pct,
       SUM(f.refunded_amount)                                                                     AS refunded_value
FROM dw.fact_deliveries AS d
JOIN dw.fact_orders     AS f  ON f.order_id  = d.order_id
LEFT JOIN dw.fact_reviews AS rv ON rv.order_id = d.order_id
CROSS APPLY (SELECT CASE WHEN d.delay_minutes <= 1  THEN '1. On time (up to 1 minute late)'
                         WHEN d.delay_minutes <= 5  THEN '2. 1 to 5 minutes late'
                         WHEN d.delay_minutes <= 10 THEN '3. 5 to 10 minutes late'
                         WHEN d.delay_minutes <= 15 THEN '4. 10 to 15 minutes late'
                         ELSE '5. More than 15 minutes late' END AS lateness_band) AS b
WHERE d.delay_minutes IS NOT NULL
GROUP BY b.lateness_band;
GO
 
-- ---------------------------------------------------------------------
-- Q8A -> rpt.vw_promo_performance
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_promo_performance
AS
SELECT p.promo_code,
       p.promo_type,
       p.discount_value,
       p.max_discount,
       p.min_order_value,
       p.start_date,
       p.end_date,
       COUNT(*)                                                                   AS orders,
       CAST(AVG(f.subtotal)       AS DECIMAL(8,2))                                AS avg_subtotal,
       CAST(AVG(f.discount_amount) AS DECIMAL(8,2))                               AS avg_discount,
       CAST(AVG(f.contribution)   AS DECIMAL(8,2))                                AS avg_contribution,
       SUM(f.contribution)                                                        AS total_contribution,
       CAST(100.0 * SUM(CASE WHEN f.contribution < 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_orders_losing_money
FROM dw.fact_orders AS f
JOIN dw.dim_promo   AS p ON p.promo_key = f.promo_key
WHERE f.contribution IS NOT NULL
GROUP BY p.promo_key, p.promo_code, p.promo_type, p.discount_value, p.max_discount, p.min_order_value, p.start_date, p.end_date;
GO
 
-- ---------------------------------------------------------------------
-- Q8C -> rpt.vw_promo_abuse_check
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_promo_abuse_check
AS
WITH uses AS (
    SELECT p.promo_code, f.customer_key, COUNT(*) AS uses
    FROM dw.fact_orders AS f
    JOIN dw.dim_promo   AS p ON p.promo_key = f.promo_key
    WHERE f.promo_key <> -1
      AND f.customer_key <> -1
      AND f.is_delivered = 1
    GROUP BY p.promo_code, f.customer_key
)
SELECT u.promo_code,
       COUNT(*)                                                                      AS customers_using,
       SUM(u.uses)                                                                   AS promo_orders,
       MAX(u.uses)                                                                   AS max_uses_by_one_customer,
       SUM(CASE WHEN u.uses >= 3 THEN 1 ELSE 0 END)                                  AS customers_with_3_or_more_uses,
       CAST(100.0 * SUM(CASE WHEN c.is_shared_phone = 1 THEN u.uses ELSE 0 END) / SUM(u.uses) AS DECIMAL(5,2)) AS pct_orders_shared_phone,
       (SELECT CAST(100.0 * SUM(CASE WHEN c2.is_shared_phone = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))
        FROM dw.fact_orders AS f2
        JOIN dw.dim_customer AS c2 ON c2.customer_key = f2.customer_key
        WHERE f2.is_delivered = 1 AND f2.customer_key <> -1)                         AS baseline_pct_shared_phone
FROM uses AS u
JOIN dw.dim_customer AS c ON c.customer_key = u.customer_key
GROUP BY u.promo_code;
GO
 
-- ---------------------------------------------------------------------
-- Q9A -> rpt.vw_channel_retention
--        Customers whose first delivered order was before 1 April 2026 (90 days before the end of the data).
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_channel_retention
AS
WITH o AS (
    SELECT customer_key, order_datetime, contribution,
           ROW_NUMBER() OVER (PARTITION BY customer_key ORDER BY order_datetime, order_id) AS order_number
    FROM dw.fact_orders
    WHERE is_delivered = 1
      AND customer_key <> -1
),
cust AS (
    SELECT customer_key,
           MIN(order_datetime)                                     AS first_order,
           MIN(CASE WHEN order_number = 2 THEN order_datetime END) AS second_order,
           COUNT(*)                                                AS delivered_orders,
           SUM(contribution)                                       AS contribution
    FROM o
    GROUP BY customer_key
)
SELECT c.signup_channel,
       COUNT(*)                                                                                              AS customers,
       CAST(AVG(1.0 * x.delivered_orders) AS DECIMAL(6,2))                                                   AS avg_delivered_orders,
       CAST(100.0 * SUM(CASE WHEN x.delivered_orders >= 2 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))     AS repeat_customer_pct,
       CAST(100.0 * SUM(CASE WHEN DATEDIFF(DAY, x.first_order, x.second_order) <= 30 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS reorder_within_30_days_pct,
       CAST(100.0 * SUM(CASE WHEN DATEDIFF(DAY, x.first_order, x.second_order) <= 90 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS reorder_within_90_days_pct,
       CAST(AVG(x.contribution) AS DECIMAL(8,2))                                                             AS avg_contribution_per_customer,
       SUM(x.contribution)                                                                                   AS total_contribution
FROM cust AS x
JOIN dw.dim_customer AS c ON c.customer_key = x.customer_key
WHERE x.first_order < '2026-04-01'
GROUP BY c.signup_channel;
GO
 
-- ---------------------------------------------------------------------
-- Q10A -> rpt.vw_rfm_segments
--         As of 30 June 2026. For another date use rpt.usp_rfm_segments.
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_rfm_segments
AS
WITH params AS (
    SELECT CAST('2026-06-30' AS DATE) AS as_of
),
c AS (
    SELECT f.customer_key,
           DATEDIFF(DAY, MAX(f.order_datetime), p.as_of) AS recency_days,
           COUNT(*)                                      AS frequency,
           SUM(f.gmv)                                    AS monetary
    FROM dw.fact_orders AS f
    CROSS JOIN params   AS p
    WHERE f.is_delivered = 1
      AND f.customer_key <> -1
    GROUP BY f.customer_key, p.as_of
),
scored AS (
    SELECT customer_key, recency_days, frequency, monetary,
           NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
           NTILE(5) OVER (ORDER BY frequency ASC)     AS f_score,
           NTILE(5) OVER (ORDER BY monetary ASC)      AS m_score
    FROM c
),
seg AS (
    SELECT customer_key, recency_days, frequency, monetary,
           CASE WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN '1. Champions'
                WHEN f_score >= 4 AND r_score >= 3                  THEN '2. Loyal'
                WHEN r_score >= 4 AND f_score <= 2                  THEN '3. New or recent'
                WHEN r_score <= 2 AND f_score >= 3                  THEN '4. At risk'
                WHEN r_score <= 2 AND f_score <= 2                  THEN '5. Lost'
                ELSE '6. Regular' END AS segment
    FROM scored
)
SELECT segment,
       COUNT(*)                                                                         AS customers,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))                   AS pct_of_customers,
       CAST(AVG(1.0 * recency_days) AS DECIMAL(7,1))                                    AS avg_recency_days,
       CAST(AVG(1.0 * frequency)    AS DECIMAL(6,2))                                    AS avg_orders,
       CAST(AVG(monetary)           AS DECIMAL(10,2))                                   AS avg_spend,
       SUM(monetary)                                                                    AS total_gmv,
       CAST(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER () AS DECIMAL(5,2))         AS pct_of_gmv
FROM seg
GROUP BY segment;
GO
 
/* =====================================================================
   3. Stored procedures (parameterised)
   ===================================================================== */
 
-- ---------------------------------------------------------------------
-- rpt.usp_monthly_performance: monthly orders, GMV, net revenue and contribution
--   @from_date, @to_date  period (both days included); default is the whole data period
--   @city                 one city, or NULL for all cities
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE rpt.usp_monthly_performance
    @from_date DATE         = '2025-01-01',
    @to_date   DATE         = '2026-06-30',
    @city      NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
 
    IF @from_date > @to_date
        THROW 50001, 'from_date must not be after to_date.', 1;
 
    SELECT d.month_start,
           d.year_month,
           COUNT(*)                                                       AS orders,
           SUM(CAST(f.is_cancelled AS INT))                               AS cancelled_orders,
           CAST(100.0 * SUM(CAST(f.is_cancelled AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS cancellation_rate,
           SUM(CAST(f.is_delivered AS INT))                               AS delivered_orders,
           SUM(f.gmv)                                                     AS gmv,
           SUM(f.net_revenue)                                             AS net_revenue,
           SUM(f.contribution)                                            AS contribution,
           CAST(AVG(f.contribution) AS DECIMAL(8,2))                      AS avg_contribution_per_order
    FROM dw.fact_orders AS f
    JOIN dw.dim_date    AS d ON d.date_key = f.date_key
    WHERE f.order_datetime >= @from_date
      AND f.order_datetime <  DATEADD(DAY, 1, @to_date)
      AND (@city IS NULL OR f.delivery_city = @city)
    GROUP BY d.month_start, d.year_month
    ORDER BY d.month_start;
END;
GO
 
-- ---------------------------------------------------------------------
-- rpt.usp_cancellations: cancelled orders by type, with the order value lost
--   @from_date, @to_date  period (both days included); default is the whole data period
--   @city                 one city, or NULL for all cities
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE rpt.usp_cancellations
    @from_date DATE         = '2025-01-01',
    @to_date   DATE         = '2026-06-30',
    @city      NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
 
    IF @from_date > @to_date
        THROW 50001, 'from_date must not be after to_date.', 1;
 
    WITH base AS (
        SELECT is_cancelled, cancellation_type, total_amount
        FROM dw.fact_orders
        WHERE order_datetime >= @from_date
          AND order_datetime <  DATEADD(DAY, 1, @to_date)
          AND (@city IS NULL OR delivery_city = @city)
    )
    SELECT cancellation_type,
           COUNT(*)                                                                         AS cancelled_orders,
           CAST(100.0 * COUNT(*) / NULLIF((SELECT COUNT(*) FROM base), 0) AS DECIMAL(5,2))  AS pct_of_all_orders,
           CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))                   AS pct_of_cancellations,
           SUM(total_amount)                                                                AS order_value_lost
    FROM base
    WHERE is_cancelled = 1
    GROUP BY cancellation_type
    ORDER BY cancelled_orders DESC;
END;
GO
 
-- ---------------------------------------------------------------------
-- rpt.usp_rfm_segments: RFM segments as of any date (orders after that date are ignored)
--   @as_of_date  recency is counted to this date; default is the end of the data
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE rpt.usp_rfm_segments
    @as_of_date DATE = '2026-06-30'
AS
BEGIN
    SET NOCOUNT ON;
 
    IF @as_of_date IS NULL
        SET @as_of_date = '2026-06-30';
 
    WITH c AS (
        SELECT customer_key,
               DATEDIFF(DAY, MAX(order_datetime), @as_of_date) AS recency_days,
               COUNT(*)                                        AS frequency,
               SUM(gmv)                                        AS monetary
        FROM dw.fact_orders
        WHERE is_delivered = 1
          AND customer_key <> -1
          AND order_datetime < DATEADD(DAY, 1, @as_of_date)
        GROUP BY customer_key
    ),
    scored AS (
        SELECT customer_key, recency_days, frequency, monetary,
               NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
               NTILE(5) OVER (ORDER BY frequency ASC)     AS f_score,
               NTILE(5) OVER (ORDER BY monetary ASC)      AS m_score
        FROM c
    ),
    seg AS (
        SELECT customer_key, recency_days, frequency, monetary,
               CASE WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN '1. Champions'
                    WHEN f_score >= 4 AND r_score >= 3                  THEN '2. Loyal'
                    WHEN r_score >= 4 AND f_score <= 2                  THEN '3. New or recent'
                    WHEN r_score <= 2 AND f_score >= 3                  THEN '4. At risk'
                    WHEN r_score <= 2 AND f_score <= 2                  THEN '5. Lost'
                    ELSE '6. Regular' END AS segment
        FROM scored
    )
    SELECT segment,
           COUNT(*)                                                                         AS customers,
           CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))                   AS pct_of_customers,
           CAST(AVG(1.0 * recency_days) AS DECIMAL(7,1))                                    AS avg_recency_days,
           CAST(AVG(1.0 * frequency)    AS DECIMAL(6,2))                                    AS avg_orders,
           CAST(AVG(monetary)           AS DECIMAL(10,2))                                   AS avg_spend,
           SUM(monetary)                                                                    AS total_gmv,
           CAST(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER () AS DECIMAL(5,2))         AS pct_of_gmv
    FROM seg
    GROUP BY segment
    ORDER BY segment;
END;
GO
 
/* =====================================================================
   4. Check: the views against the Phase 5 results
   Every row should say OK.
   ===================================================================== */
SELECT check_name,
       actual,
       expected,
       CASE WHEN ABS(actual - expected) < 0.01 THEN 'OK' ELSE 'CHECK' END AS result
FROM (
    SELECT 'Q1A  total orders'                          AS check_name, CAST(SUM(orders) AS DECIMAL(18,2))                AS actual, CAST(52325 AS DECIMAL(18,2))      AS expected FROM rpt.vw_monthly_trend
    UNION ALL
    SELECT 'Q1B  Delhi GMV growth %',                   CAST(growth_pct AS DECIMAL(18,2)),                               CAST(200.4 AS DECIMAL(18,2))                 FROM rpt.vw_city_growth          WHERE delivery_city = 'Delhi'
    UNION ALL
    SELECT 'Q2E  Delhi contribution per order',         CAST(avg_contribution AS DECIMAL(18,2)),                         CAST(52.93 AS DECIMAL(18,2))                 FROM rpt.vw_city_economics       WHERE delivery_city = 'Delhi'
    UNION ALL
    SELECT 'Q3B  Delhi cancellation rate',              CAST(cancellation_rate AS DECIMAL(18,2)),                        CAST(11.29 AS DECIMAL(18,2))                 FROM rpt.vw_cancellations_by_city WHERE delivery_city = 'Delhi'
    UNION ALL
    SELECT 'Q4B  Hyderabad breach %',                   CAST(breach_pct AS DECIMAL(18,2)),                               CAST(96.37 AS DECIMAL(18,2))                 FROM rpt.vw_sla_by_city          WHERE delivery_city = 'Hyderabad'
    UNION ALL
    SELECT 'Q5C  Hyderabad partners',                   CAST(partners AS DECIMAL(18,2)),                                 CAST(39 AS DECIMAL(18,2))                    FROM rpt.vw_partner_capacity     WHERE delivery_city = 'Hyderabad'
    UNION ALL
    SELECT 'Q6B  high-cancellation avg rating',         CAST(avg_rating AS DECIMAL(18,2)),                               CAST(2.97 AS DECIMAL(18,2))                  FROM rpt.vw_restaurant_groups    WHERE restaurant_group LIKE 'High%'
    UNION ALL
    SELECT 'Q7A  avg rating, 15+ minutes late',         CAST(avg_rating AS DECIMAL(18,2)),                               CAST(3.13 AS DECIMAL(18,2))                  FROM rpt.vw_lateness_impact      WHERE lateness_band LIKE '5.%'
    UNION ALL
    SELECT 'Q8A  MEGA50 total contribution',            CAST(total_contribution AS DECIMAL(18,2)),                       CAST(-137160.15 AS DECIMAL(18,2))            FROM rpt.vw_promo_performance    WHERE promo_code = 'MEGA50'
    UNION ALL
    SELECT 'Q8C  MEGA50 max uses by one customer',      CAST(max_uses_by_one_customer AS DECIMAL(18,2)),                 CAST(94 AS DECIMAL(18,2))                    FROM rpt.vw_promo_abuse_check    WHERE promo_code = 'MEGA50'
    UNION ALL
    SELECT 'Q9A  Referral repeat customers %',          CAST(repeat_customer_pct AS DECIMAL(18,2)),                      CAST(79.53 AS DECIMAL(18,2))                 FROM rpt.vw_channel_retention    WHERE signup_channel = 'Referral'
    UNION ALL
    SELECT 'Q10A Champions customers',                  CAST(customers AS DECIMAL(18,2)),                                CAST(1266 AS DECIMAL(18,2))                  FROM rpt.vw_rfm_segments         WHERE segment = '1. Champions'
) AS x;
GO
 
/* =====================================================================
   Example calls of the stored procedures
   ===================================================================== */
-- EXEC rpt.usp_monthly_performance;                                              -- all cities, the whole data period
-- EXEC rpt.usp_monthly_performance @city = 'Delhi', @from_date = '2026-01-01';   -- Delhi, 2026 only
-- EXEC rpt.usp_cancellations @city = 'Hyderabad';                                -- cancellations by type in Hyderabad
-- EXEC rpt.usp_cancellations @from_date = '2025-10-01', @to_date = '2025-12-31'; -- Q4 2025, all cities
-- EXEC rpt.usp_rfm_segments;                                                     -- as of 30 June 2026
-- EXEC rpt.usp_rfm_segments @as_of_date = '2026-03-31';                          -- as it looked at the end of March 2026