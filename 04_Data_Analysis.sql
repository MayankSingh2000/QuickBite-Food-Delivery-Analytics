/* =====================================================================
   QuickBite Food Delivery Analytics
   04_Data_Analysis_lean.sql

   Answers the 10 stakeholder questions with one headline query each
   (two for Q1 and Q8). Each query ends with a one-sentence insight.
   Reads the dw star schema only; nothing in this script changes data.
   Queries named in a comment but not included here (for example Q3F or
   Q8B) are in 04_Data_Analysis_supporting.sql.

   Steps
   Q1   Growth and performance: monthly trend (Q1A), GMV growth by city (Q1B)
   Q2   Contribution per order by city (Q2E)
   Q3   Cancellation rate by city and type (Q3B)
   Q4   Delivery promise breach rate by city (Q4B)
   Q5   Delivery partners against demand by city (Q5C)
   Q6   High-cancellation restaurants against all others (Q6B)
   Q7   Ratings and refunds by lateness (Q7A)
   Q8   Contribution per order by promo code (Q8A), repeat use and shared phones (Q8C)
   Q9   Retention by acquisition channel (Q9A)
   Q10  RFM customer segments (Q10A)
   ===================================================================== */
 
USE QuickBite;
GO
 
-- =====================================================================
-- Q1. Growth and performance
--     Definitions (from data_dictionary.md and 03_Data_Modelling.sql; every measure counts DELIVERED orders only):
--       GMV          = total_amount
--       Commission   = subtotal x commission_pct / 100
--       Net revenue  = commission + delivery fee - discount
--       Contribution = net revenue - partner payout
--       Orders       = all orders placed, whatever their status; "delivered orders" is stated whenever only those are counted
--     Known gaps (the measures are NULL there, so averages leave those orders out and the coverage is shown):
--       * 1,428 delivered orders have no commission (restaurant unknown, or one of the 7 restaurants without a commission)
--       * 470 delivered orders have no partner payout
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q1A. Monthly trend: orders, GMV and net revenue with the change against the previous month (LAG)
--      net_revenue_coverage_pct = share of delivered orders whose net revenue is known (the rest are in the known gaps listed above)
-- ---------------------------------------------------------------------
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
SELECT year_month,
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
FROM monthly
ORDER BY month_start;
GO
-- Insight: Orders grew from 1,006 in January 2025 to 4,441 in December 2025 but have been flat since that peak
--          (3,383 to 3,983 orders and 1.9M to 2.3M GMV a month in 2026), so growth has plateaued (year-on-year order
--          growth has slowed from +294% in January 2026 to +89% in June) and the business should grow through existing
--          customers and by fixing leaks (cancellations, late deliveries, promos) rather than rely on volume.

-- ---------------------------------------------------------------------
-- Q1B. Which cities drive growth? GMV of January to June 2025 against January to June 2026 for every city,
--      and each city's share of the total increase (the shares add up to 100)
-- ---------------------------------------------------------------------
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
FROM city_h1
ORDER BY gmv_increase DESC;
GO
-- Insight: Every city more than doubled its GMV in January to June 2026 against the same months of 2025, and Mumbai, Delhi
--          and Bengaluru drive 66% of the increase (23.2%, 22.1% and 20.6%), with Delhi growing fastest (+200%) and
--          Hyderabad slowest (+106%).

-- =====================================================================
-- Q2. Contribution per order and what pushes it up or down
--     Only delivered orders whose contribution is known are used (commission and payout both known),
--     so every average below is taken over the same orders.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q2E. Why do the cities differ? The parts of the contribution per order, typical distance and promo use, by city
--      (same orders as Q2D; avg_distance_km leaves out the 8 deliveries with an invalid distance)
--      Read it by comparing each city with the others, column by column: where is the gap in avg_contribution coming from?
-- ---------------------------------------------------------------------
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
GROUP BY f.delivery_city
ORDER BY avg_contribution;
GO
-- Insight: Partner payout (about 50) and distance (about 3.5 km) are the same in every city, so Delhi's low contribution
--          per order (52.93 vs 71.76 to 89.17 elsewhere) comes from its smallest baskets (550) and heaviest discounting
--          (average discount 19.56, 20% of orders with a promo); Delhi should cut discounts and push bigger baskets, since
--          baskets under 300 earn only 7.44 per order.
 
-- =====================================================================
-- Q3. Where and when are we losing orders?
--     Cancellation rate = cancelled orders / all orders (data dictionary). The three cancellation types are
--     Customer, Restaurant and No partner. Every query below uses ALL orders, whatever their status.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q3B. Cancellation rate by city, split by type (each rate is a share of ALL orders of that city)
-- ---------------------------------------------------------------------
SELECT delivery_city,
       COUNT(*)                                                                                   AS orders,
       SUM(CAST(is_cancelled AS INT))                                                             AS cancelled,
       CAST(100.0 * SUM(CAST(is_cancelled AS INT)) / COUNT(*) AS DECIMAL(5,2))                    AS cancellation_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'Customer'   THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS customer_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'Restaurant' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS restaurant_rate,
       CAST(100.0 * SUM(CASE WHEN cancellation_type = 'No partner' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS no_partner_rate
FROM dw.fact_orders
GROUP BY delivery_city
ORDER BY cancellation_rate DESC;
GO
-- Insight: 8.2% of orders (4,313) are cancelled; Delhi is highest at 11.3% because of restaurant cancellations (7.2% vs
--          1.3% to 4.3% in other cities) and Hyderabad loses the most orders for lack of a partner (3.5% vs under 0.9%), so
--          fix a few restaurants in Delhi and add partners in Hyderabad.
 
-- =====================================================================
-- Q4. How often do we miss the delivery promise (SLA) and what drives delays?
--     delay_minutes = delivery_minutes - promised_minutes, measured from the moment the order was placed (data dictionary).
--     is_sla_breach uses a tolerance of 1 minute (see step 8 in 03_Data_Modelling.sql).
--     Only deliveries with a known breach flag are used: 48,012 deliveries minus those without a delivery time (192)
--     or without a promised time.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q4B. Breach rate by city (severe_delay_pct = more than 15 minutes late)
-- ---------------------------------------------------------------------
SELECT f.delivery_city,
       COUNT(*)                                                                          AS deliveries,
       CAST(100.0 * SUM(CAST(d.is_sla_breach AS INT)) / COUNT(*) AS DECIMAL(5,2))        AS breach_pct,
       CAST(AVG(d.delay_minutes) AS DECIMAL(6,2))                                        AS avg_delay_minutes,
       CAST(100.0 * SUM(CASE WHEN d.delay_minutes > 15 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS severe_delay_pct
FROM dw.fact_deliveries AS d
JOIN dw.fact_orders     AS f ON f.order_id = d.order_id
WHERE d.is_sla_breach IS NOT NULL
GROUP BY f.delivery_city
ORDER BY breach_pct DESC;
GO
-- Insight: 67.81% of deliveries miss the promise by more than 1 minute, but the problem is concentrated in Hyderabad,
--          which is late 96% of the time (31% of its deliveries are more than 15 minutes late) vs 58% to 69% in the
--          other cities (5% to 8% more than 15 minutes late), and it has been like this in all 18 months, so
--          Hyderabad should be fixed first.
 
-- =====================================================================
-- Q5. Do we have too few delivery partners in some cities at peak times?
--     A time slot is one city, one day and one hour. Demand = orders placed in the slot. Supply = partners who made at least
--     one delivery in the slot (partners who were available but idle cannot be seen in this data, so supply is a lower bound).
--     "No partner" cancellations are the direct sign of a shortage.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q5C. Fleet size against demand by city: partners registered in the city, orders per partner, and the "no partner" rate
--      (the data covers 18 months, so orders_per_partner_per_month is orders / partners / 18)
-- ---------------------------------------------------------------------
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
LEFT JOIN supply AS s ON s.city = d.delivery_city
ORDER BY orders_per_partner DESC;
GO
-- Insight: Hyderabad has 39 partners for 6,640 orders (170 orders per partner vs 93 to 119 elsewhere) and the highest
--          no-partner rate (3.5% vs under 0.9%), so it needs more partners, especially at dinner and on Fridays and
--          Saturdays.
 
-- =====================================================================
-- Q6. Which restaurants are high-volume but hurt the customer experience?
--     High volume = the top fifth of restaurants by number of orders (NTILE). Customer experience is read from four numbers per restaurant:
--     average rating (reviews with a valid rating), late share (is_sla_breach), refund share (refunded orders / orders that reached
--     the customer) and restaurant-side cancellation share (of all its orders). Orders of the unknown restaurant are left out.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q6B. Do the 12 high-cancellation restaurants from Q3F and Q3G also hurt ratings and refunds?
--      Same grouping as Q3G (100+ orders and a restaurant cancellation rate of 10% or more) against all other restaurants.
-- ---------------------------------------------------------------------
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
JOIN del ON del.restaurant_group = ord.restaurant_group
ORDER BY ord.restaurants;
GO
-- Insight: The 12 restaurants that cancel 10% or more of their orders hold about 14% of orders but rate 2.97 vs 4.14 for
--          all others, with refunds of 4.74% vs 1.63%, so fixing these 12 (5 in Delhi, 4 in Mumbai, 2 in Bengaluru, 1 in
--          Hyderabad) is the quickest way to lift ratings; they are also late more often (91.9% vs 64.8%), so part of the
--          gap may be lateness.
 
-- =====================================================================
-- Q7. How much do late deliveries hurt ratings and refunds?
--     Lateness is measured against the promise (delay_minutes). Deliveries without a known delay are left out.
--     refund_pct = refunded orders / deliveries (a refunded order is a delivery that happened).
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q7A. Rating and refunds by how late the delivery was
-- ---------------------------------------------------------------------
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
GROUP BY b.lateness_band
ORDER BY b.lateness_band;
GO
-- Insight: Ratings fall from 4.41 on time to 3.13 when the delivery is more than 15 minutes late, and 1 to 2 star ratings
--          jump from under 1% (up to 5 minutes late) to 20.78%, so deliveries should stay within about 5 minutes of the
--          promise.
 
-- =====================================================================
-- Q8. Which promo codes make money, and is any promo being abused?
--     Contribution is the delivered orders with a known contribution (see the definitions under Q1). "NO PROMO" is the comparison group.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q8A. Contribution per order by promo code, against orders without a promo
-- ---------------------------------------------------------------------
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
GROUP BY p.promo_key, p.promo_code, p.promo_type, p.discount_value, p.max_discount, p.min_order_value, p.start_date, p.end_date
ORDER BY avg_contribution;
GO
-- Insight: MEGA50 (loses 137,160) and FIRST50 (loses 35,119) lose money on average and together wipe out most of the
--          200,741 that FREEDEL earns, so they should be capped or redesigned; the other promos are profitable.
 
-- ---------------------------------------------------------------------
-- Q8C. Repeat use and shared phones: how often do single customers use the same promo, and are shared-phone accounts overrepresented?
--      Delivered orders of known customers only. baseline_pct_shared_phone = share of ALL delivered orders placed by shared-phone
--      accounts; a promo far above that baseline deserves a closer look.
-- ---------------------------------------------------------------------
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
GROUP BY u.promo_code
ORDER BY max_uses_by_one_customer DESC;
GO
-- Insight: MEGA50 is being abused: 123 customers placed 1,734 orders (one customer used it 94 times) and 100% of its orders
--          came from shared-phone accounts vs a 9% baseline, and Q8B shows no rule was broken, so add a per-customer usage
--          limit.
 
-- =====================================================================
-- Q9. Which acquisition channel brings customers who stay? Was the Q4 2025 promo campaign worth it?
--     A customer "stays" when they place a further DELIVERED order. Cohorts and first orders use the first delivered order,
--     not signup_date (40 customers signed up after their first order, log #50). The channel comes from signup_channel.
--     The data ends on 30 June 2026, so retention windows are only measured for customers who had enough time to come back.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q9A. Retention by acquisition channel: customers whose first delivered order was before 1 April 2026
--      (so every one of them had at least 90 days to order again)
-- ---------------------------------------------------------------------
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
GROUP BY c.signup_channel
ORDER BY reorder_within_90_days_pct DESC;
GO
-- Insight: Referral customers stay best (79.5% place a second order, 1,064 contribution per customer) and Promo Campaign
--          customers worst (32.9%, 154), so acquisition spend should shift toward referral and away from promo campaigns.
 
-- =====================================================================
-- Q10. Who are the most valuable customers?
--      Delivered orders only. Recency = days from the last order to 30 June 2026 (the end of the data); frequency = number of
--      delivered orders; monetary = GMV. Each is scored 1 to 5 with NTILE (5 = best). Many customers share the same frequency,
--      so NTILE splits ties arbitrarily; read the segments, not single scores.
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- Q10A. RFM segments: size, behaviour and share of GMV
--       Champions = recent, frequent and high spend (4 or 5 on all three); Loyal = frequent and not lapsed;
--       New or recent = ordered lately but rarely; At risk = used to order but has gone quiet; Lost = quiet and rarely ordered
-- ---------------------------------------------------------------------
DECLARE @as_of DATE = '2026-06-30';
 
WITH c AS (
    SELECT customer_key,
           DATEDIFF(DAY, MAX(order_datetime), @as_of) AS recency_days,
           COUNT(*)                                   AS frequency,
           SUM(gmv)                                   AS monetary
    FROM dw.fact_orders
    WHERE is_delivered = 1
      AND customer_key <> -1
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
GO
-- Insight: Champions are 22% of customers but 59% of GMV, while the 'At risk' segment (1,039 customers, 5.2M GMV, silent
--          for about 345 days) is the best win-back target and 'Lost' customers (22% of customers, 2.5% of GMV) are not
--          worth chasing.