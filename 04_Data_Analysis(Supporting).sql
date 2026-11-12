/* =====================================================================
   QuickBite Food Delivery Analytics
   04_Data_Analysis_supporting.sql

   Supporting checks for the headline queries in 04_Data_Analysis_lean.sql.
   Reads the dw star schema only; nothing in this script changes data.
   Definitions and known gaps are in the Q1 section of the lean file.

   Steps
   Q1   Year-on-year growth by month (Q1C)
   Q2   Average contribution per order (Q2A); by basket size (Q2B), distance (Q2C) and city (Q2D)
   Q3   Cancellations by type (Q3A), hour (Q3C), weekday (Q3D) and payment method (Q3E);
        restaurants with the most cancellations (Q3F, Q3G)
   Q4   Delay and breach share by tolerance (Q4A); breach by hour (Q4C), season (Q4D) and partner tenure (Q4E);
        worst restaurants (Q4F); tests that separate Hyderabad from the season, peak and tenure effects (Q4G to Q4J)
   Q5   Partner supply against demand by city and hour (Q5A, Q5B); Hyderabad against the other cities
        by weekday (Q5D) and by hour (Q5E)
   Q6   Lowest-rated high-volume restaurants (Q6A)
   Q7   Late-delivery effect in Hyderabad and the other cities (Q7B); cost of refunds (Q7C)
   Q8   Promo rule breaks (Q8B)
   Q9   Monthly cohort retention (Q9B); signups by channel and month (Q9C); value of the Q4 2025 campaign (Q9D)
   Q10  Revenue concentration (Q10B); top 15 customers (Q10C)
   ===================================================================== */
 
USE QuickBite;
GO
 
-- =====================================================================
-- Q1. Growth and performance
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q1C. Year on year by month: each month of 2026 against the same month of 2025 (LAG with an offset of 12 months)
-- ---------------------------------------------------------------------
WITH monthly AS (
    SELECT d.month_start,
           d.year_month,
           COUNT(*)           AS orders,
           SUM(f.gmv)         AS gmv,
           SUM(f.net_revenue) AS net_revenue
    FROM dw.fact_orders AS f
    JOIN dw.dim_date    AS d ON d.date_key = f.date_key
    GROUP BY d.month_start, d.year_month
),
yoy AS (
    SELECT year_month, month_start, orders, gmv, net_revenue,
           LAG(orders,      12) OVER (ORDER BY month_start) AS orders_year_ago,
           LAG(gmv,         12) OVER (ORDER BY month_start) AS gmv_year_ago,
           LAG(net_revenue, 12) OVER (ORDER BY month_start) AS net_revenue_year_ago
    FROM monthly
)
SELECT year_month,
       orders,
       orders_year_ago,
       CAST(100.0 * (orders - orders_year_ago) / NULLIF(orders_year_ago, 0) AS DECIMAL(6,1))                   AS orders_yoy_pct,
       gmv,
       gmv_year_ago,
       CAST(100.0 * (gmv - gmv_year_ago) / NULLIF(gmv_year_ago, 0) AS DECIMAL(6,1))                           AS gmv_yoy_pct,
       net_revenue,
       net_revenue_year_ago,
       CAST(100.0 * (net_revenue - net_revenue_year_ago) / NULLIF(net_revenue_year_ago, 0) AS DECIMAL(6,1))   AS net_revenue_yoy_pct
FROM yoy
WHERE orders_year_ago IS NOT NULL
ORDER BY month_start;
GO
-- Insight: Year-on-year growth is still strong but slowing: orders +294% in January 2026 to +89% in June (GMV +302% to
--          +86%, net revenue +322% to +93%), because 2025 kept rising while 2026 stayed flat. 

-- =====================================================================
-- Q2. Contribution per order and what pushes it up or down
--     Only delivered orders whose contribution is known are used (commission and payout both known),
--     so every average below is taken over the same orders.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q2A. Average contribution per order and its parts
--      avg_contribution = avg_commission + avg_delivery_fee - avg_discount - avg_partner_payout (the parts must add up)
-- ---------------------------------------------------------------------
SELECT COUNT(*)                                          AS orders_with_contribution,
       (SELECT COUNT(*) FROM dw.fact_orders WHERE is_delivered = 1) AS delivered_orders,
       CAST(AVG(commission_amount) AS DECIMAL(8,2))      AS avg_commission,
       CAST(AVG(delivery_fee)      AS DECIMAL(8,2))      AS avg_delivery_fee,
       CAST(AVG(discount_amount)   AS DECIMAL(8,2))      AS avg_discount,
       CAST(AVG(partner_payout)    AS DECIMAL(8,2))      AS avg_partner_payout,
       CAST(AVG(contribution)      AS DECIMAL(8,2))      AS avg_contribution,
       SUM(contribution)                                 AS total_contribution,
       CAST(100.0 * SUM(CASE WHEN contribution < 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_orders_losing_money
FROM dw.fact_orders
WHERE contribution IS NOT NULL;
GO
-- Insight: An average delivered order earns 75.07 (commission 124.10 + delivery fee 15.73 - discount 14.47 - partner payout
--          50.29), 14.74% of orders lose money, and total contribution is 3.39M. 

-- ---------------------------------------------------------------------
-- Q2B. By order size: contribution per order for each basket-size band (the orders column must add up to Q2A)
-- ---------------------------------------------------------------------
SELECT b.size_band,
       COUNT(*)                                          AS orders,
       CAST(AVG(f.subtotal)         AS DECIMAL(8,2))     AS avg_subtotal,
       CAST(AVG(f.commission_amount) AS DECIMAL(8,2))    AS avg_commission,
       CAST(AVG(f.delivery_fee)     AS DECIMAL(8,2))     AS avg_delivery_fee,
       CAST(AVG(f.discount_amount)  AS DECIMAL(8,2))     AS avg_discount,
       CAST(AVG(f.partner_payout)   AS DECIMAL(8,2))     AS avg_partner_payout,
       CAST(AVG(f.contribution)     AS DECIMAL(8,2))     AS avg_contribution,
       CAST(100.0 * SUM(CASE WHEN f.contribution < 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_orders_losing_money
FROM dw.fact_orders AS f
CROSS APPLY (SELECT CASE WHEN f.subtotal < 300  THEN '1. Under 300'
                         WHEN f.subtotal < 500  THEN '2. 300 to 499'
                         WHEN f.subtotal < 800  THEN '3. 500 to 799'
                         WHEN f.subtotal < 1200 THEN '4. 800 to 1,199'
                         ELSE '5. 1,200 and above' END AS size_band) AS b
WHERE f.contribution IS NOT NULL
GROUP BY b.size_band
ORDER BY b.size_band;
GO
-- Insight: Contribution per order rises with basket size, from 7.44 for baskets under 300 (30% of orders, 28.5% of them
--          lose money) to 272.25 for baskets of 1,200 and above, because the partner payout (about 50) is the same for
--          every basket. 

-- ---------------------------------------------------------------------
-- Q2C. By delivery distance: contribution per order for each distance band
--      Deliveries with an invalid distance (8 rows, set to NULL during cleaning) are left out.
-- ---------------------------------------------------------------------
SELECT b.distance_band,
       COUNT(*)                                          AS orders,
       CAST(AVG(d.distance_km)       AS DECIMAL(6,2))    AS avg_distance_km,
       CAST(AVG(f.delivery_fee)      AS DECIMAL(8,2))    AS avg_delivery_fee,
       CAST(AVG(f.partner_payout)    AS DECIMAL(8,2))    AS avg_partner_payout,
       CAST(AVG(f.contribution)      AS DECIMAL(8,2))    AS avg_contribution,
       CAST(100.0 * SUM(CASE WHEN f.contribution < 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_orders_losing_money
FROM dw.fact_orders     AS f
JOIN dw.fact_deliveries AS d ON d.order_id = f.order_id
CROSS APPLY (SELECT CASE WHEN d.distance_km < 2  THEN '1. Under 2 km'
                         WHEN d.distance_km < 4  THEN '2. 2 to 4 km'
                         WHEN d.distance_km < 6  THEN '3. 4 to 6 km'
                         WHEN d.distance_km < 10 THEN '4. 6 to 10 km'
                         ELSE '5. 10 km and above' END AS distance_band) AS b
WHERE f.contribution IS NOT NULL
  AND d.distance_km IS NOT NULL
GROUP BY b.distance_band
ORDER BY b.distance_band;
GO
-- Insight: Contribution per order falls as the delivery gets longer, from 84.22 under 2 km to 38.02 at 10 km and above (31%
--          of those long deliveries lose money), because the partner payout rises faster than the delivery fee.

-- ---------------------------------------------------------------------
-- Q2D. By city: contribution per order, total contribution and each city's share of it (the shares add up to 100)
-- ---------------------------------------------------------------------
SELECT f.delivery_city,
       COUNT(*)                                          AS orders,
       CAST(AVG(f.subtotal)          AS DECIMAL(8,2))    AS avg_subtotal,
       CAST(AVG(f.contribution)      AS DECIMAL(8,2))    AS avg_contribution,
       SUM(f.contribution)                               AS total_contribution,
       CAST(100.0 * SUM(f.contribution) / SUM(SUM(f.contribution)) OVER () AS DECIMAL(5,2)) AS pct_of_total_contribution,
       CAST(100.0 * SUM(CASE WHEN f.contribution < 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_orders_losing_money
FROM dw.fact_orders AS f
WHERE f.contribution IS NOT NULL
GROUP BY f.delivery_city
ORDER BY total_contribution DESC;
GO
-- Insight: Delhi earns the least per order (52.93 vs 71.76 to 89.17 in the other cities) and 19.2% of its orders lose money
--          (vs 12.0% to 14.2% elsewhere), so with about as many orders as Mumbai (9,640 vs 9,769) it contributes 510K
--          against Mumbai's 817K.
 
-- =====================================================================
-- Q3. Where and when are we losing orders?
--     Cancellation rate = cancelled orders / all orders (data dictionary). The three cancellation types are
--     Customer, Restaurant and No partner. Every query below uses ALL orders, whatever their status.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q3A. Cancellations by type, with the order value lost (expected 4,313 cancelled orders in total: 1,983 + 1,752 + 578)
-- ---------------------------------------------------------------------
SELECT cancellation_type,
       COUNT(*)                                                                         AS cancelled_orders,
       CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dw.fact_orders) AS DECIMAL(5,2))   AS pct_of_all_orders,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))                   AS pct_of_cancellations,
       SUM(total_amount)                                                                AS order_value_lost
FROM dw.fact_orders
WHERE is_cancelled = 1
GROUP BY cancellation_type
ORDER BY cancelled_orders DESC;
GO
-- Insight: 4,313 orders were cancelled (8.2% of all orders, 2.61M of order value): restaurants cause 46% of them, customers
--          41% and no partner found 13%.
 
-- ---------------------------------------------------------------------
-- Q3C. Cancellation rate by hour of the day, split by type
-- ---------------------------------------------------------------------
SELECT order_hour,
       COUNT(*)                                                                                   AS orders,
       SUM(CAST(is_cancelled AS INT))                                                             AS cancelled,
       CAST(100.0 * SUM(CAST(is_cancelled AS INT)) / COUNT(*) AS DECIMAL(5,2))                    AS cancellation_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'Customer'   THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS customer_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'Restaurant' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS restaurant_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'No partner' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS no_partner_rate
FROM dw.fact_orders
GROUP BY order_hour
ORDER BY order_hour;
GO
-- Insight: Cancellations are fairly steady through the day (7.2% to 8.2%) and rise to 8.4% to 8.8% between 18:00 and 21:59,
--          mostly from no-partner cancellations (1.3% to 1.4% vs 0.7% to 1.1% at other hours), which is a Hyderabad problem
--          (see Q5E).
 
-- ---------------------------------------------------------------------
-- Q3D. Cancellation rate by day of the week (Monday = 1), split by type
-- ---------------------------------------------------------------------
SELECT d.day_of_week_number,
       d.day_name,
       COUNT(*)                                                                                   AS orders,
       SUM(CAST(f.is_cancelled AS INT))                                                           AS cancelled,
       CAST(100.0 * SUM(CAST(f.is_cancelled AS INT)) / COUNT(*) AS DECIMAL(5,2))                  AS cancellation_rate,
       CAST(100.0 * SUM(CASE WHEN f.cancellation_type = 'Customer'   THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS customer_rate,
       CAST(100.0 * SUM(CASE WHEN f.cancellation_type = 'Restaurant' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS restaurant_rate,
       CAST(100.0 * SUM(CASE WHEN f.cancellation_type = 'No partner' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS no_partner_rate
FROM dw.fact_orders AS f
JOIN dw.dim_date    AS d ON d.date_key = f.date_key
GROUP BY d.day_of_week_number, d.day_name
ORDER BY d.day_of_week_number;
GO
-- Insight:  Saturday has the highest cancellation rate (9.17% vs 7.3% to 8.3% on the other days), and Friday and Saturday
--          have the highest no-partner rates (1.56% and 1.53% vs 0.7% to 1.0% from Monday to Thursday), which is mostly a
--          Hyderabad problem (see Q5D).
 
-- ---------------------------------------------------------------------
-- Q3E. Cancellation rate by payment method, split by type
-- ---------------------------------------------------------------------
SELECT payment_method,
       COUNT(*)                                                                                   AS orders,
       SUM(CAST(is_cancelled AS INT))                                                             AS cancelled,
       CAST(100.0 * SUM(CAST(is_cancelled AS INT)) / COUNT(*) AS DECIMAL(5,2))                    AS cancellation_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'Customer'   THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS customer_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'Restaurant' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS restaurant_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'No partner' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS no_partner_rate
FROM dw.fact_orders
GROUP BY payment_method
ORDER BY cancellation_rate DESC;
GO
-- Insight: Cash on delivery orders are cancelled 12.4% of the time vs 7.2% to 7.9% for the other payment methods, and all
--          of the gap is customer-side cancellations.
 
-- ---------------------------------------------------------------------
-- Q3F. Which restaurants cancel the most? The 15 restaurants with the highest restaurant-side cancellation rate
--      (only restaurants with at least 100 orders). Follows Q3B, which showed Delhi at 7.2% restaurant cancellations
--      against 1.3% to 4.3% in the other cities: is it a few restaurants or the whole city? See the city column.
-- ---------------------------------------------------------------------
SELECT TOP 15
       r.restaurant_id,
       r.restaurant_name,
       r.city,
       COUNT(*)                                                                                   AS orders,
       SUM(CASE WHEN f.cancellation_type = 'Restaurant' THEN 1 ELSE 0 END)                        AS restaurant_cancellations,
       CAST(100.0 * SUM(CASE WHEN f.cancellation_type = 'Restaurant' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS restaurant_cancellation_rate
FROM dw.fact_orders     AS f
JOIN dw.dim_restaurant  AS r ON r.restaurant_key = f.restaurant_key
WHERE r.restaurant_key <> -1
GROUP BY r.restaurant_id, r.restaurant_name, r.city
HAVING COUNT(*) >= 100
ORDER BY restaurant_cancellation_rate DESC;
GO
-- Insight: Twelve restaurants cancel 18% to 23% of their orders and then the rate drops to under 4%; five of the twelve are
--          in Delhi.
 
-- ---------------------------------------------------------------------
-- Q3G. How concentrated are the restaurant-side cancellations? Restaurants with 100+ orders and a restaurant cancellation
--      rate of 10% or more, against all other restaurants. Q3F showed twelve restaurants at 18% to 23% and then a drop to
--      under 4%: this query counts how much of the total those twelve explain.
-- ---------------------------------------------------------------------
WITH r AS (
    SELECT restaurant_key,
           COUNT(*)                                                             AS orders,
           SUM(CASE WHEN cancellation_type = 'Restaurant' THEN 1 ELSE 0 END)    AS restaurant_cancellations
    FROM dw.fact_orders
    WHERE restaurant_key <> -1
    GROUP BY restaurant_key
)
SELECT CASE WHEN orders >= 100 AND 100.0 * restaurant_cancellations / orders >= 10
            THEN 'Rate 10% or more (100+ orders)' ELSE 'All other restaurants' END                      AS restaurant_group,
       COUNT(*)                                                                                         AS restaurants,
       SUM(orders)                                                                                      AS orders,
       SUM(restaurant_cancellations)                                                                    AS restaurant_cancellations,
       CAST(100.0 * SUM(restaurant_cancellations) / SUM(orders) AS DECIMAL(5,2))                        AS cancellation_rate,
       CAST(100.0 * SUM(restaurant_cancellations) / (SELECT SUM(restaurant_cancellations) FROM r) AS DECIMAL(5,2)) AS pct_of_all_restaurant_cancellations
FROM r
GROUP BY CASE WHEN orders >= 100 AND 100.0 * restaurant_cancellations / orders >= 10
              THEN 'Rate 10% or more (100+ orders)' ELSE 'All other restaurants' END
ORDER BY restaurant_cancellations DESC;
GO
-- Insight: Those 12 restaurants cancel 20.7% of their orders vs 1.1% for the other 308 and cause about 74% of all
--          restaurant-side cancellations, so a handful of restaurants explains the problem.
 
-- =====================================================================
-- Q4. How often do we miss the delivery promise (SLA) and what drives delays?
--     delay_minutes = delivery_minutes - promised_minutes, measured from the moment the order was placed (data dictionary).
--     is_sla_breach uses a tolerance of 1 minute (see step 8 in 03_Data_Modelling.sql).
--     Only deliveries with a known breach flag are used: 48,012 deliveries minus those without a delivery time (192)
--     or without a promised time.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q4A. Is the breach rate believable? The delay in numbers, and the breach share under different tolerances
--      The breach_pct_1min column must equal the 67.81% found in check VM7.
-- ---------------------------------------------------------------------
SELECT COUNT(*)                                                                  AS deliveries_measured,
       CAST(AVG(CAST(promised_minutes AS DECIMAL(8,2))) AS DECIMAL(6,2))         AS avg_promised_minutes,
       CAST(AVG(delivery_minutes) AS DECIMAL(6,2))                               AS avg_delivery_minutes,
       CAST(AVG(delay_minutes)    AS DECIMAL(6,2))                               AS avg_delay_minutes,
       (SELECT DISTINCT CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delay_minutes) OVER () AS DECIMAL(6,2))
        FROM dw.fact_deliveries WHERE is_sla_breach IS NOT NULL)                 AS median_delay_minutes,
       CAST(100.0 * SUM(CASE WHEN delay_minutes > 0  THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS breach_pct_strict,
       CAST(100.0 * SUM(CASE WHEN delay_minutes > 1  THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS breach_pct_1min,
       CAST(100.0 * SUM(CASE WHEN delay_minutes > 5  THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS breach_pct_5min,
       CAST(100.0 * SUM(CASE WHEN delay_minutes > 10 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS breach_pct_10min,
       CAST(100.0 * SUM(CASE WHEN delay_minutes > 15 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS breach_pct_15min
FROM dw.fact_deliveries
WHERE is_sla_breach IS NOT NULL;
GO
-- Insight: The typical delivery arrives about 4 minutes after the promise (median 4.2, average 5.0); 67.81% are more than 1
--          minute late but only 22.94% are more than 10 minutes late, so most breaches are small.
 
-- ---------------------------------------------------------------------
-- Q4C. Breach rate by hour the order was placed (find the peak hours)
-- ---------------------------------------------------------------------
SELECT d.order_hour,
       COUNT(*)                                                                          AS deliveries,
       CAST(100.0 * SUM(CAST(d.is_sla_breach AS INT)) / COUNT(*) AS DECIMAL(5,2))        AS breach_pct,
       CAST(AVG(d.delivery_minutes) AS DECIMAL(6,2))                                     AS avg_delivery_minutes,
       CAST(AVG(d.delay_minutes)    AS DECIMAL(6,2))                                     AS avg_delay_minutes
FROM dw.fact_deliveries AS d
WHERE d.is_sla_breach IS NOT NULL
GROUP BY d.order_hour
ORDER BY d.order_hour;
GO
-- Insight: Breach rates are 62% to 66% in most hours and jump to about 73% between 19:00 and 22:59, when the average delay
--          is about 6.3 minutes vs about 4 minutes at other hours.
 
-- ---------------------------------------------------------------------
-- Q4D. Breach rate by weather season (Winter Dec to Feb, Summer Mar to May, Monsoon Jun to Sep, Post-monsoon Oct to Nov)
--      See also Q4I: the monsoon gap comes entirely from July and August 2025. June 2025, September 2025 and June 2026
--      are normal, so this is a two-month episode, not a seasonal pattern.
-- ---------------------------------------------------------------------
SELECT dt.season,
       COUNT(*)                                                                          AS deliveries,
       CAST(100.0 * SUM(CAST(d.is_sla_breach AS INT)) / COUNT(*) AS DECIMAL(5,2))        AS breach_pct,
       CAST(AVG(d.delivery_minutes) AS DECIMAL(6,2))                                     AS avg_delivery_minutes,
       CAST(AVG(d.delay_minutes)    AS DECIMAL(6,2))                                     AS avg_delay_minutes
FROM dw.fact_deliveries AS d
JOIN dw.dim_date        AS dt ON dt.date_key = d.date_key
WHERE d.is_sla_breach IS NOT NULL
GROUP BY dt.season
ORDER BY breach_pct DESC;
GO
-- Insight: Monsoon has the highest breach rate (74.4% vs 64.7% to 65.9% in the other seasons), but that comes only from
--          July and August 2025 (see Q4I), so it is a two-month episode, not a seasonal pattern.
 
-- ---------------------------------------------------------------------
-- Q4E. Breach rate by partner tenure (days between the partner's joining date and the order)
-- ---------------------------------------------------------------------
SELECT b.tenure_band,
       COUNT(*)                                                                          AS deliveries,
       CAST(100.0 * SUM(CAST(d.is_sla_breach AS INT)) / COUNT(*) AS DECIMAL(5,2))        AS breach_pct,
       CAST(AVG(d.delivery_minutes) AS DECIMAL(6,2))                                     AS avg_delivery_minutes,
       CAST(AVG(d.delay_minutes)    AS DECIMAL(6,2))                                     AS avg_delay_minutes
FROM dw.fact_deliveries AS d
CROSS APPLY (SELECT CASE WHEN d.partner_tenure_days < 90  THEN '1. Under 90 days'
                         WHEN d.partner_tenure_days < 180 THEN '2. 90 to 179 days'
                         WHEN d.partner_tenure_days < 365 THEN '3. 180 to 364 days'
                         WHEN d.partner_tenure_days < 730 THEN '4. 365 to 729 days'
                         ELSE '5. 730 days and above' END AS tenure_band) AS b
WHERE d.is_sla_breach IS NOT NULL
  AND d.partner_tenure_days IS NOT NULL
GROUP BY b.tenure_band
ORDER BY b.tenure_band;
GO
-- Insight: The breach rate falls as partners gain experience, from 79.8% in the first 90 days to 65.9% after two years (the
--          first-90-day effect is confirmed in Q4H and Q4J).
-- ---------------------------------------------------------------------
-- Q4F. The 15 restaurants with the highest breach rate (only restaurants with at least 100 measured deliveries)
-- ---------------------------------------------------------------------
SELECT TOP 15
       r.restaurant_id,
       r.restaurant_name,
       r.city,
       COUNT(*)                                                                          AS deliveries,
       CAST(100.0 * SUM(CAST(d.is_sla_breach AS INT)) / COUNT(*) AS DECIMAL(5,2))        AS breach_pct,
       CAST(AVG(d.delay_minutes) AS DECIMAL(6,2))                                        AS avg_delay_minutes
FROM dw.fact_deliveries AS d
JOIN dw.dim_restaurant  AS r ON r.restaurant_key = d.restaurant_key
WHERE d.is_sla_breach IS NOT NULL
  AND r.restaurant_key <> -1
GROUP BY r.restaurant_id, r.restaurant_name, r.city
HAVING COUNT(*) >= 100
ORDER BY breach_pct DESC;
GO
-- Insight: All 15 restaurants with the highest breach rate (96% to 100%) are in Hyderabad.
 
-- ---------------------------------------------------------------------
-- Q4G. Are the season and dinner-peak effects real, or just Hyderabad? (Q4B showed Hyderabad far above every other city)
--      The same breach rate split into Hyderabad and the other six cities, by season and by dinner peak (19:00 to 22:59).
--      If the gaps between seasons and between peak and other hours also show in "Other cities", they are real effects.
-- ---------------------------------------------------------------------
SELECT dt.season,
       b.peak_slot,
       b.city_group,
       COUNT(*)                                                                          AS deliveries,
       CAST(100.0 * SUM(CAST(d.is_sla_breach AS INT)) / COUNT(*) AS DECIMAL(5,2))        AS breach_pct,
       CAST(AVG(d.delay_minutes) AS DECIMAL(6,2))                                        AS avg_delay_minutes
FROM dw.fact_deliveries AS d
JOIN dw.fact_orders     AS f  ON f.order_id  = d.order_id
JOIN dw.dim_date        AS dt ON dt.date_key = d.date_key
CROSS APPLY (SELECT CASE WHEN d.order_hour BETWEEN 19 AND 22 THEN 'Dinner peak 19-22' ELSE 'Other hours' END AS peak_slot,
                    CASE WHEN f.delivery_city = 'Hyderabad' THEN 'Hyderabad' ELSE 'Other cities' END        AS city_group) AS b
WHERE d.is_sla_breach IS NOT NULL
GROUP BY dt.season, b.peak_slot, b.city_group
ORDER BY b.city_group, dt.season, b.peak_slot;
GO
-- Insight: Outside Hyderabad the dinner peak (19:00 to 22:59) is 9 to 15 points worse than other hours in every season, so
--          it is a real effect; Hyderabad is above 94% in every season and time slot.
 
-- ---------------------------------------------------------------------
-- Q4H. Is the new-partner effect real, or are Hyderabad's partners simply newer? Breach rate by partner tenure band,
--      Hyderabad against the other cities
-- ---------------------------------------------------------------------
SELECT b.tenure_band,
       b.city_group,
       COUNT(*)                                                                          AS deliveries,
       CAST(100.0 * SUM(CAST(d.is_sla_breach AS INT)) / COUNT(*) AS DECIMAL(5,2))        AS breach_pct,
       CAST(AVG(d.delay_minutes) AS DECIMAL(6,2))                                        AS avg_delay_minutes
FROM dw.fact_deliveries AS d
JOIN dw.fact_orders     AS f ON f.order_id = d.order_id
CROSS APPLY (SELECT CASE WHEN d.partner_tenure_days < 90  THEN '1. Under 90 days'
                         WHEN d.partner_tenure_days < 180 THEN '2. 90 to 179 days'
                         WHEN d.partner_tenure_days < 365 THEN '3. 180 to 364 days'
                         WHEN d.partner_tenure_days < 730 THEN '4. 365 to 729 days'
                         ELSE '5. 730 days and above' END                                  AS tenure_band,
                    CASE WHEN f.delivery_city = 'Hyderabad' THEN 'Hyderabad' ELSE 'Other cities' END AS city_group) AS b
WHERE d.is_sla_breach IS NOT NULL
  AND d.partner_tenure_days IS NOT NULL
GROUP BY b.tenure_band, b.city_group
ORDER BY b.tenure_band, b.city_group;
GO
-- Insight: Hyderabad is late 95% to 98% at every partner tenure level, so its problem is not new partners; in the other
--          cities partners in their first 90 days are late 76.7% of the time vs 62.0% to 64.2% for everyone else, so the
--          new-partner effect is real. 

-- ---------------------------------------------------------------------
-- Q4I. Did Hyderabad's delays always exist or start at some point? Breach rate by month, Hyderabad against the other cities
-- ---------------------------------------------------------------------
SELECT dt.year_month,
       b.city_group,
       COUNT(*)                                                                          AS deliveries,
       CAST(100.0 * SUM(CAST(d.is_sla_breach AS INT)) / COUNT(*) AS DECIMAL(5,2))        AS breach_pct,
       CAST(AVG(d.delay_minutes) AS DECIMAL(6,2))                                        AS avg_delay_minutes
FROM dw.fact_deliveries AS d
JOIN dw.fact_orders     AS f  ON f.order_id  = d.order_id
JOIN dw.dim_date        AS dt ON dt.date_key = d.date_key
CROSS APPLY (SELECT CASE WHEN f.delivery_city = 'Hyderabad' THEN 'Hyderabad' ELSE 'Other cities' END AS city_group) AS b
WHERE d.is_sla_breach IS NOT NULL
GROUP BY dt.year_month, b.city_group
ORDER BY dt.year_month, b.city_group;
GO
-- Insight:  Hyderabad is late 94.6% to 100% of the time in every one of the 18 months, and in July and August 2025 every
--           city jumped (about 5 minutes more delay; breach 87% to 88% in the other cities vs about 60% in the other
--           months).
 
-- ---------------------------------------------------------------------
-- Q4J. Does the new-partner effect survive once the July and August 2025 shock is removed? (Q4I showed that shock in every city)
--      Breach rate by partner tenure band, the six cities other than Hyderabad, July and August 2025 left out.
--      If partners under 90 days are still clearly worse than the others, the effect is real.
-- ---------------------------------------------------------------------
SELECT b.tenure_band,
       COUNT(*)                                                                          AS deliveries,
       CAST(100.0 * SUM(CAST(d.is_sla_breach AS INT)) / COUNT(*) AS DECIMAL(5,2))        AS breach_pct,
       CAST(AVG(d.delay_minutes) AS DECIMAL(6,2))                                        AS avg_delay_minutes
FROM dw.fact_deliveries AS d
JOIN dw.fact_orders     AS f  ON f.order_id  = d.order_id
JOIN dw.dim_date        AS dt ON dt.date_key = d.date_key
CROSS APPLY (SELECT CASE WHEN d.partner_tenure_days < 90  THEN '1. Under 90 days'
                         WHEN d.partner_tenure_days < 180 THEN '2. 90 to 179 days'
                         WHEN d.partner_tenure_days < 365 THEN '3. 180 to 364 days'
                         WHEN d.partner_tenure_days < 730 THEN '4. 365 to 729 days'
                         ELSE '5. 730 days and above' END AS tenure_band) AS b
WHERE d.is_sla_breach IS NOT NULL
  AND d.partner_tenure_days IS NOT NULL
  AND f.delivery_city <> 'Hyderabad'
  AND dt.year_month NOT IN ('2025-07', '2025-08')
GROUP BY b.tenure_band
ORDER BY b.tenure_band;
GO
-- Insight: Even without July and August 2025 and without Hyderabad, partners in their first 90 days are late 74.3% of the
--          time vs 59.5% to 60.8% for everyone else, so the new-partner effect is real.

-- =====================================================================
-- Q5. Do we have too few delivery partners in some cities at peak times?
--     A time slot is one city, one day and one hour. Demand = orders placed in the slot. Supply = partners who made at least
--     one delivery in the slot (partners who were available but idle cannot be seen in this data, so supply is a lower bound).
--     "No partner" cancellations are the direct sign of a shortage.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q5A. City by hour grid: orders, orders per active partner and the share of orders lost for lack of a partner
--      (98 rows, 7 cities by the 14 hours from 10:00 to 23:59 when orders are placed; this is the data for a heat map in Power BI)
--      NOTE: orders_per_active_partner stays between 1.03 and 1.16 in every slot (each partner makes about one delivery per hour slot),
--      so it mostly reflects cancellations and does NOT show a shortage. no_partner_pct is the real shortage signal.
-- ---------------------------------------------------------------------
WITH slot AS (
    SELECT delivery_city, date_key, order_hour,
           COUNT(*)                                                          AS orders,
           SUM(CASE WHEN cancellation_type = 'No partner' THEN 1 ELSE 0 END) AS no_partner_orders
    FROM dw.fact_orders
    GROUP BY delivery_city, date_key, order_hour
),
supply AS (
    SELECT f.delivery_city, f.date_key, f.order_hour,
           COUNT(DISTINCT d.partner_key) AS active_partners
    FROM dw.fact_deliveries AS d
    JOIN dw.fact_orders     AS f ON f.order_id = d.order_id
    GROUP BY f.delivery_city, f.date_key, f.order_hour
)
SELECT s.delivery_city,
       s.order_hour,
       SUM(s.orders)                                                                        AS orders,
       CAST(1.0 * SUM(s.orders) / NULLIF(SUM(ISNULL(p.active_partners, 0)), 0) AS DECIMAL(6,2)) AS orders_per_active_partner,
       SUM(s.no_partner_orders)                                                             AS no_partner_cancellations,
       CAST(100.0 * SUM(s.no_partner_orders) / SUM(s.orders) AS DECIMAL(5,2))               AS no_partner_pct
FROM slot AS s
LEFT JOIN supply AS p
       ON p.delivery_city = s.delivery_city AND p.date_key = s.date_key AND p.order_hour = s.order_hour
GROUP BY s.delivery_city, s.order_hour
ORDER BY s.delivery_city, s.order_hour;
GO
-- Insight: Orders per active partner is 1.03 to 1.16 in every slot, so it does not show a shortage; no_partner_pct is the
--          real signal.
 
-- ---------------------------------------------------------------------
-- Q5B. The 15 worst city-and-hour combinations: highest share of orders lost for lack of a partner (at least 100 orders)
-- ---------------------------------------------------------------------
WITH slot AS (
    SELECT delivery_city, date_key, order_hour,
           COUNT(*)                                                          AS orders,
           SUM(CASE WHEN cancellation_type = 'No partner' THEN 1 ELSE 0 END) AS no_partner_orders
    FROM dw.fact_orders
    GROUP BY delivery_city, date_key, order_hour
),
supply AS (
    SELECT f.delivery_city, f.date_key, f.order_hour,
           COUNT(DISTINCT d.partner_key) AS active_partners
    FROM dw.fact_deliveries AS d
    JOIN dw.fact_orders     AS f ON f.order_id = d.order_id
    GROUP BY f.delivery_city, f.date_key, f.order_hour
)
SELECT TOP 15
       s.delivery_city,
       s.order_hour,
       SUM(s.orders)                                                                        AS orders,
       CAST(1.0 * SUM(s.orders) / NULLIF(SUM(ISNULL(p.active_partners, 0)), 0) AS DECIMAL(6,2)) AS orders_per_active_partner,
       SUM(s.no_partner_orders)                                                             AS no_partner_cancellations,
       CAST(100.0 * SUM(s.no_partner_orders) / SUM(s.orders) AS DECIMAL(5,2))               AS no_partner_pct
FROM slot AS s
LEFT JOIN supply AS p
       ON p.delivery_city = s.delivery_city AND p.date_key = s.date_key AND p.order_hour = s.order_hour
GROUP BY s.delivery_city, s.order_hour
HAVING SUM(s.orders) >= 100
ORDER BY no_partner_pct DESC;
GO
-- Insight: Hyderabad holds the 9 worst city-and-hour slots and 11 of the worst 15 for no-partner cancellations (up to 5.5%
--          of orders lost at 20:00 to 21:59).
 
-- ---------------------------------------------------------------------
-- Q5D. "No partner" cancellation rate by day of the week, Hyderabad against the other six cities
--      (Q3D showed Friday and Saturday "highest no-partner rate": is that Hyderabad or everywhere?)
-- ---------------------------------------------------------------------
SELECT d.day_of_week_number,
       d.day_name,
       b.city_group,
       COUNT(*)                                                                           AS orders,
       SUM(CASE WHEN f.cancellation_type = 'No partner' THEN 1 ELSE 0 END)                AS no_partner_cancellations,
       CAST(100.0 * SUM(CASE WHEN f.cancellation_type = 'No partner' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS no_partner_pct
FROM dw.fact_orders AS f
JOIN dw.dim_date    AS d ON d.date_key = f.date_key
CROSS APPLY (SELECT CASE WHEN f.delivery_city = 'Hyderabad' THEN 'Hyderabad' ELSE 'Other cities' END AS city_group) AS b
GROUP BY d.day_of_week_number, d.day_name, b.city_group
ORDER BY b.city_group, d.day_of_week_number;
GO
-- Insight: Hyderabad loses 4.9% of its Friday orders and 5.9% of its Saturday orders for lack of a partner (1.9% to 2.8%
--          from Monday to Thursday), vs 0.5% to 1.1% on every day in the other cities, so the weekend shortage is
--          Hyderabad's.
 
-- ---------------------------------------------------------------------
-- Q5E. "No partner" cancellation rate by hour, Hyderabad against the other six cities
--      (Q3C showed a rise at dinner overall: is that Hyderabad or everywhere?)
-- ---------------------------------------------------------------------
SELECT f.order_hour,
       b.city_group,
       COUNT(*)                                                                           AS orders,
       SUM(CASE WHEN f.cancellation_type = 'No partner' THEN 1 ELSE 0 END)                AS no_partner_cancellations,
       CAST(100.0 * SUM(CASE WHEN f.cancellation_type = 'No partner' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS no_partner_pct
FROM dw.fact_orders AS f
CROSS APPLY (SELECT CASE WHEN f.delivery_city = 'Hyderabad' THEN 'Hyderabad' ELSE 'Other cities' END AS city_group) AS b
GROUP BY f.order_hour, b.city_group
ORDER BY b.city_group, f.order_hour;
GO
-- Insight: Hyderabad loses 4.6% of the orders placed from 18:00 to 22:59 for lack of a partner vs under 1.1% in the other
--          cities.
 
-- =====================================================================
-- Q6. Which restaurants are high-volume but hurt the customer experience?
--     High volume = the top fifth of restaurants by number of orders (NTILE). Customer experience is read from four numbers per restaurant:
--     average rating (reviews with a valid rating), late share (is_sla_breach), refund share (refunded orders / orders that reached
--     the customer) and restaurant-side cancellation share (of all its orders). Orders of the unknown restaurant are left out.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q6A. The 20 lowest-rated restaurants among the high-volume fifth (restaurants with at least 30 rated reviews)
--      Late share depends heavily on the city (Hyderabad is late almost always, see Q4B), so compare late_pct only inside one city.
-- ---------------------------------------------------------------------
WITH o AS (
    SELECT restaurant_key,
           COUNT(*)                                                          AS orders,
           SUM(CAST(is_delivered AS INT))                                    AS delivered_orders,
           SUM(CAST(is_refunded  AS INT))                                    AS refunded_orders,
           SUM(CASE WHEN cancellation_type = 'Restaurant' THEN 1 ELSE 0 END) AS restaurant_cancellations
    FROM dw.fact_orders
    WHERE restaurant_key <> -1
    GROUP BY restaurant_key
),
rv AS (
    SELECT restaurant_key,
           COUNT(rating)                           AS reviews,
           AVG(CAST(rating AS DECIMAL(4,2)))       AS avg_rating
    FROM dw.fact_reviews
    GROUP BY restaurant_key
),
dl AS (
    SELECT restaurant_key,
           COUNT(*)                                AS deliveries_measured,
           SUM(CAST(is_sla_breach AS INT))         AS late_deliveries
    FROM dw.fact_deliveries
    WHERE is_sla_breach IS NOT NULL
    GROUP BY restaurant_key
),
scored AS (
    SELECT o.restaurant_key, o.orders, o.delivered_orders, o.refunded_orders, o.restaurant_cancellations,
           rv.reviews, rv.avg_rating, dl.deliveries_measured, dl.late_deliveries,
           NTILE(5) OVER (ORDER BY o.orders DESC) AS volume_quintile
    FROM o
    LEFT JOIN rv ON rv.restaurant_key = o.restaurant_key
    LEFT JOIN dl ON dl.restaurant_key = o.restaurant_key
)
SELECT TOP 20
       r.restaurant_id,
       r.restaurant_name,
       r.city,
       s.orders,
       s.reviews,
       CAST(s.avg_rating AS DECIMAL(4,2))                                                                     AS avg_rating,
       CAST(100.0 * s.late_deliveries / NULLIF(s.deliveries_measured, 0) AS DECIMAL(5,2))                     AS late_pct,
       CAST(100.0 * s.refunded_orders / NULLIF(s.delivered_orders + s.refunded_orders, 0) AS DECIMAL(5,2))    AS refund_pct,
       CAST(100.0 * s.restaurant_cancellations / s.orders AS DECIMAL(5,2))                                    AS restaurant_cancel_pct
FROM scored AS s
JOIN dw.dim_restaurant AS r ON r.restaurant_key = s.restaurant_key
WHERE s.volume_quintile = 1
  AND s.reviews >= 30
ORDER BY s.avg_rating ASC;
GO
-- Insight: Of the 20 lowest-rated big restaurants, 12 (avg rating 2.66 to 3.08) cancel 18% to 23% of their orders,
--          while the Hyderabad restaurants further down are late 94% to 97% of the time but rate 3.76 to 3.88 and
--          cancel under 2%, so lateness alone does not push a restaurant to the bottom.
 
-- =====================================================================
-- Q7. How much do late deliveries hurt ratings and refunds?
--     Lateness is measured against the promise (delay_minutes). Deliveries without a known delay are left out.
--     refund_pct = refunded orders / deliveries (a refunded order is a delivery that happened).
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q7B. Is the late-delivery effect the same in Hyderabad and the other cities? Late against on time, by city group
-- ---------------------------------------------------------------------
SELECT b.city_group,
       CASE WHEN d.is_sla_breach = 1 THEN 'Late' ELSE 'On time' END                               AS delivery_status,
       COUNT(*)                                                                                   AS deliveries,
       COUNT(rv.rating)                                                                           AS reviews,
       CAST(AVG(CAST(rv.rating AS DECIMAL(4,2))) AS DECIMAL(4,2))                                 AS avg_rating,
       CAST(100.0 * SUM(CAST(f.is_refunded AS INT)) / COUNT(*) AS DECIMAL(5,2))                   AS refund_pct
FROM dw.fact_deliveries AS d
JOIN dw.fact_orders     AS f  ON f.order_id  = d.order_id
LEFT JOIN dw.fact_reviews AS rv ON rv.order_id = d.order_id
CROSS APPLY (SELECT CASE WHEN f.delivery_city = 'Hyderabad' THEN 'Hyderabad' ELSE 'Other cities' END AS city_group) AS b
WHERE d.is_sla_breach IS NOT NULL
GROUP BY b.city_group, CASE WHEN d.is_sla_breach = 1 THEN 'Late' ELSE 'On time' END
ORDER BY b.city_group, delivery_status;
GO
-- Insight: Lateness lowers ratings in every city (0.76 stars in Hyderabad, 4.46 vs 3.70, and 0.55 elsewhere, 4.41 vs 3.86),
--          and the refund gap is clear only outside Hyderabad (2.15% vs 1.65%) because Hyderabad has very few on-time
--          deliveries (about 4 refunds).
 
-- ---------------------------------------------------------------------
-- Q7C. What do refunds cost? Refunded value, how it compares with GMV, and how many refunds follow a late delivery
--      (GMV counts delivered orders only, so the percentage is refunded value against GMV, not a share of it)
-- ---------------------------------------------------------------------
SELECT SUM(CAST(f.is_refunded AS INT))                                              AS refunded_orders,
       SUM(f.refunded_amount)                                                       AS refunded_value,
       (SELECT SUM(gmv) FROM dw.fact_orders)                                        AS gmv,
       CAST(100.0 * SUM(f.refunded_amount) / (SELECT SUM(gmv) FROM dw.fact_orders) AS DECIMAL(5,2)) AS refunded_value_vs_gmv_pct,
       CAST(100.0 * SUM(CASE WHEN f.is_refunded = 1 AND d.is_sla_breach = 1 THEN 1 ELSE 0 END)
                  / NULLIF(SUM(CAST(f.is_refunded AS INT)), 0) AS DECIMAL(5,2))     AS pct_of_refunds_after_a_late_delivery,
       CAST(100.0 * SUM(CASE WHEN d.is_sla_breach = 1 THEN 1 ELSE 0 END)
                  / NULLIF(SUM(CASE WHEN d.is_sla_breach IS NOT NULL THEN 1 ELSE 0 END), 0) AS DECIMAL(5,2)) AS pct_of_all_deliveries_late
FROM dw.fact_orders AS f
LEFT JOIN dw.fact_deliveries AS d ON d.order_id = f.order_id;
GO
-- Insight: Refunds cost 587,679 (2.01% of GMV, 947 orders) and 72.65% of them follow a late delivery, but 67.81% of all
--          deliveries are late, so refunds are only weakly tied to lateness and fixing lateness will lift ratings more than
--          it cuts refund cost.
 
-- =====================================================================
-- Q8. Which promo codes make money, and is any promo being abused?
--     Contribution is the delivered orders with a known contribution (see the definitions under Q1 in 04_Data_Analysis_lean.sql). "NO PROMO" is the comparison group.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q8B. Promo rule breaks: orders that used a promo outside its dates, below its minimum order value or above its discount cap
--      (all orders with a promo, whatever their status; a count above 0 is worth explaining, not necessarily fraud)
-- ---------------------------------------------------------------------
SELECT p.promo_code,
       p.start_date,
       p.end_date,
       p.min_order_value,
       p.max_discount,
       COUNT(*)                                                                                         AS promo_orders,
       SUM(CASE WHEN CAST(f.order_datetime AS DATE) < p.start_date
                  OR CAST(f.order_datetime AS DATE) > p.end_date THEN 1 ELSE 0 END)                      AS outside_validity_dates,
       SUM(CASE WHEN f.subtotal < p.min_order_value THEN 1 ELSE 0 END)                                   AS below_minimum_order,
       SUM(CASE WHEN f.discount_amount > p.max_discount THEN 1 ELSE 0 END)                               AS discount_above_cap
FROM dw.fact_orders AS f
JOIN dw.dim_promo   AS p ON p.promo_key = f.promo_key
WHERE f.promo_key <> -1
GROUP BY p.promo_code, p.start_date, p.end_date, p.min_order_value, p.max_discount
ORDER BY outside_validity_dates DESC;
GO
-- Insight: None of the 9,142 promo orders broke a rule (all three columns are 0), so the losses are by design and the gap
--          is the missing per-customer limit.
 
-- =====================================================================
-- Q9. Which acquisition channel brings customers who stay? Was the Q4 2025 promo campaign worth it?
--     A customer "stays" when they place a further DELIVERED order. Cohorts and first orders use the first delivered order,
--     not signup_date (40 customers signed up after their first order, log #50). The channel comes from signup_channel.
--     The data ends on 30 June 2026, so retention windows are only measured for customers who had enough time to come back.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q9B. Monthly cohort retention: of the customers whose first delivered order was in a month, the share who ordered again
--      in each of the next three calendar months (empty where that month is after the end of the data)
-- ---------------------------------------------------------------------
WITH o AS (
    SELECT customer_key, DATEFROMPARTS(YEAR(order_datetime), MONTH(order_datetime), 1) AS order_month
    FROM dw.fact_orders
    WHERE is_delivered = 1
      AND customer_key <> -1
),
cohort AS (
    SELECT customer_key, MIN(order_month) AS cohort_month
    FROM o
    GROUP BY customer_key
),
activity AS (
    SELECT c.cohort_month, c.customer_key, DATEDIFF(MONTH, c.cohort_month, o.order_month) AS month_offset
    FROM cohort AS c
    JOIN o ON o.customer_key = c.customer_key
    GROUP BY c.cohort_month, c.customer_key, DATEDIFF(MONTH, c.cohort_month, o.order_month)
),
counts AS (
    SELECT cohort_month,
           COUNT(DISTINCT CASE WHEN month_offset = 0 THEN customer_key END) AS cohort_size,
           COUNT(DISTINCT CASE WHEN month_offset = 1 THEN customer_key END) AS active_m1,
           COUNT(DISTINCT CASE WHEN month_offset = 2 THEN customer_key END) AS active_m2,
           COUNT(DISTINCT CASE WHEN month_offset = 3 THEN customer_key END) AS active_m3
    FROM activity
    GROUP BY cohort_month
)
SELECT cohort_month,
       cohort_size,
       CASE WHEN DATEADD(MONTH, 1, cohort_month) <= '2026-06-01' THEN CAST(100.0 * active_m1 / cohort_size AS DECIMAL(5,2)) END AS retained_month_1_pct,
       CASE WHEN DATEADD(MONTH, 2, cohort_month) <= '2026-06-01' THEN CAST(100.0 * active_m2 / cohort_size AS DECIMAL(5,2)) END AS retained_month_2_pct,
       CASE WHEN DATEADD(MONTH, 3, cohort_month) <= '2026-06-01' THEN CAST(100.0 * active_m3 / cohort_size AS DECIMAL(5,2)) END AS retained_month_3_pct
FROM counts
ORDER BY cohort_month;
GO
-- Insight: The October to December 2025 cohorts retain worst (month-1 about 36% vs 47% to 50% for the others, month-3 about
--          24% vs 37%), the same time as the campaign.
 
-- ---------------------------------------------------------------------
-- Q9C. When did each channel bring customers in? Signups per month by channel (find the Q4 2025 campaign)
--      The channel names are those of the clean data; a column of zeros means the name differs, change it here.
-- ---------------------------------------------------------------------
SELECT DATEFROMPARTS(YEAR(signup_date), MONTH(signup_date), 1)                  AS signup_month,
       SUM(CASE WHEN signup_channel = 'Organic'        THEN 1 ELSE 0 END)       AS organic,
       SUM(CASE WHEN signup_channel = 'Paid Ads'       THEN 1 ELSE 0 END)       AS paid_ads,
       SUM(CASE WHEN signup_channel = 'Influencer'     THEN 1 ELSE 0 END)       AS influencer,
       SUM(CASE WHEN signup_channel = 'Referral'       THEN 1 ELSE 0 END)       AS referral,
       SUM(CASE WHEN signup_channel = 'Promo Campaign' THEN 1 ELSE 0 END)       AS promo_campaign,
       COUNT(*)                                                                 AS total_signups
FROM dw.dim_customer
WHERE customer_key <> -1
  AND signup_date IS NOT NULL
GROUP BY DATEFROMPARTS(YEAR(signup_date), MONTH(signup_date), 1)
ORDER BY signup_month;
GO
-- Insight: Promo Campaign signups jumped from 2 to 27 a month to 258, 442 and 203 in October to December 2025 while the
--          other channels stayed flat, so the campaign added customers rather than moving them.
 
-- ---------------------------------------------------------------------
-- Q9D. Was the Q4 2025 campaign worth it? Customers who signed up through "Promo Campaign" in October to December 2025,
--      against Promo Campaign signups in other months and against every other channel.
--      There is no campaign cost in the data, so "worth it" is judged by what the customers bring: orders and contribution
--      (contribution already has the discounts taken off).
-- ---------------------------------------------------------------------
WITH o AS (
    SELECT customer_key,
           COUNT(*)                     AS delivered_orders,
           SUM(contribution)            AS contribution,
           SUM(discount_amount)         AS discounts
    FROM dw.fact_orders
    WHERE is_delivered = 1
      AND customer_key <> -1
    GROUP BY customer_key
),
c AS (
    SELECT cu.customer_key,
           CASE WHEN cu.signup_channel = 'Promo Campaign' AND cu.signup_date >= '2025-10-01' AND cu.signup_date < '2026-01-01'
                    THEN '1. Promo Campaign, signed up Oct-Dec 2025'
                WHEN cu.signup_channel = 'Promo Campaign' THEN '2. Promo Campaign, other months'
                ELSE '3. All other channels' END AS customer_group,
           o.delivered_orders, o.contribution, o.discounts
    FROM dw.dim_customer AS cu
    LEFT JOIN o ON o.customer_key = cu.customer_key
    WHERE cu.customer_key <> -1
)
SELECT customer_group,
       COUNT(*)                                                                                       AS customers_signed_up,
       SUM(CASE WHEN delivered_orders >= 1 THEN 1 ELSE 0 END)                                         AS customers_who_ordered,
       CAST(100.0 * SUM(CASE WHEN delivered_orders >= 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS activation_pct,
       CAST(100.0 * SUM(CASE WHEN delivered_orders >= 2 THEN 1 ELSE 0 END)
                  / NULLIF(SUM(CASE WHEN delivered_orders >= 1 THEN 1 ELSE 0 END), 0) AS DECIMAL(5,2)) AS repeat_pct_of_those_who_ordered,
       CAST(AVG(1.0 * delivered_orders) AS DECIMAL(6,2))                                              AS avg_orders_per_customer_who_ordered,
       CAST(AVG(contribution) AS DECIMAL(8,2))                                                        AS avg_contribution_per_customer_who_ordered,
       CAST(SUM(contribution) / COUNT(*) AS DECIMAL(8,2))                                             AS contribution_per_signed_up_customer,
       CAST(SUM(discounts) / NULLIF(SUM(delivered_orders), 0) AS DECIMAL(8,2))                        AS avg_discount_per_order
FROM c
GROUP BY customer_group
ORDER BY customer_group;
GO
-- Insight: Customers from the Q4 2025 campaign are worth about 140 contribution per signup vs 669 for the other channels
--          and only 32% reorder (vs 69%), so unless the campaign cost under about 140 per signup (no cost is in the data)
--          it did not pay off.
 
-- =====================================================================
-- Q10. Who are the most valuable customers?
--      Delivered orders only. Recency = days from the last order to 30 June 2026 (the end of the data); frequency = number of
--      delivered orders; monetary = GMV. Each is scored 1 to 5 with NTILE (5 = best). Many customers share the same frequency,
--      so NTILE splits ties arbitrarily; read the segments, not single scores.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q10B. Revenue concentration (Pareto): customers ranked by spend and split into ten equal groups
--       cumulative_pct_of_gmv at decile 2 is the share of GMV from the top 20% of customers
-- ---------------------------------------------------------------------
WITH c AS (
    SELECT customer_key, SUM(gmv) AS spend
    FROM dw.fact_orders
    WHERE is_delivered = 1
      AND customer_key <> -1
    GROUP BY customer_key
),
d AS (
    SELECT spend, NTILE(10) OVER (ORDER BY spend DESC) AS spend_decile
    FROM c
)
SELECT spend_decile,
       COUNT(*)                                                                                  AS customers,
       SUM(spend)                                                                                AS gmv,
       CAST(100.0 * SUM(spend) / SUM(SUM(spend)) OVER () AS DECIMAL(5,2))                        AS pct_of_gmv,
       CAST(100.0 * SUM(SUM(spend)) OVER (ORDER BY spend_decile) / SUM(SUM(spend)) OVER () AS DECIMAL(5,2)) AS cumulative_pct_of_gmv
FROM d
GROUP BY spend_decile
ORDER BY spend_decile;
GO
-- Insight: The top 20% of customers give 71% of GMV and the top 10% alone give 52.6%, so revenue is more concentrated than
--          the 80/20 rule.
 
-- ---------------------------------------------------------------------
-- Q10C. The 15 most valuable customers by GMV, with their channel, last order and the two data-quality flags
-- ---------------------------------------------------------------------
SELECT TOP 15
       c.customer_id,
       c.signup_channel,
       c.city,
       x.delivered_orders,
       x.gmv,
       x.contribution,
       x.last_order_date,
       c.is_shared_phone,
       c.is_signup_after_first_order
FROM (SELECT customer_key,
             COUNT(*)                          AS delivered_orders,
             SUM(gmv)                          AS gmv,
             SUM(contribution)                 AS contribution,
             CAST(MAX(order_datetime) AS DATE) AS last_order_date
      FROM dw.fact_orders
      WHERE is_delivered = 1
        AND customer_key <> -1
      GROUP BY customer_key) AS x
JOIN dw.dim_customer AS c ON c.customer_key = x.customer_key
ORDER BY x.gmv DESC;
GO
-- Insight: The top 15 customers bring 1.67M GMV (5.7% of the total), two have negative contribution and a shared-phone flag
--          (check for promo abuse), and three have not ordered since August to November 2025 (win-back targets).