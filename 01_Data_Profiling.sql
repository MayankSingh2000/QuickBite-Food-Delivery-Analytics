USE QuickBite;

/* =====================================================================
   QuickBite Food Delivery Analytics
   01_Data_Profiling.sql

   Profiles the 8 raw staging tables. Reads the stg tables only; nothing in
   this script changes data. Findings are recorded in data_quality_log.xlsx
   and fixed in 02_Data_Cleaning.sql. Each check is tagged with the
   stakeholder question it affects, for example [Q9].

   Steps
   1.  stg.orders            checks 1 to 13: duplicates, status and payment values, date formats,
                             subtotal validity, promo and city values, orphan customers and
                             restaurants, total amount arithmetic
   2.  stg.customers         C1 to C9: uniqueness, gender, channel, age, email, city, phone layouts,
                             shared phone numbers, signup date formats
   3.  stg.restaurants       R1 to R6: IDs and names, duplicate restaurants, cuisine, commission,
                             city, onboarded date formats
   4.  stg.delivery_partners P1 to P5: IDs and names, vehicle type, employment type, city, joined date
   5.  stg.order_items       I1 to I6: uniqueness, category, item names, quantity, unit price,
                             orphan items
   6.  stg.deliveries        D1 to D7: uniqueness, missing values and timestamp format, delivered
                             before pickup, distance, promised minutes and payout, orphans,
                             pickups before the partner joined
   7.  stg.reviews           RV1 to RV6: uniqueness, rating, review text, review date format, orphans,
                             reviews dated before the delivery
   8.  stg.promotions        PR1 to PR2: the full table, promo codes used but not defined
   ===================================================================== */

/* =====================================================================
   1. stg.orders (checks 1 to 13)
   ===================================================================== */

-- 1. Duplicate check: total rows vs distinct order IDs

SELECT 
	   COUNT(*)                 AS total_rows,
       COUNT(DISTINCT order_id) AS distinct_orders
FROM stg.orders;

-- 2. Consistency check: order_status values

SELECT order_status, 
COUNT(*) AS orders
FROM stg.orders
GROUP BY order_status
ORDER BY order_status;

-- 3. Consistency check: payment_method values

SELECT payment_method, 
COUNT(*) AS orders
FROM stg.orders
GROUP BY payment_method
ORDER BY payment_method;

-- 4. Format check: how many different date formats exist in order_datetime

SELECT CASE
         WHEN order_datetime LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] %' THEN 'yyyy-mm-dd hh:mi:ss'
         WHEN order_datetime LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9] %' THEN 'dd/mm/yyyy hh:mi'
         WHEN order_datetime LIKE '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9] %' THEN 'dd-Mon-yyyy hh:mi'
         ELSE 'other'
       END AS date_format,
       COUNT(*) AS orders
FROM stg.orders
GROUP BY CASE
         WHEN order_datetime LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] %' THEN 'yyyy-mm-dd hh:mi:ss'
         WHEN order_datetime LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9] %' THEN 'dd/mm/yyyy hh:mi'
         WHEN order_datetime LIKE '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9] %' THEN 'dd-Mon-yyyy hh:mi'
         ELSE 'other'
       END;

-- 5. Validity check: subtotal that is not a number, negative, or zero

SELECT
  SUM(CASE WHEN TRY_CAST(subtotal AS DECIMAL(12,2)) IS NULL THEN 1 ELSE 0 END) AS not_a_number,
  SUM(CASE WHEN TRY_CAST(subtotal AS DECIMAL(12,2)) < 0     THEN 1 ELSE 0 END) AS negative,
  SUM(CASE WHEN TRY_CAST(subtotal AS DECIMAL(12,2)) = 0     THEN 1 ELSE 0 END) AS zero
FROM stg.orders;

-- 6. Hidden variants: order_status exactly as stored (case and trailing spaces visible)

SELECT
    SUM(CASE WHEN order_status LIKE ' %' THEN 1 ELSE 0 END)                                              AS leading_space,
    SUM(CASE WHEN order_status LIKE '% ' THEN 1 ELSE 0 END)                                              AS trailing_space,
    SUM(CASE WHEN order_status COLLATE Latin1_General_CS_AS = LOWER(order_status) THEN 1 ELSE 0 END)     AS all_lowercase,
    SUM(CASE WHEN order_status COLLATE Latin1_General_CS_AS = UPPER(order_status) THEN 1 ELSE 0 END)     AS all_uppercase,
    SUM(CASE WHEN order_status LIKE 'Canceled%' THEN 1 ELSE 0 END)                                      AS us_spelling_canceled,
    COUNT(*)                                                                                             AS total_rows
FROM stg.orders;

-- 6.1. Rows needing a status fix: not exactly one of the 5 valid values, or has hidden spaces

SELECT COUNT(*) AS rows_needing_fix
FROM stg.orders
WHERE order_status COLLATE Latin1_General_BIN2 NOT IN
          ('Delivered', 'Refunded', 'Cancelled by Customer',
           'Cancelled by Restaurant', 'Cancelled - No Partner')
   OR DATALENGTH(order_status) <> DATALENGTH(TRIM(order_status));

-- 7. Inspect duplicates: every row for order IDs that appear more than once

SELECT TOP 20 o.*
FROM stg.orders o
WHERE o.order_id IN (SELECT order_id
                     FROM stg.orders
                     GROUP BY order_id
                     HAVING COUNT(*) > 1)
ORDER BY o.order_id;

-- 7.1. Count extra exact copies using ROW_NUMBER over every column (compare with 732)

WITH numbered AS (
    SELECT ROW_NUMBER() OVER (
               PARTITION BY order_id, customer_id, restaurant_id, order_datetime, order_status,
                            payment_method, promo_code, subtotal, discount_amount, delivery_fee,
                            total_amount, delivery_city, order_platform
               ORDER BY (SELECT NULL)) AS copy_number
    FROM stg.orders
)
SELECT COUNT(*) AS extra_exact_copies
FROM numbered
WHERE copy_number > 1;

-- 9. Consistency check: promo_code values exactly as stored (case visible)

SELECT promo_code COLLATE Latin1_General_BIN2 AS exact_promo_code,
       COUNT(*)                                AS orders
FROM stg.orders
GROUP BY promo_code COLLATE Latin1_General_BIN2
ORDER BY orders DESC;

-- 10. Consistency check: delivery_city values exactly as stored (case visible)

SELECT delivery_city COLLATE Latin1_General_BIN2 AS exact_city,
       DATALENGTH(delivery_city)                 AS stored_bytes,
       COUNT(*)                                  AS orders
FROM stg.orders
GROUP BY delivery_city COLLATE Latin1_General_BIN2, DATALENGTH(delivery_city)
ORDER BY exact_city;

-- 11. Integrity check: orders whose customer_id has no match in the customers table

SELECT COUNT(*) AS orphan_orders
FROM stg.orders AS o
LEFT JOIN stg.customers AS c
       ON o.customer_id = c.customer_id
WHERE c.customer_id IS NULL;

-- 12. Integrity check: orders whose restaurant_id has no match in the restaurants table

SELECT COUNT(*) AS orphan_restaurant_orders
FROM stg.orders AS o
LEFT JOIN stg.restaurants AS r
       ON o.restaurant_id = r.restaurant_id
WHERE r.restaurant_id IS NULL;

-- 13. Arithmetic check: rows where total_amount does not equal subtotal - discount + delivery_fee

SELECT COUNT(*) AS rows_checked,
       SUM(CASE WHEN ABS(  TRY_CAST(total_amount    AS DECIMAL(12,2))
                         - (TRY_CAST(subtotal        AS DECIMAL(12,2))
                          - TRY_CAST(discount_amount AS DECIMAL(12,2))
                          + TRY_CAST(delivery_fee    AS DECIMAL(12,2)))) > 0.01
                THEN 1 ELSE 0 END) AS total_mismatch
FROM stg.orders
WHERE TRY_CAST(subtotal AS DECIMAL(12,2)) IS NOT NULL;

/* =====================================================================
   2. stg.customers (checks C1 to C9)
   ===================================================================== */
 USE QuickBite
-- C1. Uniqueness check: total rows vs distinct customer_id in customers  [Q9, Q10]

SELECT COUNT(*)                    AS total_rows,
       COUNT(DISTINCT customer_id) AS distinct_customers
FROM stg.customers;

-- C2. Consistency check: gender values exactly as stored (case visible; NULL shows as NULL)  [Q10]

SELECT gender COLLATE Latin1_General_BIN2 AS exact_gender,
       COUNT(*)                           AS customers
FROM stg.customers
GROUP BY gender COLLATE Latin1_General_BIN2
ORDER BY customers DESC;

-- C3. Consistency check: signup_channel values exactly as stored (case visible)  [Q9]

SELECT signup_channel COLLATE Latin1_General_BIN2 AS exact_channel,
       COUNT(*)                                    AS customers
FROM stg.customers
GROUP BY signup_channel COLLATE Latin1_General_BIN2
ORDER BY exact_channel;

-- C4. Validity check: age that is missing, not a number, or outside the valid range 18-65  [Q10]

SELECT
  SUM(CASE WHEN age IS NULL OR TRIM(age) = ''                                          THEN 1 ELSE 0 END) AS missing_age,
  SUM(CASE WHEN age IS NOT NULL AND TRIM(age) <> ''
            AND TRY_CAST(age AS INT) IS NULL                                           THEN 1 ELSE 0 END) AS not_a_number,
  SUM(CASE WHEN TRY_CAST(age AS INT) < 18                                              THEN 1 ELSE 0 END) AS under_18,
  SUM(CASE WHEN TRY_CAST(age AS INT) > 65                                              THEN 1 ELSE 0 END) AS over_65,
  COUNT(*)                                                                                                AS total_rows
FROM stg.customers;

-- C5. Completeness and validity check: email missing or without an @ sign  [customer contact]

SELECT
  SUM(CASE WHEN email IS NULL OR TRIM(email) = ''                                  THEN 1 ELSE 0 END) AS missing_email,
  SUM(CASE WHEN email IS NOT NULL AND TRIM(email) <> '' AND email NOT LIKE '%@%'  THEN 1 ELSE 0 END) AS email_without_at,
  COUNT(*)                                                                                           AS total_rows
FROM stg.customers;

-- C6. Consistency check: city values exactly as stored (case visible, with stored size)  [Q1, Q3, Q5]

SELECT city COLLATE Latin1_General_BIN2 AS exact_city,
       DATALENGTH(city)                 AS stored_bytes,
       COUNT(*)                         AS customers
FROM stg.customers
GROUP BY city COLLATE Latin1_General_BIN2, DATALENGTH(city)
ORDER BY exact_city;

-- C7. Format check: how many different phone layouts exist in customers.phone

WITH p AS (
    SELECT CASE
             WHEN phone IS NULL OR TRIM(phone) = ''                                          THEN 'missing'
             WHEN phone LIKE '[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'            THEN '10 digits'
             WHEN phone LIKE '+91 [0-9][0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9][0-9]'       THEN '+91 xxxxx xxxxx'
             WHEN phone LIKE '+91[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'         THEN '+91xxxxxxxxxx'
             WHEN phone LIKE '[0-9][0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9][0-9]'           THEN 'xxxxx xxxxx'
             WHEN phone LIKE '0[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'           THEN '0 + 10 digits'
             ELSE 'other'
           END AS phone_format
    FROM stg.customers
)
SELECT phone_format, COUNT(*) AS customers
FROM p
GROUP BY phone_format
ORDER BY customers DESC;

-- C8. Uniqueness check: phone numbers (last 10 digits) used by more than one customer account

WITH norm AS (
    SELECT customer_id,
           RIGHT(REPLACE(REPLACE(phone, ' ', ''), '+', ''), 10) AS phone10
    FROM stg.customers
    WHERE phone IS NOT NULL AND TRIM(phone) <> ''
)
SELECT COUNT(*)      AS shared_phone_numbers,
       SUM(accounts) AS accounts_involved
FROM (SELECT phone10, COUNT(*) AS accounts
      FROM norm
      GROUP BY phone10
      HAVING COUNT(*) > 1) AS s;

-- C8.1 Compare accounts with a shared phone vs a unique phone: orders and MEGA50 promo usage

WITH norm AS (
    SELECT customer_id,
           RIGHT(REPLACE(REPLACE(phone, ' ', ''), '+', ''), 10) AS phone10
    FROM stg.customers
    WHERE phone IS NOT NULL AND TRIM(phone) <> ''
),
flagged AS (
    SELECT customer_id,
           CASE WHEN COUNT(*) OVER (PARTITION BY phone10) > 1
                THEN 'shared phone' ELSE 'unique phone' END AS phone_group
    FROM norm
)
SELECT f.phone_group,
       COUNT(DISTINCT f.customer_id)                                           AS accounts,
       COUNT(DISTINCT o.order_id)                                              AS orders,
       COUNT(DISTINCT CASE WHEN o.promo_code = 'MEGA50' THEN o.order_id END)   AS mega50_orders
FROM flagged AS f
LEFT JOIN stg.orders AS o
       ON o.customer_id = f.customer_id
GROUP BY f.phone_group;

-- C9. Format check: date layouts used in customers.signup_date

WITH d AS (
    SELECT CASE
             WHEN signup_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'                 THEN 'yyyy-mm-dd'
             WHEN signup_date LIKE '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9]'   THEN 'dd-Mon-yyyy'
             ELSE 'other'
           END AS date_format
    FROM stg.customers
)
SELECT date_format, COUNT(*) AS customers
FROM d
GROUP BY date_format
ORDER BY customers DESC;

/* =====================================================================
   3. stg.restaurants (checks R1 to R6)
   ===================================================================== */

-- R1. Uniqueness and whitespace check: restaurant IDs and names with hidden spaces  [Q6]

SELECT COUNT(*)                                                                                          AS total_rows,
       COUNT(DISTINCT restaurant_id)                                                                     AS distinct_ids,
       SUM(CASE WHEN DATALENGTH(restaurant_name) <> DATALENGTH(TRIM(restaurant_name)) THEN 1 ELSE 0 END) AS names_with_spaces
FROM stg.restaurants;

-- R2. Possible duplicate restaurants: same name, city and area (after cleanup) under different IDs  [Q6]

SELECT UPPER(TRIM(restaurant_name))    AS name_clean,
       UPPER(TRIM(city))               AS city_clean,
       UPPER(TRIM(area))               AS area_clean,
       COUNT(*)                        AS ids,
       STRING_AGG(restaurant_id, ', ') AS restaurant_ids
FROM stg.restaurants
GROUP BY UPPER(TRIM(restaurant_name)), UPPER(TRIM(city)), UPPER(TRIM(area))
HAVING COUNT(*) > 1
ORDER BY ids DESC, name_clean;

-- R2.1 Compare the suspected duplicate restaurants side by side: attributes and number of orders per ID  [Q6]

WITH grp AS (
    SELECT UPPER(TRIM(restaurant_name)) AS name_clean,
           UPPER(TRIM(city))            AS city_clean,
           UPPER(TRIM(area))            AS area_clean
    FROM stg.restaurants
    GROUP BY UPPER(TRIM(restaurant_name)), UPPER(TRIM(city)), UPPER(TRIM(area))
    HAVING COUNT(*) > 1
)
SELECT g.name_clean, r.restaurant_id, r.cuisine, r.tier, r.commission_pct, r.onboarded_date,
       COUNT(DISTINCT o.order_id) AS orders
FROM grp AS g
JOIN stg.restaurants AS r
  ON UPPER(TRIM(r.restaurant_name)) = g.name_clean
 AND UPPER(TRIM(r.city))            = g.city_clean
 AND UPPER(TRIM(r.area))            = g.area_clean
LEFT JOIN stg.orders AS o
       ON o.restaurant_id = r.restaurant_id
GROUP BY g.name_clean, r.restaurant_id, r.cuisine, r.tier, r.commission_pct, r.onboarded_date
ORDER BY g.name_clean, r.restaurant_id;

-- R3. Consistency check: cuisine values exactly as stored (case visible)  [Q6]

SELECT cuisine COLLATE Latin1_General_BIN2 AS exact_cuisine,
       COUNT(*)                            AS restaurants
FROM stg.restaurants
GROUP BY cuisine COLLATE Latin1_General_BIN2
ORDER BY exact_cuisine;

-- R4. Validity check: commission_pct missing, stored as a fraction (below 1), or valid percentage  [Q2]

SELECT
  SUM(CASE WHEN commission_pct IS NULL OR TRIM(commission_pct) = ''              THEN 1 ELSE 0 END) AS missing,
  SUM(CASE WHEN TRY_CAST(commission_pct AS DECIMAL(6,3)) < 1                     THEN 1 ELSE 0 END) AS stored_as_fraction,
  SUM(CASE WHEN TRY_CAST(commission_pct AS DECIMAL(6,3)) BETWEEN 1 AND 100       THEN 1 ELSE 0 END) AS valid_percentage,
  MIN(TRY_CAST(commission_pct AS DECIMAL(6,3)))                                  AS lowest_value,
  MAX(TRY_CAST(commission_pct AS DECIMAL(6,3)))                                  AS highest_value,
  COUNT(*)                                                                       AS total_rows
FROM stg.restaurants;

-- R5. Consistency check: city values exactly as stored (case visible, with stored size)  [Q1, Q3, Q5]

SELECT city COLLATE Latin1_General_BIN2 AS exact_city,
       DATALENGTH(city)                 AS stored_bytes,
       COUNT(*)                         AS restaurants
FROM stg.restaurants
GROUP BY city COLLATE Latin1_General_BIN2, DATALENGTH(city)
ORDER BY exact_city;

-- R6. Format check: date layouts used in restaurants.onboarded_date

WITH d AS (
    SELECT CASE
             WHEN onboarded_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN 'yyyy-mm-dd'
             WHEN onboarded_date LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]' THEN 'dd/mm/yyyy'
             ELSE 'other'
           END AS date_format
    FROM stg.restaurants
)
SELECT date_format, COUNT(*) AS restaurants
FROM d
GROUP BY date_format
ORDER BY restaurants DESC;

/* =====================================================================
   4. stg.delivery_partners (checks P1 to P5)
   ===================================================================== */

-- P1. Uniqueness and whitespace check: partner IDs and names with hidden spaces  [Q4, Q5]

SELECT COUNT(*)                                                                                       AS total_rows,
       COUNT(DISTINCT partner_id)                                                                     AS distinct_ids,
       SUM(CASE WHEN DATALENGTH(partner_name) <> DATALENGTH(TRIM(partner_name)) THEN 1 ELSE 0 END)    AS names_with_spaces
FROM stg.delivery_partners;

-- P2. Consistency check: vehicle_type values exactly as stored (case visible)  [Q4]

SELECT vehicle_type COLLATE Latin1_General_BIN2 AS exact_vehicle_type,
       COUNT(*)                                  AS partners
FROM stg.delivery_partners
GROUP BY vehicle_type COLLATE Latin1_General_BIN2
ORDER BY exact_vehicle_type;

-- P3. Consistency check: employment_type values exactly as stored (case visible)  [Q4]

SELECT employment_type COLLATE Latin1_General_BIN2 AS exact_employment_type,
       COUNT(*)                                     AS partners
FROM stg.delivery_partners
GROUP BY employment_type COLLATE Latin1_General_BIN2
ORDER BY exact_employment_type;

-- P4. Consistency check: city values exactly as stored (case visible, with stored size)  [Q1, Q3, Q5]

SELECT city COLLATE Latin1_General_BIN2 AS exact_city,
       DATALENGTH(city)                 AS stored_bytes,
       COUNT(*)                         AS partners
FROM stg.delivery_partners
GROUP BY city COLLATE Latin1_General_BIN2, DATALENGTH(city)
ORDER BY exact_city;

-- P5. Format and range check: joined_date layouts, unreadable dates, earliest and latest date  [Q4]

SELECT SUM(CASE WHEN joined_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN 1 ELSE 0 END)                     AS iso_format,
       SUM(CASE WHEN joined_date IS NULL OR joined_date NOT LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN 1 ELSE 0 END) AS other_or_missing,
       MIN(TRY_CAST(joined_date AS DATE))                                                                                 AS earliest,
       MAX(TRY_CAST(joined_date AS DATE))                                                                                 AS latest,
       COUNT(*)                                                                                                           AS total_rows
FROM stg.delivery_partners;

/* =====================================================================
   5. stg.order_items (checks I1 to I6)
   ===================================================================== */

-- I1. Uniqueness check: total rows vs distinct order_item_id in order_items  [Q2]

SELECT COUNT(*)                        AS total_rows,
       COUNT(DISTINCT order_item_id)   AS distinct_item_ids
FROM stg.order_items;

-- I2. Consistency check: item_category values exactly as stored (case visible)  [general quality]

SELECT item_category COLLATE Latin1_General_BIN2 AS exact_category,
       COUNT(*)                                   AS items
FROM stg.order_items
GROUP BY item_category COLLATE Latin1_General_BIN2
ORDER BY exact_category;

-- I3. Consistency check: item_name spacing, capitals and number of distinct dishes  [general quality]

SELECT COUNT(DISTINCT item_name COLLATE Latin1_General_BIN2)                                          AS distinct_raw_names,
       COUNT(DISTINCT UPPER(TRIM(item_name)))                                                         AS distinct_clean_names,
       SUM(CASE WHEN DATALENGTH(item_name) <> DATALENGTH(TRIM(item_name)) THEN 1 ELSE 0 END)          AS names_with_spaces,
       SUM(CASE WHEN item_name COLLATE Latin1_General_CS_AS = UPPER(item_name) THEN 1 ELSE 0 END)     AS all_uppercase_names
FROM stg.order_items;

-- I4. Validity check: quantity missing, not a number, zero or negative  [Q2]

SELECT SUM(CASE WHEN TRY_CAST(quantity AS INT) IS NULL THEN 1 ELSE 0 END)   AS missing_or_not_a_number,
       SUM(CASE WHEN TRY_CAST(quantity AS INT) <= 0   THEN 1 ELSE 0 END)    AS zero_or_negative,
       MIN(TRY_CAST(quantity AS INT))                                       AS lowest,
       MAX(TRY_CAST(quantity AS INT))                                       AS highest,
       COUNT(*)                                                             AS total_rows
FROM stg.order_items;

-- I5. Validity check: unit_price missing, not a number, zero or negative  [Q2]

SELECT SUM(CASE WHEN TRY_CAST(unit_price AS DECIMAL(10,2)) IS NULL THEN 1 ELSE 0 END)   AS missing_or_not_a_number,
       SUM(CASE WHEN TRY_CAST(unit_price AS DECIMAL(10,2)) <= 0   THEN 1 ELSE 0 END)    AS zero_or_negative,
       MIN(TRY_CAST(unit_price AS DECIMAL(10,2)))                                       AS lowest,
       MAX(TRY_CAST(unit_price AS DECIMAL(10,2)))                                       AS highest,
       COUNT(*)                                                                         AS total_rows
FROM stg.order_items;

-- I6. Integrity check: order items whose order_id has no match in the orders table  [Q2]

SELECT COUNT(*)                   AS orphan_items,
       COUNT(DISTINCT i.order_id) AS distinct_orphan_order_ids
FROM stg.order_items AS i
WHERE NOT EXISTS (SELECT 1
                  FROM stg.orders AS o
                  WHERE o.order_id = i.order_id);

/* =====================================================================
   6. stg.deliveries (checks D1 to D7)
   ===================================================================== */

-- D1. Uniqueness check: one delivery row per delivery_id and per order_id  [Q4]

SELECT COUNT(*)                     AS total_rows,
       COUNT(DISTINCT delivery_id)  AS distinct_delivery_ids,
       COUNT(DISTINCT order_id)     AS distinct_order_ids
FROM stg.deliveries;

-- D2. Completeness and format check: missing values and timestamps not in yyyy-mm-dd hh:mi:ss  [Q4]

SELECT SUM(CASE WHEN pickup_time    IS NULL OR TRIM(pickup_time)    = '' THEN 1 ELSE 0 END) AS missing_pickup,
       SUM(CASE WHEN delivered_time IS NULL OR TRIM(delivered_time) = '' THEN 1 ELSE 0 END) AS missing_delivered,
       SUM(CASE WHEN partner_id     IS NULL OR TRIM(partner_id)     = '' THEN 1 ELSE 0 END) AS missing_partner,
       SUM(CASE WHEN pickup_time    NOT LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' THEN 1 ELSE 0 END) AS pickup_not_iso,
       SUM(CASE WHEN delivered_time NOT LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' THEN 1 ELSE 0 END) AS delivered_not_iso,
       COUNT(*)                                                                                  AS total_rows
FROM stg.deliveries;

-- D3. Logic check: food delivered before it was picked up  [Q4]

SELECT SUM(CASE WHEN TRY_CAST(delivered_time AS DATETIME2) <  TRY_CAST(pickup_time AS DATETIME2) THEN 1 ELSE 0 END) AS delivered_before_pickup,
       SUM(CASE WHEN TRY_CAST(delivered_time AS DATETIME2) =  TRY_CAST(pickup_time AS DATETIME2) THEN 1 ELSE 0 END) AS same_time,
       COUNT(*)                                                                                                     AS rows_checked
FROM stg.deliveries
WHERE TRY_CAST(delivered_time AS DATETIME2) IS NOT NULL
  AND TRY_CAST(pickup_time    AS DATETIME2) IS NOT NULL;

-- D4. Validity check: distance_km missing, zero or negative, or unrealistically large (over 20 km)  [Q4]

SELECT SUM(CASE WHEN TRY_CAST(distance_km AS DECIMAL(8,2)) IS NULL THEN 1 ELSE 0 END)   AS missing_or_not_a_number,
       SUM(CASE WHEN TRY_CAST(distance_km AS DECIMAL(8,2)) <= 0   THEN 1 ELSE 0 END)    AS zero_or_negative,
       SUM(CASE WHEN TRY_CAST(distance_km AS DECIMAL(8,2)) > 20   THEN 1 ELSE 0 END)    AS over_20_km,
       MIN(TRY_CAST(distance_km AS DECIMAL(8,2)))                                       AS lowest,
       MAX(TRY_CAST(distance_km AS DECIMAL(8,2)))                                       AS highest,
       COUNT(*)                                                                         AS total_rows
FROM stg.deliveries;

-- D5. Validity check: promised_minutes and partner_payout missing, zero or negative, and their ranges  [Q2, Q4]

SELECT SUM(CASE WHEN TRY_CAST(promised_minutes AS INT) <= 0 THEN 1 ELSE 0 END)                         AS promised_zero_or_negative,
       MIN(TRY_CAST(promised_minutes AS INT))                                                          AS promised_lowest,
       MAX(TRY_CAST(promised_minutes AS INT))                                                          AS promised_highest,
       SUM(CASE WHEN partner_payout IS NULL OR TRIM(partner_payout) = '' THEN 1 ELSE 0 END)           AS payout_missing,
       SUM(CASE WHEN TRY_CAST(partner_payout AS DECIMAL(10,2)) <= 0 THEN 1 ELSE 0 END)                AS payout_zero_or_negative,
       MIN(TRY_CAST(partner_payout AS DECIMAL(10,2)))                                                  AS payout_lowest,
       MAX(TRY_CAST(partner_payout AS DECIMAL(10,2)))                                                  AS payout_highest,
       COUNT(*)                                                                                        AS total_rows
FROM stg.deliveries;

-- D6. Integrity check: deliveries whose order_id or partner_id has no match in its parent table  [Q4, Q5]

SELECT SUM(CASE WHEN o.order_id   IS NULL THEN 1 ELSE 0 END) AS orders_missing,
       SUM(CASE WHEN p.partner_id IS NULL THEN 1 ELSE 0 END) AS partners_missing,
       COUNT(*)                                              AS total_rows
FROM stg.deliveries AS d
LEFT JOIN (SELECT DISTINCT order_id FROM stg.orders) AS o
       ON o.order_id = d.order_id
LEFT JOIN stg.delivery_partners AS p
       ON p.partner_id = d.partner_id;

-- D7. Logic check: pickups that happened before the partner's joined_date  [Q4]

SELECT COUNT(*)                    AS pickups_before_partner_joined,
       COUNT(DISTINCT d.partner_id) AS partners_involved
FROM stg.deliveries AS d
JOIN stg.delivery_partners AS p
  ON p.partner_id = d.partner_id
WHERE TRY_CAST(d.pickup_time AS DATE) < TRY_CAST(p.joined_date AS DATE);

/* =====================================================================
   7. stg.reviews (checks RV1 to RV6)
   ===================================================================== */

-- RV1. Uniqueness check: total rows vs distinct review_id and distinct order_id in reviews  [Q7]

SELECT COUNT(*)                    AS total_rows,
       COUNT(DISTINCT review_id)   AS distinct_review_ids,
       COUNT(DISTINCT order_id)    AS distinct_order_ids
FROM stg.reviews;

-- RV2. Validity check: rating not a number, outside 1-5, and its range  [Q7]

SELECT SUM(CASE WHEN TRY_CAST(rating AS INT) IS NULL THEN 1 ELSE 0 END)                     AS missing_or_not_a_number,
       SUM(CASE WHEN TRY_CAST(rating AS INT) < 1     THEN 1 ELSE 0 END)                     AS below_1,
       SUM(CASE WHEN TRY_CAST(rating AS INT) > 5     THEN 1 ELSE 0 END)                     AS above_5,
       MIN(TRY_CAST(rating AS INT))                                                         AS lowest,
       MAX(TRY_CAST(rating AS INT))                                                         AS highest,
       COUNT(*)                                                                             AS total_rows
FROM stg.reviews;

-- RV3. Completeness check: review_text missing or blank  [Q7]

SELECT SUM(CASE WHEN review_text IS NULL OR TRIM(review_text) = '' THEN 1 ELSE 0 END) AS missing_text,
       COUNT(*)                                                                       AS total_rows
FROM stg.reviews;

-- RV4. Format and range check: review_date layouts, earliest and latest date  [Q7]

SELECT SUM(CASE WHEN review_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN 1 ELSE 0 END)                       AS iso_format,
       SUM(CASE WHEN review_date IS NULL OR review_date NOT LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN 1 ELSE 0 END) AS other_or_missing,
       MIN(TRY_CAST(review_date AS DATE))                                                                                       AS earliest,
       MAX(TRY_CAST(review_date AS DATE))                                                                                       AS latest,
       COUNT(*)                                                                                                                 AS total_rows
FROM stg.reviews

-- RV5. Integrity check: reviews whose order_id has no match in the orders table  [Q7]

SELECT COUNT(*) AS orphan_reviews
FROM stg.reviews AS r
WHERE NOT EXISTS (SELECT 1
                  FROM stg.orders AS o
                  WHERE o.order_id = r.order_id);

-- RV6. Logic check: reviews dated before the delivery they review  [Q7]

SELECT COUNT(*)                     AS reviews_before_delivery,
       COUNT(DISTINCT r.review_id)  AS distinct_reviews
FROM stg.reviews AS r
JOIN stg.deliveries AS d
  ON d.order_id = r.order_id
WHERE TRY_CAST(r.review_date AS DATE) < TRY_CAST(d.delivered_time AS DATE);

/* =====================================================================
   8. stg.promotions (checks PR1 to PR2)
   ===================================================================== */

-- PR1. Spot check: the full promotions table (7 rows)  [Q8]

SELECT * FROM stg.promotions;

-- PR2. Integrity check: promo codes used in orders that are not defined in promotions (expect no rows)  [Q8]

WITH used AS (
    SELECT DISTINCT UPPER(TRIM(promo_code)) AS code
    FROM stg.orders
    WHERE promo_code IS NOT NULL
      AND UPPER(TRIM(promo_code)) NOT IN ('NONE', 'N/A', 'NO PROMO')
)
SELECT u.code AS code_not_in_promotions
FROM used AS u
LEFT JOIN stg.promotions AS p
       ON UPPER(TRIM(p.promo_code)) = u.code
WHERE p.promo_code IS NULL;