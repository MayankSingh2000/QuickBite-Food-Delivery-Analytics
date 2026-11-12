/* =====================================================================
   QuickBite Food Delivery Analytics
   02_Data_Cleaning.sql

   Cleans the raw stg tables into the clean schema. stg tables are never
   modified. Step numbers match the section numbers below.

   Steps
   1-4.  Mapping tables: create 9 lookup tables (city, order status, payment
         method, cuisine, item category, signup channel, gender, vehicle
         type, employment type), fill them with the standard value for every
         spelling found in profiling, check entry counts and unmapped values
   5.    clean.delivery_partners: standardise city, vehicle type and
         employment type, convert joined date
   6.    clean.restaurants: remove 4 duplicate restaurants, convert commission
         fractions to percentages, parse onboarded dates, flag missing commission
   7.    clean.promotions: convert data types
   8.    clean.customers: standardise gender, channel, city and names,
         validate age, email and phone, flag shared phone numbers,
         parse signup dates
   9.    Lookup of correct item names (63 dishes)
   10.   clean.order_items: remove 919 duplicate rows, validate quantity and
         price, repair 40 orphan order IDs; reconciliation tests RC1 to RC3
   11.   clean.orders: remove duplicate orders, standardise status, payment
         method, city and promo code, parse 3 date formats, correct subtotal
         and total, flag orphan customers and restaurants
   12.   clean.deliveries: set impossible values to NULL and flag them
   13.   clean.reviews: remove duplicate reviews, validate ratings and
         review dates
         Cross-table verification of all clean tables
   14.   Flag customers who signed up after their first order (log #50)
   15.   Flag orders placed before the restaurant's onboarded date (log #51)

   Each step ends with checks against expected values. Finding numbers
   refer to data_quality_log.xlsx.
   ===================================================================== */

USE QuickBite;
GO

-- ---------------------------------------------------------------------
-- 1. Create the mapping tables
--    A mapping table translates every spelling found in profiling into one standard value.
--    raw_key is the raw text in upper case with spaces trimmed, so case and space variants
--    collapse automatically and only the different spellings are listed.
--    Usage: JOIN clean.map_city AS m ON m.raw_key = UPPER(TRIM(t.city))  ->  m.standard_value
--    Findings addressed (data_quality_log.xlsx): #2 order_status | #3 payment_method |
--    #8, #17, #26, #30 city (4 tables) | #12 gender | #14 signup_channel | #23 cuisine |
--    #28 vehicle_type | #29 employment_type | #32 item_category
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS clean.map_city, clean.map_status, clean.map_payment, clean.map_cuisine,
                     clean.map_category, clean.map_channel, clean.map_gender,
                     clean.map_vehicle, clean.map_employment;

CREATE TABLE clean.map_city       (raw_key VARCHAR(100) NOT NULL PRIMARY KEY, standard_value VARCHAR(100) NOT NULL);
CREATE TABLE clean.map_status     (raw_key VARCHAR(100) NOT NULL PRIMARY KEY, standard_value VARCHAR(100) NOT NULL);
CREATE TABLE clean.map_payment    (raw_key VARCHAR(100) NOT NULL PRIMARY KEY, standard_value VARCHAR(100) NOT NULL);
CREATE TABLE clean.map_cuisine    (raw_key VARCHAR(100) NOT NULL PRIMARY KEY, standard_value VARCHAR(100) NOT NULL);
CREATE TABLE clean.map_category   (raw_key VARCHAR(100) NOT NULL PRIMARY KEY, standard_value VARCHAR(100) NOT NULL);
CREATE TABLE clean.map_channel    (raw_key VARCHAR(100) NOT NULL PRIMARY KEY, standard_value VARCHAR(100) NOT NULL);
CREATE TABLE clean.map_gender     (raw_key VARCHAR(100) NOT NULL PRIMARY KEY, standard_value VARCHAR(100) NOT NULL);
CREATE TABLE clean.map_vehicle    (raw_key VARCHAR(100) NOT NULL PRIMARY KEY, standard_value VARCHAR(100) NOT NULL);
CREATE TABLE clean.map_employment (raw_key VARCHAR(100) NOT NULL PRIMARY KEY, standard_value VARCHAR(100) NOT NULL);
GO

-- ---------------------------------------------------------------------
-- 2. Fill them (the keys are the UPPER(TRIM()) spellings found while profiling)
-- ---------------------------------------------------------------------

-- 2.1 Cities: used for orders.delivery_city, customers.city, restaurants.city, delivery_partners.city
INSERT INTO clean.map_city (raw_key, standard_value) VALUES
 ('BENGALURU', 'Bengaluru'), ('BANGALORE', 'Bengaluru'), ('BLR', 'Bengaluru'),
 ('MUMBAI',    'Mumbai'),    ('BOMBAY',    'Mumbai'),
 ('DELHI',     'Delhi'),     ('NEW DELHI', 'Delhi'),
 ('HYDERABAD', 'Hyderabad'), ('HYD',       'Hyderabad'),
 ('CHENNAI',   'Chennai'),   ('MADRAS',    'Chennai'),
 ('KOLKATA',   'Kolkata'),   ('CALCUTTA',  'Kolkata'),
 ('PUNE',      'Pune');

-- 2.2 Order status: 5 real statuses; US spelling "Canceled" mapped to "Cancelled"
INSERT INTO clean.map_status (raw_key, standard_value) VALUES
 ('DELIVERED',                'Delivered'),
 ('REFUNDED',                 'Refunded'),
 ('CANCELLED BY CUSTOMER',    'Cancelled by Customer'),   ('CANCELED BY CUSTOMER',    'Cancelled by Customer'),
 ('CANCELLED BY RESTAURANT',  'Cancelled by Restaurant'), ('CANCELED BY RESTAURANT',  'Cancelled by Restaurant'),
 ('CANCELLED - NO PARTNER',   'Cancelled - No Partner'),  ('CANCELED - NO PARTNER',   'Cancelled - No Partner');

-- 2.3 Payment method: 5 real methods
INSERT INTO clean.map_payment (raw_key, standard_value) VALUES
 ('UPI', 'UPI'),
 ('CREDIT CARD', 'Credit Card'), ('CREDITCARD', 'Credit Card'),
 ('DEBIT CARD',  'Debit Card'),  ('DEBITCARD',  'Debit Card'),
 ('COD', 'COD'), ('CASH ON DELIVERY', 'COD'), ('CASH', 'COD'),
 ('WALLET', 'Wallet'), ('E-WALLET', 'Wallet');

-- 2.4 Cuisine: 9 real cuisines (assumption: 'Chinese/Asian' is treated as Chinese)
INSERT INTO clean.map_cuisine (raw_key, standard_value) VALUES
 ('NORTH INDIAN', 'North Indian'), ('N. INDIAN', 'North Indian'),
 ('SOUTH INDIAN', 'South Indian'),
 ('CHINESE', 'Chinese'), ('CHINESE/ASIAN', 'Chinese'),
 ('BIRYANI', 'Biryani'), ('BIRIYANI', 'Biryani'),
 ('PIZZA & ITALIAN', 'Pizza & Italian'), ('PIZZA AND ITALIAN', 'Pizza & Italian'),
 ('BURGERS & FAST FOOD', 'Burgers & Fast Food'),
 ('DESSERTS & BAKERY', 'Desserts & Bakery'),
 ('HEALTHY & SALADS', 'Healthy & Salads'),
 ('STREET FOOD & ROLLS', 'Street Food & Rolls');

-- 2.5 Item category: 6 real categories
INSERT INTO clean.map_category (raw_key, standard_value) VALUES
 ('MAIN', 'Main'), ('MAIN COURSE', 'Main'),
 ('STARTER', 'Starter'), ('STARTERS', 'Starter'),
 ('BEVERAGE', 'Beverage'), ('DRINKS', 'Beverage'),
 ('DESSERT', 'Dessert'), ('SWEETS', 'Dessert'),
 ('SIDE', 'Side'), ('BREAD', 'Bread');

-- 2.6 Signup channel: 5 real channels (underscore variants included)
INSERT INTO clean.map_channel (raw_key, standard_value) VALUES
 ('ORGANIC', 'Organic'),
 ('PAID ADS', 'Paid Ads'), ('PAID_ADS', 'Paid Ads'),
 ('PROMO CAMPAIGN', 'Promo Campaign'), ('PROMO_CAMPAIGN', 'Promo Campaign'),
 ('REFERRAL', 'Referral'),
 ('INFLUENCER', 'Influencer');

-- 2.7 Gender: Male / Female / Other (missing values stay NULL here and become 'Unknown' in the clean table)
INSERT INTO clean.map_gender (raw_key, standard_value) VALUES
 ('MALE', 'Male'), ('M', 'Male'),
 ('FEMALE', 'Female'), ('F', 'Female'),
 ('OTHER', 'Other');

-- 2.8 Vehicle type (assumption: 'Motorcycle' is treated as Bike)
INSERT INTO clean.map_vehicle (raw_key, standard_value) VALUES
 ('BIKE', 'Bike'), ('MOTORCYCLE', 'Bike'),
 ('SCOOTER', 'Scooter'), ('SCOOTY', 'Scooter'),
 ('EV BIKE', 'EV Bike'), ('ELECTRIC BIKE', 'EV Bike'),
 ('BICYCLE', 'Bicycle');

-- 2.9 Employment type
INSERT INTO clean.map_employment (raw_key, standard_value) VALUES
 ('FULL-TIME', 'Full-time'), ('FULL TIME', 'Full-time'), ('FT', 'Full-time'),
 ('GIG', 'Gig'), ('GIG WORKER', 'Gig');
GO

-- ---------------------------------------------------------------------
-- 3. Check 1: how many rows are in each mapping table (expected: 14, 8, 10, 13, 10, 7, 5, 7, 5)
-- ---------------------------------------------------------------------
SELECT 'map_city' AS mapping_table, COUNT(*) AS entries FROM clean.map_city       UNION ALL
SELECT 'map_status',                COUNT(*)             FROM clean.map_status     UNION ALL
SELECT 'map_payment',               COUNT(*)             FROM clean.map_payment    UNION ALL
SELECT 'map_cuisine',               COUNT(*)             FROM clean.map_cuisine    UNION ALL
SELECT 'map_category',              COUNT(*)             FROM clean.map_category   UNION ALL
SELECT 'map_channel',               COUNT(*)             FROM clean.map_channel    UNION ALL
SELECT 'map_gender',                COUNT(*)             FROM clean.map_gender     UNION ALL
SELECT 'map_vehicle',               COUNT(*)             FROM clean.map_vehicle    UNION ALL
SELECT 'map_employment',            COUNT(*)             FROM clean.map_employment;
GO

-- ---------------------------------------------------------------------
-- 4. Check 2: unmapped values. Every row below must show 0. A number above 0 means a
--    spelling exists in the raw data that the mapping table does not cover yet.
-- ---------------------------------------------------------------------
SELECT 'orders.delivery_city' AS source_column, COUNT(*) AS unmapped_rows
FROM stg.orders AS t
LEFT JOIN clean.map_city AS m ON m.raw_key = UPPER(TRIM(t.delivery_city))
WHERE t.delivery_city IS NOT NULL AND TRIM(t.delivery_city) <> '' AND m.raw_key IS NULL
UNION ALL
SELECT 'customers.city', COUNT(*)
FROM stg.customers AS t
LEFT JOIN clean.map_city AS m ON m.raw_key = UPPER(TRIM(t.city))
WHERE t.city IS NOT NULL AND TRIM(t.city) <> '' AND m.raw_key IS NULL
UNION ALL
SELECT 'restaurants.city', COUNT(*)
FROM stg.restaurants AS t
LEFT JOIN clean.map_city AS m ON m.raw_key = UPPER(TRIM(t.city))
WHERE t.city IS NOT NULL AND TRIM(t.city) <> '' AND m.raw_key IS NULL
UNION ALL
SELECT 'delivery_partners.city', COUNT(*)
FROM stg.delivery_partners AS t
LEFT JOIN clean.map_city AS m ON m.raw_key = UPPER(TRIM(t.city))
WHERE t.city IS NOT NULL AND TRIM(t.city) <> '' AND m.raw_key IS NULL
UNION ALL
SELECT 'orders.order_status', COUNT(*)
FROM stg.orders AS t
LEFT JOIN clean.map_status AS m ON m.raw_key = UPPER(TRIM(t.order_status))
WHERE t.order_status IS NOT NULL AND TRIM(t.order_status) <> '' AND m.raw_key IS NULL
UNION ALL
SELECT 'orders.payment_method', COUNT(*)
FROM stg.orders AS t
LEFT JOIN clean.map_payment AS m ON m.raw_key = UPPER(TRIM(t.payment_method))
WHERE t.payment_method IS NOT NULL AND TRIM(t.payment_method) <> '' AND m.raw_key IS NULL
UNION ALL
SELECT 'restaurants.cuisine', COUNT(*)
FROM stg.restaurants AS t
LEFT JOIN clean.map_cuisine AS m ON m.raw_key = UPPER(TRIM(t.cuisine))
WHERE t.cuisine IS NOT NULL AND TRIM(t.cuisine) <> '' AND m.raw_key IS NULL
UNION ALL
SELECT 'order_items.item_category', COUNT(*)
FROM stg.order_items AS t
LEFT JOIN clean.map_category AS m ON m.raw_key = UPPER(TRIM(t.item_category))
WHERE t.item_category IS NOT NULL AND TRIM(t.item_category) <> '' AND m.raw_key IS NULL
UNION ALL
SELECT 'customers.signup_channel', COUNT(*)
FROM stg.customers AS t
LEFT JOIN clean.map_channel AS m ON m.raw_key = UPPER(TRIM(t.signup_channel))
WHERE t.signup_channel IS NOT NULL AND TRIM(t.signup_channel) <> '' AND m.raw_key IS NULL
UNION ALL
SELECT 'customers.gender', COUNT(*)
FROM stg.customers AS t
LEFT JOIN clean.map_gender AS m ON m.raw_key = UPPER(TRIM(t.gender))
WHERE t.gender IS NOT NULL AND TRIM(t.gender) <> '' AND m.raw_key IS NULL
UNION ALL
SELECT 'delivery_partners.vehicle_type', COUNT(*)
FROM stg.delivery_partners AS t
LEFT JOIN clean.map_vehicle AS m ON m.raw_key = UPPER(TRIM(t.vehicle_type))
WHERE t.vehicle_type IS NOT NULL AND TRIM(t.vehicle_type) <> '' AND m.raw_key IS NULL
UNION ALL
SELECT 'delivery_partners.employment_type', COUNT(*)
FROM stg.delivery_partners AS t
LEFT JOIN clean.map_employment AS m ON m.raw_key = UPPER(TRIM(t.employment_type))
WHERE t.employment_type IS NOT NULL AND TRIM(t.employment_type) <> '' AND m.raw_key IS NULL;
GO

/* =====================================================================
   PART 2: clean.delivery_partners, clean.restaurants, clean.promotions
   Findings addressed: #21 restaurant_name spaces | #22 duplicate restaurants | #23 cuisine
   #24 commission fractions | #25 commission missing | #26 city | #27 onboarded_date
   #28 vehicle_type | #29 employment_type | #30 city (partners)
   ===================================================================== */

USE QuickBite;
GO

-- ---------------------------------------------------------------------
-- 5. clean.delivery_partners
--    LEFT JOIN + NOT NULL columns on purpose: if a spelling were ever missing from a
--    mapping table the INSERT fails with an error instead of silently losing rows.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS clean.delivery_partners;
CREATE TABLE clean.delivery_partners (
    partner_id       VARCHAR(20)   NOT NULL PRIMARY KEY,
    partner_name     NVARCHAR(100) NOT NULL,
    city             VARCHAR(50)   NOT NULL,
    vehicle_type     VARCHAR(30)   NOT NULL,
    employment_type  VARCHAR(30)   NOT NULL,
    joined_date      DATE          NOT NULL
);

INSERT INTO clean.delivery_partners (partner_id, partner_name, city, vehicle_type, employment_type, joined_date)
SELECT TRIM(p.partner_id),
       TRIM(p.partner_name),
       c.standard_value,
       v.standard_value,
       e.standard_value,
       TRY_CAST(NULLIF(TRIM(p.joined_date), '') AS DATE)
FROM stg.delivery_partners AS p
LEFT JOIN clean.map_city       AS c ON c.raw_key = UPPER(TRIM(p.city))
LEFT JOIN clean.map_vehicle    AS v ON v.raw_key = UPPER(TRIM(p.vehicle_type))
LEFT JOIN clean.map_employment AS e ON e.raw_key = UPPER(TRIM(p.employment_type));
GO

-- ---------------------------------------------------------------------
-- 6. clean.restaurants
--    Decisions:
--      * R1400-R1403 are exact copies of R1084, R1298, R1287, R1318 with 0 orders (profiling check R2.1) -> removed
--      * commission_pct below 1 is a fraction (0.18 = 18%) -> multiplied by 100
--      * missing commission stays NULL and is flagged (commission_missing = 1); excluded from contribution averages later
--      * onboarded_date: yyyy-mm-dd (style 23) or dd/mm/yyyy (style 103); 18/08/2025 shows that the day comes first
--      * NULLIF(TRIM(x), '') protects against blank text, which would otherwise convert to 0 or 1900-01-01
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS clean.restaurants;
CREATE TABLE clean.restaurants (
    restaurant_id       VARCHAR(20)   NOT NULL PRIMARY KEY,
    restaurant_name     NVARCHAR(100) NOT NULL,
    cuisine             VARCHAR(50)   NOT NULL,
    tier                VARCHAR(30)   NULL,
    city                VARCHAR(50)   NOT NULL,
    area                NVARCHAR(50)  NULL,
    commission_pct      DECIMAL(5,2)  NULL,
    commission_missing  BIT           NOT NULL,
    onboarded_date      DATE          NULL
);

INSERT INTO clean.restaurants (restaurant_id, restaurant_name, cuisine, tier, city, area,
                               commission_pct, commission_missing, onboarded_date)
SELECT TRIM(r.restaurant_id),
       TRIM(r.restaurant_name),
       cu.standard_value,
       TRIM(r.tier),
       ci.standard_value,
       TRIM(r.area),
       CASE WHEN n.comm IS NULL THEN NULL
            WHEN n.comm < 1     THEN n.comm * 100
            ELSE n.comm END,
       CASE WHEN n.comm IS NULL THEN 1 ELSE 0 END,
       COALESCE(TRY_CONVERT(DATE, NULLIF(TRIM(r.onboarded_date), ''), 23),
                TRY_CONVERT(DATE, NULLIF(TRIM(r.onboarded_date), ''), 103))
FROM stg.restaurants AS r
CROSS APPLY (SELECT TRY_CAST(NULLIF(TRIM(r.commission_pct), '') AS DECIMAL(6,3)) AS comm) AS n
LEFT JOIN clean.map_cuisine AS cu ON cu.raw_key = UPPER(TRIM(r.cuisine))
LEFT JOIN clean.map_city    AS ci ON ci.raw_key = UPPER(TRIM(r.city))
WHERE TRIM(r.restaurant_id) NOT IN ('R1400', 'R1401', 'R1402', 'R1403');
GO

-- ---------------------------------------------------------------------
-- 7. clean.promotions (already clean: only types are converted)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS clean.promotions;
CREATE TABLE clean.promotions (
    promo_code       VARCHAR(20)  NOT NULL PRIMARY KEY,
    promo_type       VARCHAR(20)  NOT NULL,
    discount_value   DECIMAL(8,2) NOT NULL,
    max_discount     DECIMAL(8,2) NOT NULL,
    min_order_value  DECIMAL(8,2) NOT NULL,
    start_date       DATE         NOT NULL,
    end_date         DATE         NOT NULL,
    eligibility      VARCHAR(50)  NULL
);

INSERT INTO clean.promotions (promo_code, promo_type, discount_value, max_discount, min_order_value,
                              start_date, end_date, eligibility)
SELECT UPPER(TRIM(promo_code)),
       TRIM(promo_type),
       TRY_CAST(discount_value  AS DECIMAL(8,2)),
       TRY_CAST(max_discount    AS DECIMAL(8,2)),
       TRY_CAST(min_order_value AS DECIMAL(8,2)),
       TRY_CAST(start_date      AS DATE),
       TRY_CAST(end_date        AS DATE),
       TRIM(eligibility)
FROM stg.promotions;
GO

-- ---------------------------------------------------------------------
-- PART 2 CHECKS: compare each result with the expected value
-- ---------------------------------------------------------------------

-- V1. Row counts of the three clean tables
SELECT 'clean.delivery_partners' AS table_name, COUNT(*) AS row_count, 450 AS expected FROM clean.delivery_partners UNION ALL
SELECT 'clean.restaurants',                     COUNT(*),               320             FROM clean.restaurants       UNION ALL
SELECT 'clean.promotions',                      COUNT(*),               7               FROM clean.promotions;
GO

-- V2. Number of distinct values per cleaned text column
SELECT 'partners.city' AS column_name, COUNT(DISTINCT city) AS distinct_values, 7 AS expected FROM clean.delivery_partners UNION ALL
SELECT 'partners.vehicle_type',        COUNT(DISTINCT vehicle_type),            4             FROM clean.delivery_partners UNION ALL
SELECT 'partners.employment_type',     COUNT(DISTINCT employment_type),         2             FROM clean.delivery_partners UNION ALL
SELECT 'restaurants.city',             COUNT(DISTINCT city),                    7             FROM clean.restaurants       UNION ALL
SELECT 'restaurants.cuisine',          COUNT(DISTINCT cuisine),                 9             FROM clean.restaurants       UNION ALL
SELECT 'restaurants.tier',             COUNT(DISTINCT tier),                    3             FROM clean.restaurants;
GO

-- V3. Commission check: no fractions left, 7 still missing, range between 12 and 28
SELECT SUM(CASE WHEN commission_pct < 1 THEN 1 ELSE 0 END)    AS still_fractions,   -- expected 0
       SUM(CASE WHEN commission_pct IS NULL THEN 1 ELSE 0 END) AS missing,          -- expected 7
       MIN(commission_pct)                                     AS lowest,           -- expected 12 to 14
       MAX(commission_pct)                                     AS highest           -- expected 28
FROM clean.restaurants;
GO

-- V4. Onboarded date check: every date readable, range 2023 to 2025
SELECT SUM(CASE WHEN onboarded_date IS NULL THEN 1 ELSE 0 END) AS unreadable_dates,   -- expected 0
       MIN(onboarded_date)                                      AS earliest,
       MAX(onboarded_date)                                      AS latest
FROM clean.restaurants;
GO

-- V5. Same-name restaurants left after removing the 4 copies (expected 5 groups, all genuinely different restaurants)
SELECT UPPER(restaurant_name)          AS restaurant_name,
       city,
       UPPER(area)                     AS area,
       COUNT(*)                        AS ids,
       STRING_AGG(restaurant_id, ', ') AS restaurant_ids
FROM clean.restaurants
GROUP BY UPPER(restaurant_name), city, UPPER(area)
HAVING COUNT(*) > 1
ORDER BY restaurant_name;
-- Expected: Kolkata Bites (R1031, R1084), Fresh Express, Namaste House, Sweet Corner, Tandoor Junction.
-- Any extra group means the city mapping revealed a hidden duplicate: investigate it like R2.1.
GO

-- V5B. Restaurant names with leading or trailing spaces after cleaning (expected 0; the raw table had 16)
SELECT (SELECT COUNT(*) FROM stg.restaurants   WHERE restaurant_name <> TRIM(restaurant_name)) AS raw_with_spaces,
       (SELECT COUNT(*) FROM clean.restaurants WHERE restaurant_name <> TRIM(restaurant_name)) AS clean_with_spaces;
GO

/* ---------------------------------------------------------------------
   Results of the Part 2 checks:
     V1 450 / 320 / 7   V2 all 6 rows match   V3 0, 7, 12.00, 28.00   V4 0, 2023-01-01, 2025-09-24   V5 5 groups (as expected)
   --------------------------------------------------------------------- */

/* =====================================================================
   PART 3: clean.customers
   Findings addressed: #12 gender | #13 missing gender | #14 signup_channel | #15 age | #16 email
   #17 city | #18 phone layouts | #19 shared phone flag | #20 signup_date formats
   Also addressed: customer_name spaces and capitals (see check V10)
   ===================================================================== */

USE QuickBite;
GO

-- ---------------------------------------------------------------------
-- 8. clean.customers
--    Decisions:
--      * gender: mapped; missing becomes 'Unknown' (no value is guessed)
--      * age: outside 18-65 or missing -> NULL (age unknown)
--      * email: missing or not shaped like name@domain.ext -> NULL
--      * phone: keep the last 10 digits; must start with 6-9, otherwise NULL
--      * is_shared_phone = 1 when another customer account has the same phone (kept, not deleted)
--      * signup_date: yyyy-mm-dd (style 23) or dd-Mon-yyyy (hyphens replaced by spaces, style 106)
--      * customer_name: trimmed and written as 'First Last' (works because every name has exactly two words)
--    Each CROSS APPLY below computes one value once, so later columns can reuse it.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS clean.customers;
CREATE TABLE clean.customers (
    customer_id      VARCHAR(20)   NOT NULL PRIMARY KEY,
    customer_name    NVARCHAR(100) NOT NULL,
    gender           VARCHAR(10)   NOT NULL,
    age              TINYINT       NULL,
    city             VARCHAR(50)   NOT NULL,
    signup_channel   VARCHAR(30)   NOT NULL,
    signup_date      DATE          NULL,
    email            VARCHAR(200)  NULL,
    phone            CHAR(10)      NULL,
    is_shared_phone  BIT           NOT NULL
);

INSERT INTO clean.customers (customer_id, customer_name, gender, age, city, signup_channel,
                             signup_date, email, phone, is_shared_phone)
SELECT TRIM(c.customer_id),
       CASE WHEN nm.sp = 0
            THEN UPPER(LEFT(nm.t, 1)) + LOWER(SUBSTRING(nm.t, 2, 100))
            ELSE UPPER(LEFT(nm.t, 1)) + LOWER(SUBSTRING(nm.t, 2, nm.sp - 2)) + ' '
               + UPPER(SUBSTRING(nm.t, nm.sp + 1, 1)) + LOWER(SUBSTRING(nm.t, nm.sp + 2, 100)) END,
       COALESCE(g.standard_value, 'Unknown'),
       CASE WHEN ag.age BETWEEN 18 AND 65 THEN ag.age END,
       ci.standard_value,
       ch.standard_value,
       sd.d,
       CASE WHEN em.e LIKE '%_@_%._%' THEN em.e END,
       ph.phone10,
       CASE WHEN ph.phone10 IS NOT NULL AND COUNT(*) OVER (PARTITION BY ph.phone10) > 1 THEN 1 ELSE 0 END
FROM stg.customers AS c
CROSS APPLY (SELECT TRIM(c.customer_name) AS t, CHARINDEX(' ', TRIM(c.customer_name)) AS sp) AS nm
CROSS APPLY (SELECT TRY_CAST(NULLIF(TRIM(c.age), '') AS INT) AS age) AS ag
CROSS APPLY (SELECT NULLIF(LOWER(TRIM(c.email)), '') AS e) AS em
CROSS APPLY (SELECT RIGHT(REPLACE(REPLACE(TRIM(c.phone), ' ', ''), '+', ''), 10) AS p) AS p0
CROSS APPLY (SELECT CASE WHEN p0.p LIKE '[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' THEN p0.p END AS phone10) AS ph
CROSS APPLY (SELECT NULLIF(TRIM(c.signup_date), '') AS raw) AS sr
CROSS APPLY (SELECT COALESCE(TRY_CONVERT(DATE, sr.raw, 23),
                             TRY_CONVERT(DATE, REPLACE(sr.raw, '-', ' '), 106)) AS d) AS sd
LEFT JOIN clean.map_gender  AS g  ON g.raw_key  = UPPER(TRIM(c.gender))
LEFT JOIN clean.map_city    AS ci ON ci.raw_key = UPPER(TRIM(c.city))
LEFT JOIN clean.map_channel AS ch ON ch.raw_key = UPPER(TRIM(c.signup_channel));
GO

-- ---------------------------------------------------------------------
-- PART 3 CHECKS: compare each result with the expected value
-- ---------------------------------------------------------------------

-- V6. Row count and unique IDs (expected 6000 and 6000)
SELECT COUNT(*) AS row_count, COUNT(DISTINCT customer_id) AS distinct_ids
FROM clean.customers;
GO

-- V7. Gender, channel and city after cleaning (expected 16 rows)
--     gender: Male 3017, Female 2593, Other 180, Unknown 210
--     channel: Organic 1845, Paid Ads 1478, Promo Campaign 1195, Referral 745, Influencer 737
--     city: Bengaluru 1285, Mumbai 1238, Delhi 1217, Hyderabad 847, Chennai 489, Kolkata 468, Pune 456
SELECT 'gender' AS column_name, gender AS value, COUNT(*) AS customers FROM clean.customers GROUP BY gender
UNION ALL
SELECT 'signup_channel', signup_channel, COUNT(*) FROM clean.customers GROUP BY signup_channel
UNION ALL
SELECT 'city', city, COUNT(*) FROM clean.customers GROUP BY city
ORDER BY column_name, customers DESC;
GO

-- V8. Age, email, phone and signup date summary
SELECT SUM(CASE WHEN age IS NULL THEN 1 ELSE 0 END)         AS age_null,        -- expected 171
       MIN(age)                                              AS min_age,         -- expected 18
       MAX(age)                                              AS max_age,         -- expected 65
       SUM(CASE WHEN email IS NULL THEN 1 ELSE 0 END)        AS email_null,      -- expected 405
       SUM(CASE WHEN phone IS NULL THEN 1 ELSE 0 END)        AS phone_null,      -- expected 0
       SUM(CASE WHEN signup_date IS NULL THEN 1 ELSE 0 END)  AS date_null,       -- expected 0
       MIN(signup_date)                                      AS earliest_signup, -- expected around 2024-07
       MAX(signup_date)                                      AS latest_signup    -- expected around mid 2026
FROM clean.customers;
GO

-- V9. Shared phone flag (expected 125 accounts on 25 numbers)
SELECT SUM(CAST(is_shared_phone AS INT))                                      AS shared_phone_accounts,
       COUNT(DISTINCT CASE WHEN is_shared_phone = 1 THEN phone END)           AS shared_phone_numbers
FROM clean.customers;
GO

-- V10. Names: problems in the raw table vs the clean table (clean_still_bad expected 0)
SELECT (SELECT COUNT(*) FROM stg.customers
        WHERE DATALENGTH(customer_name) <> DATALENGTH(TRIM(customer_name)))                  AS raw_with_spaces,
       (SELECT COUNT(*) FROM stg.customers
        WHERE customer_name COLLATE Latin1_General_CS_AS = UPPER(customer_name))              AS raw_all_capitals,
       (SELECT COUNT(*) FROM stg.customers
        WHERE customer_name COLLATE Latin1_General_CS_AS = LOWER(customer_name))              AS raw_all_lowercase,
       (SELECT COUNT(*) FROM clean.customers
        WHERE customer_name COLLATE Latin1_General_CS_AS = UPPER(customer_name)
           OR customer_name COLLATE Latin1_General_CS_AS = LOWER(customer_name)
           OR DATALENGTH(customer_name) <> DATALENGTH(TRIM(customer_name)))                  AS clean_still_bad;
GO

-- V11. Spot check: 10 random customers, raw value next to clean value
SELECT TOP 10 s.customer_id,
       s.customer_name AS raw_name, c.customer_name AS clean_name,
       s.phone         AS raw_phone, c.phone         AS clean_phone,
       s.city          AS raw_city,  c.city          AS clean_city,
       s.signup_date   AS raw_date,  c.signup_date   AS clean_date
FROM stg.customers AS s
JOIN clean.customers AS c
  ON c.customer_id = TRIM(s.customer_id)
ORDER BY NEWID();
GO

/* ---------------------------------------------------------------------
   Results of the Part 3 checks:
     V6 6000 / 6000   V7 16 rows (city rows match)   V8 age null 171, ages 18-59, email null 405, phone null 0, date null 0,
     signup 2024-07-01 to 2026-06-30   V9 125 accounts / 25 numbers   V10 raw: 146 spaces, 237 capitals, 241 lowercase; clean still bad 0
   --------------------------------------------------------------------- */

/* =====================================================================
   PART 4A: clean.order_items
   Findings addressed: #31 duplicate item rows | #32 item_category | #33 item_name
   #34 quantity 0 or negative | #35 unit_price 0 | #36 orphan items
   clean.orders (Part 4B) follows the reconciliation diagnostic at the end of this part,
   which identifies the wrong value in the 806 orders whose total does not add up.
   ===================================================================== */

USE QuickBite;
GO

-- ---------------------------------------------------------------------
-- 9. A lookup for item names: each dish written in capitals or with spaces -> its correct spelling.
--    The correct spelling is the most common version that is NOT all capitals (trimmed).
--    Expected: 63 rows (the menu has 63 dishes).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS clean.map_item;
CREATE TABLE clean.map_item (raw_key VARCHAR(100) NOT NULL PRIMARY KEY, standard_value NVARCHAR(100) NOT NULL);
GO

WITH candidates AS (
    SELECT UPPER(TRIM(item_name))                             AS raw_key,
           TRIM(item_name) COLLATE Latin1_General_BIN2        AS spelling,
           COUNT(*)                                           AS n
    FROM stg.order_items
    WHERE item_name IS NOT NULL
      AND TRIM(item_name) COLLATE Latin1_General_BIN2 <> UPPER(TRIM(item_name)) COLLATE Latin1_General_BIN2
    GROUP BY UPPER(TRIM(item_name)), TRIM(item_name) COLLATE Latin1_General_BIN2
),
ranked AS (
    SELECT raw_key, spelling,
           ROW_NUMBER() OVER (PARTITION BY raw_key ORDER BY n DESC, spelling) AS rn
    FROM candidates
)
INSERT INTO clean.map_item (raw_key, standard_value)
SELECT raw_key, spelling
FROM ranked
WHERE rn = 1;
GO

-- ---------------------------------------------------------------------
-- 10. clean.order_items (revised after test RC3)
--     RC3 proved that the 40 orphan items are real lines whose order_id has one wrong character
--     (ORD9xxxxx instead of ORD5xxxxx): with the id repaired, all 40 orders add up exactly.
--     So these lines are KEPT and their id is repaired (column order_id_repaired = 1).
--     Decisions:
--      * duplicates: keep one row per order_item_id (check VI1 proves all 919 extras are exact copies)
--      * orphan id: if the order_id does not exist but 'ORD5' + the rest of the id does, use that id
--        (an item that still cannot be linked to an order is left out by the INNER JOIN below)
--      * quantity outside 1-10 -> NULL; unit_price of 0 or below -> filled from the same dish at the same
--        restaurant when that price is unique, otherwise NULL
--      * is_valid_line = 1 only when both quantity and price are known
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS clean.order_items;
CREATE TABLE clean.order_items (
    order_item_id      VARCHAR(20)    NOT NULL PRIMARY KEY,
    order_id           VARCHAR(20)    NOT NULL,
    item_name          NVARCHAR(100)  NOT NULL,
    item_category      VARCHAR(30)    NOT NULL,
    quantity           TINYINT        NULL,
    unit_price         DECIMAL(10,2)  NULL,
    price_source       VARCHAR(40)    NULL,
    is_valid_line      BIT            NOT NULL,
    order_id_repaired  BIT            NOT NULL
);
GO

WITH valid_orders AS (
    SELECT DISTINCT TRIM(order_id) AS order_id FROM stg.orders
),
ranked_items AS (
    SELECT i.*,
           ROW_NUMBER() OVER (PARTITION BY TRIM(i.order_item_id) ORDER BY (SELECT NULL)) AS rn
    FROM stg.order_items AS i
),
one_per_item AS (
    SELECT TRIM(order_item_id) AS order_item_id,
           TRIM(order_id)      AS raw_order_id,
           item_name,
           item_category,
           TRY_CAST(NULLIF(TRIM(quantity),   '') AS INT)            AS qty,
           TRY_CAST(NULLIF(TRIM(unit_price), '') AS DECIMAL(10,2))  AS price
    FROM ranked_items
    WHERE rn = 1
),
fixed AS (
    SELECT x.order_item_id, x.item_name, x.item_category, x.qty, x.price,
           COALESCE(v1.order_id, v2.order_id)                                        AS order_id,
           CASE WHEN v1.order_id IS NULL AND v2.order_id IS NOT NULL THEN 1 ELSE 0 END AS id_repaired
    FROM one_per_item AS x
    LEFT JOIN valid_orders AS v1 ON v1.order_id = x.raw_order_id
    LEFT JOIN valid_orders AS v2 ON v2.order_id = 'ORD5' + SUBSTRING(x.raw_order_id, 5, 20)
),
order_restaurant AS (
    SELECT DISTINCT TRIM(order_id) AS order_id, UPPER(TRIM(restaurant_id)) AS restaurant_id
    FROM stg.orders
),
price_lookup AS (
    SELECT orr.restaurant_id, UPPER(TRIM(x.item_name)) AS item_key,
           MIN(x.price) AS p_min, MAX(x.price) AS p_max
    FROM fixed AS x
    JOIN order_restaurant AS orr ON orr.order_id = x.order_id
    WHERE x.price > 0
    GROUP BY orr.restaurant_id, UPPER(TRIM(x.item_name))
)
INSERT INTO clean.order_items (order_item_id, order_id, item_name, item_category,
                               quantity, unit_price, price_source, is_valid_line, order_id_repaired)
SELECT x.order_item_id,
       x.order_id,
       m.standard_value,
       cat.standard_value,
       CASE WHEN x.qty BETWEEN 1 AND 10 THEN x.qty END,
       CASE WHEN x.price > 0 THEN x.price
            WHEN pl.p_min = pl.p_max THEN pl.p_max END,
       CASE WHEN x.price > 0 THEN 'original'
            WHEN pl.p_min = pl.p_max THEN 'filled from same dish and restaurant' END,
       CASE WHEN x.qty BETWEEN 1 AND 10
             AND (x.price > 0 OR pl.p_min = pl.p_max) THEN 1 ELSE 0 END,
       x.id_repaired
FROM fixed AS x
JOIN order_restaurant AS orr
  ON orr.order_id = x.order_id
LEFT JOIN price_lookup AS pl
       ON pl.restaurant_id = orr.restaurant_id
      AND pl.item_key      = UPPER(TRIM(x.item_name))
LEFT JOIN clean.map_item     AS m   ON m.raw_key   = UPPER(TRIM(x.item_name))
LEFT JOIN clean.map_category AS cat ON cat.raw_key = UPPER(TRIM(x.item_category));
GO

-- ---------------------------------------------------------------------
-- PART 4A CHECKS
-- ---------------------------------------------------------------------

-- VI1. Are all duplicate item rows exact copies? (expected 919 extra copies, the same number as in profiling I1)
WITH numbered AS (
    SELECT ROW_NUMBER() OVER (PARTITION BY order_item_id, order_id, item_name, item_category, quantity, unit_price
                              ORDER BY (SELECT NULL)) AS copy_number
    FROM stg.order_items
)
SELECT COUNT(*) AS extra_exact_copies
FROM numbered
WHERE copy_number > 1;
GO

-- VI2. Row counts (expected: lookup 63 rows; one row per order in the orders list 52,325; clean.order_items 114,991 after the repair)
SELECT (SELECT COUNT(*) FROM clean.map_item)                                                        AS item_lookup_rows,
       (SELECT COUNT(*) FROM (SELECT DISTINCT TRIM(order_id) AS o FROM stg.orders) AS d)            AS distinct_orders,
       (SELECT COUNT(*) FROM (SELECT DISTINCT TRIM(order_id) AS o, UPPER(TRIM(restaurant_id)) AS r
                              FROM stg.orders) AS d)                                                AS order_restaurant_pairs,
       (SELECT COUNT(*) FROM clean.order_items)                                                     AS clean_item_rows,
       (SELECT COUNT(DISTINCT order_item_id) FROM clean.order_items)                                AS clean_distinct_ids;
GO

-- VI3. Item names with no entry in the lookup (expected 0)
SELECT COUNT(*) AS unmapped_item_names
FROM stg.order_items AS i
LEFT JOIN clean.map_item AS m ON m.raw_key = UPPER(TRIM(i.item_name))
WHERE i.item_name IS NOT NULL AND TRIM(i.item_name) <> '' AND m.raw_key IS NULL;
GO

-- VI4. Quantity and price after cleaning
SELECT COUNT(*)                                                                             AS item_rows,       -- expected 114,991 after the repair
       SUM(CASE WHEN quantity IS NULL THEN 1 ELSE 0 END)                                    AS quantity_null,   -- expected about 25
       SUM(CASE WHEN unit_price IS NULL THEN 1 ELSE 0 END)                                  AS price_null,      -- expected 0 or very few
       SUM(CASE WHEN price_source = 'filled from same dish and restaurant' THEN 1 ELSE 0 END) AS price_filled,  -- expected about 20
       SUM(CASE WHEN is_valid_line = 0 THEN 1 ELSE 0 END)                                   AS invalid_lines,   -- expected about 25 to 45
       MIN(quantity)  AS min_qty,   MAX(quantity)  AS max_qty,                              -- expected 1 and 3
       MIN(unit_price) AS min_price, MAX(unit_price) AS max_price                           -- expected above 0 and 600
FROM clean.order_items;
GO

-- VI5. Categories after cleaning (expected exactly 6 rows)
SELECT item_category, COUNT(*) AS items
FROM clean.order_items
GROUP BY item_category
ORDER BY items DESC;
GO

-- VI6. Spot check: 10 random item rows, raw value next to clean value
SELECT TOP 10 s.order_item_id,
       s.item_name     AS raw_name,     c.item_name     AS clean_name,
       s.item_category AS raw_category, c.item_category AS clean_category,
       s.quantity      AS raw_qty,      c.quantity      AS clean_qty,
       s.unit_price    AS raw_price,    c.unit_price    AS clean_price
FROM stg.order_items AS s
JOIN clean.order_items AS c
  ON c.order_item_id = TRIM(s.order_item_id)
ORDER BY NEWID();
GO

-- VI7. Repaired order IDs (expected 40) and orders that still have no items (expected 0)
SELECT (SELECT SUM(CAST(order_id_repaired AS INT)) FROM clean.order_items)                 AS repaired_lines,
       (SELECT COUNT(*)
        FROM (SELECT DISTINCT TRIM(order_id) AS order_id FROM stg.orders) AS o
        WHERE NOT EXISTS (SELECT 1 FROM clean.order_items AS i WHERE i.order_id = o.order_id)) AS orders_without_items;
GO

-- ---------------------------------------------------------------------
-- RECONCILIATION DIAGNOSTIC (RC1): which value is wrong when an order does not add up?
--   An order's subtotal should equal the sum of quantity x unit_price over its items,
--   and total_amount should equal subtotal - discount + delivery_fee.
--   This groups every order by what holds. It only reads data; it changes nothing.
--   Before the repair: 4 | 26 | 14 | 51,464 | 258 | 559.  After the repair, expected about:
--   group 1 = 0 | 2 = 26 | 3 = 14 | 4 = 51,504 | 5 = 258 | 6 = 523
-- ---------------------------------------------------------------------
WITH o AS (
    SELECT TRIM(order_id) AS order_id,
           TRY_CAST(REPLACE(REPLACE(TRIM(subtotal), 'Rs.', ''), ' ', '') AS DECIMAL(10,2)) AS subtotal_raw,
           TRY_CAST(NULLIF(TRIM(discount_amount), '') AS DECIMAL(10,2))                    AS discount,
           TRY_CAST(NULLIF(TRIM(delivery_fee),    '') AS DECIMAL(10,2))                    AS fee,
           TRY_CAST(NULLIF(TRIM(total_amount),    '') AS DECIMAL(10,2))                    AS total_raw,
           ROW_NUMBER() OVER (PARTITION BY TRIM(order_id) ORDER BY (SELECT NULL))          AS rn
    FROM stg.orders
),
it AS (
    SELECT order_id,
           SUM(quantity * unit_price)                        AS items_total,
           SUM(CASE WHEN is_valid_line = 0 THEN 1 ELSE 0 END) AS bad_lines
    FROM clean.order_items
    GROUP BY order_id
),
graded AS (
    SELECT CASE
             WHEN it.order_id IS NULL
                  THEN '1. order has no items in clean.order_items'
             WHEN it.bad_lines > 0
                  THEN '2. an item line is invalid, so no comparison is possible'
             WHEN o.subtotal_raw IS NULL OR o.subtotal_raw <= 0
                  THEN '3. raw subtotal is invalid (negative or zero)'
             WHEN ABS(o.subtotal_raw - it.items_total) <= 0.01
              AND ABS(o.total_raw - (o.subtotal_raw - o.discount + o.fee)) <= 0.01
                  THEN '4. everything matches'
             WHEN ABS(o.subtotal_raw - it.items_total) <= 0.01
                  THEN '5. subtotal matches the items, but TOTAL is wrong'
             ELSE '6. subtotal does NOT match the items (SUBTOTAL is wrong)'
           END AS reconciliation_result
    FROM o
    LEFT JOIN it ON it.order_id = o.order_id
    WHERE o.rn = 1
)
SELECT reconciliation_result, COUNT(*) AS orders
FROM graded
GROUP BY reconciliation_result
ORDER BY reconciliation_result;
GO

/* ---------------------------------------------------------------------
   Results of the Part 4A checks:
     VI1 919   VI2 63 / 52,325 / 52,325 / 114,951 / 114,951   VI3 0   VI4 114,951 rows, quantity NULL 25, price NULL 1,
     price filled 19, invalid lines 26, qty 1-3, price 25-600   VI5 6 categories (Main 60,768, Starter 17,200, Dessert 14,068,
     Side 9,667, Beverage 9,487, Bread 3,761)
     RC1: group 1 = 4 | 2 = 26 | 3 = 14 | 4 = 51,464 | 5 = 258 | 6 = 559   (total 52,325 orders)
   --------------------------------------------------------------------- */

-- ---------------------------------------------------------------------
-- RC2: how big are the differences? (read-only; results recorded below)
--   A. orders where the subtotal does not match the items (RC1 group 6)
--   B. orders where the subtotal matches the items but the total is wrong (RC1 group 5)
--   If A shows one repeated number (the same error over and over), that is a systematic error.
-- ---------------------------------------------------------------------
WITH o AS (
    SELECT TRIM(order_id) AS order_id,
           TRY_CAST(REPLACE(REPLACE(TRIM(subtotal), 'Rs.', ''), ' ', '') AS DECIMAL(10,2)) AS subtotal_raw,
           TRY_CAST(NULLIF(TRIM(discount_amount), '') AS DECIMAL(10,2))                    AS discount,
           TRY_CAST(NULLIF(TRIM(delivery_fee),    '') AS DECIMAL(10,2))                    AS fee,
           TRY_CAST(NULLIF(TRIM(total_amount),    '') AS DECIMAL(10,2))                    AS total_raw,
           ROW_NUMBER() OVER (PARTITION BY TRIM(order_id) ORDER BY (SELECT NULL))          AS rn
    FROM stg.orders
),
it AS (
    SELECT order_id,
           SUM(quantity * unit_price)                          AS items_total,
           SUM(CASE WHEN is_valid_line = 0 THEN 1 ELSE 0 END)  AS bad_lines
    FROM clean.order_items
    GROUP BY order_id
),
d AS (
    SELECT o.order_id,
           o.subtotal_raw - it.items_total                          AS subtotal_diff,
           o.total_raw - (o.subtotal_raw - o.discount + o.fee)      AS total_diff
    FROM o
    JOIN it ON it.order_id = o.order_id
    WHERE o.rn = 1 AND it.bad_lines = 0 AND o.subtotal_raw > 0
)
SELECT 'A. subtotal minus items total' AS difference_type, subtotal_diff AS difference, COUNT(*) AS orders
FROM d
WHERE ABS(subtotal_diff) > 0.01
GROUP BY subtotal_diff
UNION ALL
SELECT 'B. total minus (subtotal - discount + fee)', total_diff, COUNT(*)
FROM d
WHERE ABS(subtotal_diff) <= 0.01 AND ABS(total_diff) > 0.01
GROUP BY total_diff
ORDER BY difference_type, orders DESC;
GO

-- ---------------------------------------------------------------------
-- RC3: can the 40 orphan items be repaired? (read-only; run before the repair, which changes the result)
--   Hypothesis: an orphan order_id (like ORD900107) is a real one (ORD500107) with one wrong character.
--   Test 1: does the repaired ID exist in orders?  Test 2: with the line added back, does the order add up?
-- ---------------------------------------------------------------------
WITH orphans AS (
    SELECT TRIM(i.order_item_id)                       AS order_item_id,
           TRIM(i.order_id)                            AS bad_id,
           'ORD5' + SUBSTRING(TRIM(i.order_id), 5, 20) AS candidate_id,
           TRY_CAST(NULLIF(TRIM(i.quantity),   '') AS INT)
         * TRY_CAST(NULLIF(TRIM(i.unit_price), '') AS DECIMAL(10,2)) AS line_total
    FROM (SELECT DISTINCT * FROM stg.order_items) AS i
    WHERE NOT EXISTS (SELECT 1 FROM stg.orders AS o WHERE TRIM(o.order_id) = TRIM(i.order_id))
),
orders_one AS (
    SELECT TRIM(order_id) AS order_id,
           TRY_CAST(REPLACE(REPLACE(TRIM(subtotal), 'Rs.', ''), ' ', '') AS DECIMAL(10,2)) AS subtotal_raw,
           ROW_NUMBER() OVER (PARTITION BY TRIM(order_id) ORDER BY (SELECT NULL))          AS rn
    FROM stg.orders
),
it AS (
    SELECT order_id, SUM(quantity * unit_price) AS items_total
    FROM clean.order_items
    GROUP BY order_id
)
SELECT COUNT(*)                                                                         AS orphan_items,
       SUM(CASE WHEN o.order_id IS NOT NULL THEN 1 ELSE 0 END)                          AS repaired_id_exists,
       SUM(CASE WHEN o.order_id IS NOT NULL
                 AND ABS(COALESCE(it.items_total, 0) + x.line_total - o.subtotal_raw) <= 0.01
                THEN 1 ELSE 0 END)                                                      AS order_adds_up_after_repair
FROM orphans AS x
LEFT JOIN orders_one AS o ON o.order_id = x.candidate_id AND o.rn = 1
LEFT JOIN it             ON it.order_id = x.candidate_id;
GO

/* ---------------------------------------------------------------------
   Results of RC2 and RC3:
     RC2 A: +60.00 in 523 orders (systematic error); 31 other differences, 1 to 3 orders each, 36 orders in total
            (559 = 523 + 36);  B: +100 in 70 orders, -50 in 65, +250 in 65, +30 in 58 (258 orders)
     RC3: orphan items 40 | repaired id exists 40 | order adds up after repair 40  -> hypothesis confirmed
   --------------------------------------------------------------------- */

/* =====================================================================
   PART 4B: clean.orders
   Rules chosen from the reconciliation results (RC1, RC2, RC3):
     * subtotal: the item total is the truth (98.4% of orders agree with it, and 523 orders are off by exactly 60)
                 -> use the item total when every item line is valid; otherwise the raw subtotal if it is positive
     * total_amount: recomputed as subtotal - discount_amount + delivery_fee (258 raw totals were wrong)
     * both corrections are flagged, so any analysis can show them
   Other findings addressed: #1 duplicate orders | #2 status | #3 payment | #4 order_datetime (3 formats)
   #5 subtotal text/negative/zero | #6 and #7 promo_code | #8 city | #9 and #10 orphan flags | #11 total mismatch
   ===================================================================== */

USE QuickBite;
GO

-- ---------------------------------------------------------------------
-- 11. clean.orders
--     Date rule (explicit pattern for each format, never a blanket CAST):
--        yyyy-mm-dd hh:mi:ss -> style 120 | dd/mm/yyyy hh:mi -> style 103 (day first) | dd-Mon-yyyy hh:mi -> style 106
--     Day first for the slash format is proven by checks VO4 and VO5 below.
--     Promo: 'no promo' written as NONE / N/A / 'no promo' / blank becomes NULL; codes in capitals.
--     Orphan customers and restaurants are KEPT and flagged (is_orphan_customer, is_orphan_restaurant).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS clean.orders;
CREATE TABLE clean.orders (
    order_id              VARCHAR(20)    NOT NULL PRIMARY KEY,
    customer_id           VARCHAR(20)    NOT NULL,
    restaurant_id         VARCHAR(20)    NOT NULL,
    order_datetime        DATETIME2(0)   NOT NULL,
    order_status          VARCHAR(30)    NOT NULL,
    payment_method        VARCHAR(20)    NOT NULL,
    promo_code            VARCHAR(20)    NULL,
    subtotal              DECIMAL(10,2)  NULL,
    discount_amount       DECIMAL(10,2)  NULL,
    delivery_fee          DECIMAL(10,2)  NULL,
    total_amount          DECIMAL(10,2)  NULL,
    delivery_city         VARCHAR(50)    NOT NULL,
    order_platform        VARCHAR(20)    NULL,
    subtotal_source       VARCHAR(40)    NOT NULL,
    subtotal_corrected    BIT            NOT NULL,
    total_corrected       BIT            NOT NULL,
    is_orphan_customer    BIT            NOT NULL,
    is_orphan_restaurant  BIT            NOT NULL
);
GO

WITH ranked AS (
    SELECT o.*,
           ROW_NUMBER() OVER (PARTITION BY TRIM(o.order_id) ORDER BY (SELECT NULL)) AS rn
    FROM stg.orders AS o
),
one AS (
    SELECT TRIM(order_id)       AS order_id,
           TRIM(customer_id)    AS customer_id,
           TRIM(restaurant_id)  AS restaurant_id,
           TRIM(order_datetime) AS dt_raw,
           order_status, payment_method, promo_code,
           subtotal, discount_amount, delivery_fee, total_amount,
           delivery_city, order_platform
    FROM ranked
    WHERE rn = 1
),
item_totals AS (
    SELECT order_id,
           SUM(quantity * unit_price)                          AS items_total,
           SUM(CASE WHEN is_valid_line = 0 THEN 1 ELSE 0 END)  AS bad_lines
    FROM clean.order_items
    GROUP BY order_id
)
INSERT INTO clean.orders (order_id, customer_id, restaurant_id, order_datetime, order_status, payment_method,
                          promo_code, subtotal, discount_amount, delivery_fee, total_amount, delivery_city,
                          order_platform, subtotal_source, subtotal_corrected, total_corrected,
                          is_orphan_customer, is_orphan_restaurant)
SELECT o.order_id,
       o.customer_id,
       o.restaurant_id,
       dt.value,
       st.standard_value,
       pm.standard_value,
       CASE WHEN pc.code IN ('', 'NONE', 'N/A', 'NO PROMO') THEN NULL ELSE pc.code END,
       s.sub,
       n.discount,
       n.fee,
       t.total_clean,
       ci.standard_value,
       NULLIF(TRIM(o.order_platform), ''),
       s.source,
       CASE WHEN s.sub IS NOT NULL AND (n.subtotal_raw IS NULL OR ABS(s.sub - n.subtotal_raw) > 0.01) THEN 1 ELSE 0 END,
       CASE WHEN t.total_clean IS NOT NULL AND (n.total_raw IS NULL OR ABS(t.total_clean - n.total_raw) > 0.01) THEN 1 ELSE 0 END,
       CASE WHEN cu.customer_id   IS NULL THEN 1 ELSE 0 END,
       CASE WHEN re.restaurant_id IS NULL THEN 1 ELSE 0 END
FROM one AS o
CROSS APPLY (SELECT CASE
                 WHEN o.dt_raw LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] %'
                      THEN TRY_CONVERT(DATETIME2(0), o.dt_raw, 120)
                 WHEN o.dt_raw LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9] %'
                      THEN TRY_CONVERT(DATETIME2(0), o.dt_raw, 103)
                 WHEN o.dt_raw LIKE '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9] %'
                      THEN COALESCE(TRY_CONVERT(DATETIME2(0), REPLACE(o.dt_raw, '-', ' '), 106),
                                    TRY_CAST(REPLACE(o.dt_raw, '-', ' ') AS DATETIME2(0)))
             END AS value) AS dt
CROSS APPLY (SELECT UPPER(TRIM(o.promo_code)) AS code) AS pc
CROSS APPLY (SELECT TRY_CAST(REPLACE(REPLACE(TRIM(o.subtotal), 'Rs.', ''), ' ', '') AS DECIMAL(10,2)) AS subtotal_raw,
                    TRY_CAST(NULLIF(TRIM(o.discount_amount), '') AS DECIMAL(10,2))                    AS discount,
                    TRY_CAST(NULLIF(TRIM(o.delivery_fee),    '') AS DECIMAL(10,2))                    AS fee,
                    TRY_CAST(NULLIF(TRIM(o.total_amount),    '') AS DECIMAL(10,2))                    AS total_raw) AS n
LEFT JOIN item_totals AS it ON it.order_id = o.order_id
CROSS APPLY (SELECT CASE WHEN it.order_id IS NOT NULL AND it.bad_lines = 0 THEN it.items_total
                         WHEN n.subtotal_raw > 0                            THEN n.subtotal_raw END AS sub,
                    CASE WHEN it.order_id IS NOT NULL AND it.bad_lines = 0 THEN 'items total'
                         WHEN n.subtotal_raw > 0                            THEN 'raw subtotal (items incomplete)'
                         ELSE 'unknown' END AS source) AS s
CROSS APPLY (SELECT CASE WHEN s.sub IS NOT NULL AND n.discount IS NOT NULL AND n.fee IS NOT NULL
                         THEN s.sub - n.discount + n.fee END AS total_clean) AS t
LEFT JOIN clean.map_status  AS st ON st.raw_key = UPPER(TRIM(o.order_status))
LEFT JOIN clean.map_payment AS pm ON pm.raw_key = UPPER(TRIM(o.payment_method))
LEFT JOIN clean.map_city    AS ci ON ci.raw_key = UPPER(TRIM(o.delivery_city))
LEFT JOIN clean.customers   AS cu ON cu.customer_id   = o.customer_id
LEFT JOIN clean.restaurants AS re ON re.restaurant_id = o.restaurant_id;
GO

-- ---------------------------------------------------------------------
-- PART 4B CHECKS
-- ---------------------------------------------------------------------

-- VO1. Row count and unique IDs (expected 52,325 and 52,325)
SELECT COUNT(*) AS row_count, COUNT(DISTINCT order_id) AS distinct_ids
FROM clean.orders;
GO

-- VO2. Distinct statuses (expected 5), payment methods (5), cities (7), promo codes (7); 'no promo' spellings left (0)
SELECT COUNT(DISTINCT order_status)   AS statuses,
       COUNT(DISTINCT payment_method) AS payment_methods,
       COUNT(DISTINCT delivery_city)  AS cities,
       COUNT(DISTINCT promo_code)     AS promo_codes,
       SUM(CASE WHEN promo_code IN ('NONE', 'N/A', 'NO PROMO', '') THEN 1 ELSE 0 END) AS fake_promo_codes,
       SUM(CASE WHEN promo_code IS NULL THEN 1 ELSE 0 END)                           AS orders_without_promo
FROM clean.orders;
GO

-- VO3. Date range and months (expected: earliest 2025-01, latest 2026-06, 18 months)
SELECT MIN(order_datetime)                              AS earliest,
       MAX(order_datetime)                              AS latest,
       COUNT(DISTINCT CONVERT(CHAR(7), order_datetime, 120)) AS months
FROM clean.orders;
GO

-- VO4. Proof 1 of the day-first rule: pickup must come AFTER the order and within 3 hours (both expected 0)
SELECT COUNT(*) AS deliveries_checked,
       SUM(CASE WHEN d.pickup < o.order_datetime THEN 1 ELSE 0 END)                        AS pickup_before_order,
       SUM(CASE WHEN DATEDIFF(MINUTE, o.order_datetime, d.pickup) > 180 THEN 1 ELSE 0 END) AS pickup_over_3h_after_order
FROM clean.orders AS o
JOIN (SELECT TRIM(order_id) AS order_id, TRY_CAST(pickup_time AS DATETIME2(0)) AS pickup
      FROM stg.deliveries) AS d
  ON d.order_id = o.order_id;
GO

-- VO5. Proof 2 of the day-first rule: order IDs were issued in time order, so dates must never go backwards (expected 0)
WITH s AS (
    SELECT order_datetime,
           LAG(order_datetime) OVER (ORDER BY order_id) AS previous_datetime
    FROM clean.orders
)
SELECT SUM(CASE WHEN order_datetime < previous_datetime THEN 1 ELSE 0 END) AS dates_going_backwards
FROM s;
GO

-- VO6. Amounts after the corrections
SELECT COUNT(*)                                                                       AS orders,
       SUM(CAST(subtotal_corrected AS INT))                                           AS subtotal_corrected,  -- expected about 537
       SUM(CAST(total_corrected AS INT))                                              AS total_corrected,     -- expected about 258
       SUM(CASE WHEN subtotal_source = 'items total' THEN 1 ELSE 0 END)               AS from_items,          -- expected about 52,299
       SUM(CASE WHEN subtotal_source = 'raw subtotal (items incomplete)' THEN 1 ELSE 0 END) AS from_raw,      -- expected about 26
       SUM(CASE WHEN subtotal_source = 'unknown' THEN 1 ELSE 0 END)                   AS unknown_subtotal,    -- expected 0
       SUM(CASE WHEN total_amount IS NOT NULL
                 AND ABS(total_amount - (subtotal - discount_amount + delivery_fee)) > 0.01
                THEN 1 ELSE 0 END)                                                    AS total_not_adding_up  -- expected 0
FROM clean.orders;
GO

-- VO7. Orphan flags (expected about 150 customers and about 100 restaurants: the raw counts 157 and 104 included duplicate rows)
SELECT SUM(CAST(is_orphan_customer AS INT))   AS orphan_customer_orders,
       SUM(CAST(is_orphan_restaurant AS INT)) AS orphan_restaurant_orders,
       SUM(CASE WHEN is_orphan_customer = 1 AND is_orphan_restaurant = 1 THEN 1 ELSE 0 END) AS both
FROM clean.orders;
GO

-- VO8. Spot check: 10 random orders, raw value next to clean value
SELECT TOP 10 s.order_id,
       s.order_datetime AS raw_datetime, c.order_datetime AS clean_datetime,
       s.order_status   AS raw_status,   c.order_status   AS clean_status,
       s.payment_method AS raw_payment,  c.payment_method AS clean_payment,
       s.promo_code     AS raw_promo,    c.promo_code     AS clean_promo,
       s.subtotal       AS raw_subtotal, c.subtotal       AS clean_subtotal,
       s.total_amount   AS raw_total,    c.total_amount   AS clean_total
FROM stg.orders AS s
JOIN clean.orders AS c
  ON c.order_id = TRIM(s.order_id)
ORDER BY NEWID();
GO

-- CHECKPOINT. Row counts of every clean table built so far
SELECT 'clean.delivery_partners' AS table_name, COUNT(*) AS row_count FROM clean.delivery_partners UNION ALL
SELECT 'clean.restaurants',  COUNT(*) FROM clean.restaurants  UNION ALL
SELECT 'clean.promotions',   COUNT(*) FROM clean.promotions   UNION ALL
SELECT 'clean.customers',    COUNT(*) FROM clean.customers    UNION ALL
SELECT 'clean.order_items',  COUNT(*) FROM clean.order_items  UNION ALL
SELECT 'clean.orders',       COUNT(*) FROM clean.orders;
GO

-- CHECKPOINT 2. Raw vs clean row counts for order_items, and items pointing to a missing order
SELECT (SELECT COUNT(*) FROM stg.order_items)   AS raw_rows,
       (SELECT COUNT(*) FROM clean.order_items) AS clean_rows,
       (SELECT COUNT(*) FROM clean.order_items AS i
        WHERE NOT EXISTS (SELECT 1 FROM clean.orders AS o WHERE o.order_id = i.order_id)) AS items_without_order;
GO

-- CHECKPOINT 3. Repaired order IDs on clean.order_items (expected 40, all matching an order)
SELECT SUM(CAST(i.order_id_repaired AS INT)) AS repaired_items,
       SUM(CASE WHEN i.order_id_repaired = 1 AND o.order_id IS NOT NULL
                THEN 1 ELSE 0 END)           AS repaired_and_matched
FROM clean.order_items AS i
LEFT JOIN clean.orders AS o
       ON o.order_id = i.order_id;
GO

/* =====================================================================
   PART 5: clean.deliveries and clean.reviews
   Rules chosen from the profiling results (numbers refer to data_quality_log.xlsx):
     * Nothing is deleted except exact duplicate review rows. A bad value is set to NULL and a flag column
       states the reason, so any analysis can include or exclude those rows and report how many were left out.
     * deliveries had no duplicates (D1: 48,012 rows = 48,012 distinct IDs), so no de-duplication is needed there.
   Part 5A, clean.deliveries:
     #37 delivered_time missing (180)            -> kept NULL, flag delivered_time_missing
     #38 delivered before pickup (12)            -> delivered_time set to NULL, flag delivered_before_pickup
     #39 distance_km of 0 or over 20 (8)         -> distance_km set to NULL, flag distance_invalid
     #40 promised_minutes of 0 (6)               -> promised_minutes set to NULL, flag promised_invalid
     #41 partner_payout missing (478)            -> kept NULL, flag payout_missing
   Part 5B, clean.reviews (built after 5A; uses clean.deliveries and clean.orders):
     #42 duplicate review rows (60 extra copies) -> keep one row per review_id (check VR1 proves they are exact copies)
     #43 rating outside 1-5 or not a number (30) -> rating set to NULL, flag rating_invalid
     #44 review_text missing (661)               -> kept NULL (not an error)
     #45 review dated before its delivery (20)   -> review_date set to NULL, flag review_date_invalid; rating is kept
   Source columns (confirmed by the COLUMN CHECK below):
     stg.deliveries: delivery_id, order_id, partner_id, pickup_time, delivered_time, distance_km, promised_minutes, partner_payout
     stg.reviews:    review_id, order_id, rating, review_text, review_date
   ===================================================================== */

USE QuickBite;
GO

-- ---------------------------------------------------------------------
-- COLUMN CHECK (read-only): confirms the source columns listed above
-- ---------------------------------------------------------------------
SELECT TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'stg' AND TABLE_NAME IN ('deliveries', 'reviews')
ORDER BY TABLE_NAME, ORDINAL_POSITION;
GO

-- ---------------------------------------------------------------------
-- 12. clean.deliveries
--     Decisions:
--      * a delivery that arrives before it is picked up is impossible: delivered_time -> NULL and flagged
--      * distance of 0 or over 20 km -> NULL and flagged (excluded from distance and payout analysis)
--      * promised_minutes of 0 -> NULL and flagged (excluded from SLA / late-delivery metrics)
--      * missing delivered_time and missing partner_payout stay NULL and are flagged, so they can be reported separately
--     The CROSS APPLY converts each text value once, so the CASE expressions can reuse it.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS clean.deliveries;
CREATE TABLE clean.deliveries (
    delivery_id             VARCHAR(20)   NOT NULL PRIMARY KEY,
    order_id                VARCHAR(20)   NOT NULL,
    partner_id              VARCHAR(20)   NOT NULL,
    pickup_time             DATETIME2(0)  NULL,
    delivered_time          DATETIME2(0)  NULL,
    distance_km             DECIMAL(6,2)  NULL,
    promised_minutes        INT           NULL,
    partner_payout          DECIMAL(8,2)  NULL,
    delivered_time_missing  BIT           NOT NULL,
    delivered_before_pickup BIT           NOT NULL,
    distance_invalid        BIT           NOT NULL,
    promised_invalid        BIT           NOT NULL,
    payout_missing          BIT           NOT NULL
);
GO

INSERT INTO clean.deliveries (delivery_id, order_id, partner_id, pickup_time, delivered_time, distance_km,
                              promised_minutes, partner_payout, delivered_time_missing, delivered_before_pickup,
                              distance_invalid, promised_invalid, payout_missing)
SELECT TRIM(d.delivery_id),
       TRIM(d.order_id),
       TRIM(d.partner_id),
       x.pickup_time,
       CASE WHEN x.delivered_time < x.pickup_time THEN NULL ELSE x.delivered_time END,
       CASE WHEN x.distance_km <= 0 OR x.distance_km > 20 THEN NULL ELSE x.distance_km END,
       CASE WHEN x.promised_minutes <= 0 THEN NULL ELSE x.promised_minutes END,
       x.partner_payout,
       CASE WHEN x.delivered_time IS NULL THEN 1 ELSE 0 END,
       CASE WHEN x.delivered_time < x.pickup_time THEN 1 ELSE 0 END,
       CASE WHEN x.distance_km <= 0 OR x.distance_km > 20 THEN 1 ELSE 0 END,
       CASE WHEN x.promised_minutes <= 0 THEN 1 ELSE 0 END,
       CASE WHEN x.partner_payout IS NULL THEN 1 ELSE 0 END
FROM stg.deliveries AS d
CROSS APPLY (SELECT TRY_CAST(NULLIF(TRIM(d.pickup_time),      '') AS DATETIME2(0)) AS pickup_time,
                    TRY_CAST(NULLIF(TRIM(d.delivered_time),   '') AS DATETIME2(0)) AS delivered_time,
                    TRY_CAST(NULLIF(TRIM(d.distance_km),      '') AS DECIMAL(6,2)) AS distance_km,
                    TRY_CAST(NULLIF(TRIM(d.promised_minutes), '') AS INT)          AS promised_minutes,
                    TRY_CAST(NULLIF(TRIM(d.partner_payout),   '') AS DECIMAL(8,2)) AS partner_payout) AS x;
GO

-- ---------------------------------------------------------------------
-- PART 5A CHECKS: compare each result with the expected value
-- ---------------------------------------------------------------------

-- VD1. Row count and unique IDs (expected 48,012 / 48,012 / 48,012; pickup_time missing 0)
SELECT COUNT(*)                    AS row_count,
       COUNT(DISTINCT delivery_id) AS distinct_deliveries,
       COUNT(DISTINCT order_id)    AS distinct_orders,
       SUM(CASE WHEN pickup_time IS NULL THEN 1 ELSE 0 END) AS pickup_missing
FROM clean.deliveries;
GO

-- VD2. Every delivery links to a clean order and a clean partner (both expected 0)
SELECT SUM(CASE WHEN o.order_id   IS NULL THEN 1 ELSE 0 END) AS deliveries_without_order,
       SUM(CASE WHEN p.partner_id IS NULL THEN 1 ELSE 0 END) AS deliveries_without_partner
FROM clean.deliveries AS d
LEFT JOIN clean.orders            AS o ON o.order_id   = d.order_id
LEFT JOIN clean.delivery_partners AS p ON p.partner_id = d.partner_id;
GO

-- VD3. Flag counts (expected 180, 12, 8, 6 and 478: the numbers of findings #37 to #41)
SELECT SUM(CAST(delivered_time_missing  AS INT)) AS arrival_missing,
       SUM(CAST(delivered_before_pickup AS INT)) AS delivered_before_pickup,
       SUM(CAST(distance_invalid        AS INT)) AS distance_invalid,
       SUM(CAST(promised_invalid        AS INT)) AS promised_invalid,
       SUM(CAST(payout_missing          AS INT)) AS payout_missing
FROM clean.deliveries;
GO

-- VD4. No impossible values left in the clean columns (all expected 0)
SELECT SUM(CASE WHEN delivered_time < pickup_time THEN 1 ELSE 0 END)          AS delivered_before_pickup,
       SUM(CASE WHEN distance_km <= 0 OR distance_km > 20 THEN 1 ELSE 0 END) AS bad_distance,
       SUM(CASE WHEN promised_minutes <= 0 THEN 1 ELSE 0 END)                AS bad_promised,
       SUM(CASE WHEN partner_payout <= 0 THEN 1 ELSE 0 END)                  AS bad_payout
FROM clean.deliveries;
GO

-- VD5. Spot check: 10 random flagged deliveries, raw value next to clean value
SELECT TOP 10 s.delivery_id,
       s.pickup_time       AS raw_pickup,
       s.delivered_time    AS raw_delivered,   c.delivered_time  AS clean_delivered,
       s.distance_km       AS raw_distance,    c.distance_km     AS clean_distance,
       s.promised_minutes  AS raw_promised,    c.promised_minutes AS clean_promised,
       s.partner_payout    AS raw_payout,      c.partner_payout  AS clean_payout
FROM stg.deliveries AS s
JOIN clean.deliveries AS c
  ON c.delivery_id = TRIM(s.delivery_id)
WHERE c.delivered_time_missing = 1 OR c.delivered_before_pickup = 1 OR c.distance_invalid = 1
   OR c.promised_invalid = 1 OR c.payout_missing = 1
ORDER BY NEWID();
GO

-- VD6. All rare flagged deliveries (expected 26 rows: 12 + 8 + 6), raw value next to clean value
SELECT s.delivery_id,
       s.pickup_time      AS raw_pickup,
       s.delivered_time   AS raw_delivered,  c.delivered_time   AS clean_delivered,
       s.distance_km      AS raw_distance,   c.distance_km      AS clean_distance,
       s.promised_minutes AS raw_promised,   c.promised_minutes AS clean_promised
FROM stg.deliveries AS s
JOIN clean.deliveries AS c
  ON c.delivery_id = TRIM(s.delivery_id)
WHERE c.delivered_before_pickup = 1 OR c.distance_invalid = 1 OR c.promised_invalid = 1
ORDER BY c.delivered_before_pickup DESC, c.distance_invalid DESC, s.delivery_id;
GO

-- ---------------------------------------------------------------------
-- 13. clean.reviews
--     Decisions:
--      * duplicates: keep one row per review_id (check VR1 proves all extra rows are exact copies)
--      * rating: whole numbers 1 to 5 only; anything else (not a number, below 1, above 5) -> NULL and flagged
--      * review_text: blank becomes NULL (many reviewers leave only a rating; this is not an error)
--      * review_date: a review cannot be written before the order was delivered. The reference day is the
--        delivery time, else the pickup time, else the order time. An earlier review_date -> NULL and flagged;
--        the rating is kept because the rating analysis joins by order, not by review date.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS clean.reviews;
CREATE TABLE clean.reviews (
    review_id             VARCHAR(20)    NOT NULL PRIMARY KEY,
    order_id              VARCHAR(20)    NOT NULL,
    rating                TINYINT        NULL,
    rating_invalid        BIT            NOT NULL,
    review_text           NVARCHAR(MAX)  NULL,
    review_date           DATE           NULL,
    review_date_invalid   BIT            NOT NULL
);
GO

WITH ranked AS (
    SELECT TRIM(review_id)                                       AS review_id,
           TRIM(order_id)                                        AS order_id,
           TRY_CAST(NULLIF(TRIM(rating),      '') AS DECIMAL(4,1)) AS rating_raw,
           NULLIF(TRIM(review_text), '')                         AS review_text,
           TRY_CAST(NULLIF(TRIM(review_date), '') AS DATE)       AS review_date_raw,
           ROW_NUMBER() OVER (PARTITION BY TRIM(review_id) ORDER BY (SELECT NULL)) AS rn
    FROM stg.reviews
)
INSERT INTO clean.reviews (review_id, order_id, rating, rating_invalid, review_text, review_date, review_date_invalid)
SELECT r.review_id,
       r.order_id,
       CASE WHEN r.rating_raw BETWEEN 1 AND 5 THEN CAST(r.rating_raw AS TINYINT) END,
       CASE WHEN r.rating_raw IS NULL OR r.rating_raw NOT BETWEEN 1 AND 5 THEN 1 ELSE 0 END,
       r.review_text,
       CASE WHEN r.review_date_raw < b.ref_date THEN NULL ELSE r.review_date_raw END,
       CASE WHEN r.review_date_raw < b.ref_date THEN 1 ELSE 0 END
FROM ranked AS r
LEFT JOIN clean.deliveries AS cd ON cd.order_id = r.order_id
LEFT JOIN clean.orders     AS o  ON o.order_id  = r.order_id
CROSS APPLY (SELECT CAST(COALESCE(cd.delivered_time, cd.pickup_time, o.order_datetime) AS DATE) AS ref_date) AS b
WHERE r.rn = 1;
GO

-- ---------------------------------------------------------------------
-- PART 5B CHECKS: compare each result with the expected value
-- ---------------------------------------------------------------------

-- VR1. Are all duplicate review rows exact copies? (expected 22,182 / 22,122 / 22,122 / 60; fractional ratings 0)
--      If distinct_full_rows equals distinct_ids, every extra row is an exact copy and keeping one is safe.
SELECT COUNT(*)                                                         AS raw_rows,
       COUNT(DISTINCT review_id)                                        AS distinct_ids,
       (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM stg.reviews) AS t) AS distinct_full_rows,
       COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM stg.reviews) AS t) AS extra_exact_copies,
       SUM(CASE WHEN TRY_CAST(rating AS DECIMAL(4,1)) <> FLOOR(TRY_CAST(rating AS DECIMAL(4,1))) THEN 1 ELSE 0 END) AS fractional_ratings
FROM stg.reviews;
GO

-- VR2. Row count and unique IDs (expected 22,122 / 22,122 / 22,122)
SELECT COUNT(*)                  AS row_count,
       COUNT(DISTINCT review_id) AS distinct_reviews,
       COUNT(DISTINCT order_id)  AS distinct_orders
FROM clean.reviews;
GO

-- VR3. Ratings after cleaning (expected min 1, max 5; about 30 invalid: the raw count of 30 included duplicate rows)
SELECT MIN(rating)                                       AS min_rating,
       MAX(rating)                                       AS max_rating,
       SUM(CAST(rating_invalid AS INT))                  AS rating_invalid,
       SUM(CASE WHEN rating IS NULL THEN 1 ELSE 0 END)   AS rating_null   -- expected the same as rating_invalid
FROM clean.reviews;
GO

-- VR4. Dates and text (expected about 20 invalid dates, earliest date in 2025 or later, about 650 missing texts, 0 empty texts)
SELECT SUM(CAST(review_date_invalid AS INT))               AS review_date_invalid,
       MIN(review_date)                                    AS earliest_review,
       MAX(review_date)                                    AS latest_review,
       SUM(CASE WHEN review_text IS NULL THEN 1 ELSE 0 END) AS text_missing,
       SUM(CASE WHEN review_text = ''    THEN 1 ELSE 0 END) AS text_empty
FROM clean.reviews;
GO

-- VR5. Every review links to a clean order (expected 0)
SELECT COUNT(*) AS reviews_without_order
FROM clean.reviews AS rv
WHERE NOT EXISTS (SELECT 1 FROM clean.orders AS o WHERE o.order_id = rv.order_id);
GO

-- VR6. Spot check: 10 random flagged reviews, raw value next to clean value
SELECT TOP 10 s.review_id,
       s.rating      AS raw_rating, c.rating      AS clean_rating,
       s.review_date AS raw_date,   c.review_date AS clean_date,
       c.rating_invalid, c.review_date_invalid
FROM stg.reviews AS s
JOIN clean.reviews AS c
  ON c.review_id = TRIM(s.review_id)
WHERE c.rating_invalid = 1 OR c.review_date_invalid = 1
ORDER BY NEWID();
GO

/* =====================================================================
   PART 6: final verification across the clean tables
   Parts 1 to 5 each checked one table; this part checks how the tables fit together.
   It only reads data: it creates nothing and changes nothing.
   An unexpected result is a new finding, not a script failure. It is added to
   data_quality_log.xlsx (next row, number 50) and handled by flagging, never by silently changing data.
     VF1  final row count of every clean table
     VF2  customers who signed up AFTER their first order (postponed from profiling)
     VF3  orders by status, with and without a delivery
     VF4  deliveries picked up before the partner joined
     VF5  reviews by order status
     VF6  orders placed before the restaurant was onboarded
   ===================================================================== */

USE QuickBite;
GO

-- ---------------------------------------------------------------------
-- PART 6 CHECKS: compare each result with the expected value
-- ---------------------------------------------------------------------

-- VF1. Final row count of every clean table (the column match should be 1 on every row)
SELECT 'clean.delivery_partners' AS table_name, COUNT(*) AS row_count, 450     AS expected, CASE WHEN COUNT(*) = 450     THEN 1 ELSE 0 END AS match FROM clean.delivery_partners UNION ALL
SELECT 'clean.restaurants',                     COUNT(*),               320,                 CASE WHEN COUNT(*) = 320     THEN 1 ELSE 0 END             FROM clean.restaurants       UNION ALL
SELECT 'clean.promotions',                      COUNT(*),               7,                   CASE WHEN COUNT(*) = 7       THEN 1 ELSE 0 END             FROM clean.promotions        UNION ALL
SELECT 'clean.customers',                       COUNT(*),               6000,                CASE WHEN COUNT(*) = 6000    THEN 1 ELSE 0 END             FROM clean.customers         UNION ALL
SELECT 'clean.orders',                          COUNT(*),               52325,               CASE WHEN COUNT(*) = 52325   THEN 1 ELSE 0 END             FROM clean.orders            UNION ALL
SELECT 'clean.order_items',                     COUNT(*),               114991,              CASE WHEN COUNT(*) = 114991  THEN 1 ELSE 0 END             FROM clean.order_items       UNION ALL
SELECT 'clean.deliveries',                      COUNT(*),               48012,               CASE WHEN COUNT(*) = 48012   THEN 1 ELSE 0 END             FROM clean.deliveries        UNION ALL
SELECT 'clean.reviews',                         COUNT(*),               22122,               CASE WHEN COUNT(*) = 22122   THEN 1 ELSE 0 END             FROM clean.reviews;
GO

-- VF2. Customers who signed up AFTER their first order (expected 0; any rows are a new finding for the log)
--      Only customers that exist in clean.customers and have at least one order are compared.
--      A negative gap means the customer signed up that many days after the first order.
WITH first_order AS (
    SELECT customer_id, CAST(MIN(order_datetime) AS DATE) AS first_order_date
    FROM clean.orders
    GROUP BY customer_id
)
SELECT COUNT(*)                                                                    AS customers_with_orders,
       SUM(CASE WHEN c.signup_date IS NULL THEN 1 ELSE 0 END)                      AS signup_date_missing,
       SUM(CASE WHEN c.signup_date > f.first_order_date THEN 1 ELSE 0 END)         AS signed_up_after_first_order,
       MIN(DATEDIFF(DAY, c.signup_date, f.first_order_date))                       AS biggest_negative_gap_days
FROM clean.customers AS c
JOIN first_order     AS f
ON f.customer_id = c.customer_id;
GO

-- VF2B. The 10 worst cases from VF2 (applies only if signed_up_after_first_order is not 0)
WITH first_order AS (
    SELECT customer_id, CAST(MIN(order_datetime) AS DATE) AS first_order_date
    FROM clean.orders
    GROUP BY customer_id
)
SELECT TOP 10 c.customer_id, c.signup_date, f.first_order_date,
       DATEDIFF(DAY, c.signup_date, f.first_order_date) AS days_gap
FROM clean.customers AS c
JOIN first_order     AS f ON f.customer_id = c.customer_id
WHERE c.signup_date > f.first_order_date
ORDER BY days_gap;
GO

-- VF3. Orders by status, with and without a delivery
--      Expected: 52,325 - 48,012 = 4,313 orders have no delivery in total.
--      Likely pattern: Delivered and Refunded have a delivery, the three Cancelled statuses do not.
--      A different pattern is not an error, but it determines how delivery metrics are filtered.
SELECT o.order_status,
       COUNT(*)                                                 AS orders,
       SUM(CASE WHEN d.order_id IS NOT NULL THEN 1 ELSE 0 END)  AS with_delivery,
       SUM(CASE WHEN d.order_id IS NULL     THEN 1 ELSE 0 END)  AS without_delivery
FROM clean.orders AS o
LEFT JOIN clean.deliveries AS d ON d.order_id = o.order_id
GROUP BY o.order_status
ORDER BY o.order_status;
GO

-- VF4. Deliveries picked up before the partner joined (expected 48,012 checked and 0; the same result as profiling D7)
SELECT COUNT(*) AS deliveries_checked,
       SUM(CASE WHEN CAST(d.pickup_time AS DATE) < p.joined_date THEN 1 ELSE 0 END) AS pickup_before_partner_joined
FROM clean.deliveries      AS d
JOIN clean.delivery_partners AS p ON p.partner_id = d.partner_id;
GO

-- VF5. Reviews by order status (expected: reviews only on Delivered orders, possibly Refunded too)
--      A review on a cancelled order would be a new finding.
SELECT o.order_status, COUNT(*) AS reviews
FROM clean.reviews AS r
JOIN clean.orders  AS o ON o.order_id = r.order_id
GROUP BY o.order_status
ORDER BY reviews DESC;
GO

-- VF6. Orders placed before the restaurant was onboarded (expected 0; any rows are a new finding for the log)
--      Orders of orphan restaurants are not compared (they have no restaurant row), and restaurants
--      without an onboarded date are skipped.
SELECT COUNT(*) AS orders_checked,
       SUM(CASE WHEN CAST(o.order_datetime AS DATE) < r.onboarded_date THEN 1 ELSE 0 END) AS ordered_before_onboarding
FROM clean.orders      AS o
JOIN clean.restaurants AS r ON r.restaurant_id = o.restaurant_id
WHERE r.onboarded_date IS NOT NULL;
GO

 /* =====================================================================
   PART 6B: follow-up to the Part 6 results
   Part 6 found two issues that need a decision. Both are logged in data_quality_log.xlsx.
     #50 customers who signed up AFTER their first order (VF2: 40 of 5,996 customers with orders, up to 39 days)
         Decision: it cannot be determined which date is wrong, so signup_date is NOT changed. The customer is flagged
         (is_signup_after_first_order) and customer-age / cohort / retention analysis uses the FIRST ORDER date.
     #51 orders placed before the restaurant's onboarded_date (VF6: 1,730 of 52,221 orders)
         Resolved in Part 6C. VF6B and VF6C below show how large and how widespread it is, and whether the restaurants
         whose onboarded_date was written as ambiguous dd/mm/yyyy (log #27) are the cause.
   ===================================================================== */

USE QuickBite;
GO

-- ---------------------------------------------------------------------
-- 14. clean.customers: flag customers who signed up after their first order (log #50)
--     The flag column is added once; the UPDATE resets and refills it, so this section can be run again.
--     NOTE: Part 3 drops and rebuilds clean.customers, so this section must be run again after Part 3 is re-run.
-- ---------------------------------------------------------------------
IF COL_LENGTH('clean.customers', 'is_signup_after_first_order') IS NULL
    ALTER TABLE clean.customers
    ADD is_signup_after_first_order BIT NOT NULL
        CONSTRAINT DF_customers_signup_after_first_order DEFAULT 0;
GO

UPDATE clean.customers SET is_signup_after_first_order = 0;
GO

UPDATE c
SET c.is_signup_after_first_order = 1
FROM clean.customers AS c
JOIN (SELECT customer_id, CAST(MIN(order_datetime) AS DATE) AS first_order_date
      FROM clean.orders
      GROUP BY customer_id) AS f
  ON f.customer_id = c.customer_id
WHERE c.signup_date > f.first_order_date;
GO

-- ---------------------------------------------------------------------
-- PART 6B CHECKS: compare each result with the expected value
-- ---------------------------------------------------------------------

-- VF2C. Flagged customers (expected 40 flagged out of 6,000 customers, the same 40 as in VF2)
SELECT SUM(CAST(is_signup_after_first_order AS INT)) AS flagged_customers,
       COUNT(*)                                      AS customers
FROM clean.customers;
GO

-- VF6B. How big is the onboarding problem? (read-only)
--       Gaps are in days from the restaurant's onboarded_date to its earliest order; a negative number means
--       the order is that many days BEFORE onboarding. orders_before_onboarding should equal 1,730 from VF6.
WITH early AS (
    SELECT r.restaurant_id, r.onboarded_date,
           CAST(MIN(o.order_datetime) AS DATE) AS first_order_date,
           COUNT(*)                            AS orders_before
    FROM clean.orders      AS o
    JOIN clean.restaurants AS r ON r.restaurant_id = o.restaurant_id
    WHERE CAST(o.order_datetime AS DATE) < r.onboarded_date
    GROUP BY r.restaurant_id, r.onboarded_date
)
SELECT (SELECT COUNT(*) FROM clean.restaurants)                        AS restaurants_total,
       COUNT(*)                                                        AS restaurants_affected,
       SUM(orders_before)                                              AS orders_before_onboarding,
       MIN(DATEDIFF(DAY, onboarded_date, first_order_date))            AS biggest_gap_days,
       AVG(DATEDIFF(DAY, onboarded_date, first_order_date))            AS average_gap_days,
       SUM(CASE WHEN onboarded_date >= '2025-01-01' THEN 1 ELSE 0 END) AS onboarded_in_2025
FROM early;
GO

-- VF6C. The 10 restaurants with the most orders before onboarding, with the raw onboarded_date next to the clean one
--       In the raw text, dd/mm/yyyy (slash) dates are the ones that could have been read the wrong way round.
WITH early AS (
    SELECT r.restaurant_id, r.onboarded_date,
           CAST(MIN(o.order_datetime) AS DATE) AS first_order_date,
           COUNT(*)                            AS orders_before
    FROM clean.orders      AS o
    JOIN clean.restaurants AS r ON r.restaurant_id = o.restaurant_id
    WHERE CAST(o.order_datetime AS DATE) < r.onboarded_date
    GROUP BY r.restaurant_id, r.onboarded_date
)
SELECT TOP 10 e.restaurant_id,
       s.onboarded_date                                        AS raw_onboarded,
       e.onboarded_date                                        AS clean_onboarded,
       e.first_order_date,
       DATEDIFF(DAY, e.onboarded_date, e.first_order_date)     AS gap_days,
       e.orders_before
FROM early AS e
LEFT JOIN stg.restaurants AS s ON TRIM(s.restaurant_id) = e.restaurant_id
ORDER BY e.orders_before DESC;
GO

   /* =====================================================================
   PART 6C: log #51 (orders placed before the restaurant's onboarded_date)
   What VF6B and VF6C showed: 78 of 320 restaurants are affected (all onboarded in 2025), 1,730 orders,
   up to 259 days before onboarding (average 119). In the top 10 restaurants the clean date equals the raw date,
   so the date reading is not what caused the gaps there. VF6D below checks this for ALL restaurants.
   Decision (same approach as #50): the orders are real sales, so none are deleted and onboarded_date is not changed.
   Each such order is flagged (ordered_before_onboarding) and restaurant tenure analysis uses the
   FIRST ORDER date instead of onboarded_date.
   VF6D checks whether the ambiguous dd/mm/yyyy dates are the cause; section 15 flags the orders when they are not.
   ===================================================================== */

USE QuickBite;
GO

-- ---------------------------------------------------------------------
-- VF6D. Is the raw date format the cause? (read-only)
--       Restaurants grouped by how their onboarded_date was written in the raw table, and how many of each group
--       have orders before onboarding. If the ambiguous group (day 12 or below) has about the same share as the
--       other groups, the format is not the cause. If it has a much higher share, the day and month were swapped.
-- ---------------------------------------------------------------------
WITH early AS (
    SELECT DISTINCT r.restaurant_id
    FROM clean.orders      AS o
    JOIN clean.restaurants AS r ON r.restaurant_id = o.restaurant_id
    WHERE CAST(o.order_datetime AS DATE) < r.onboarded_date
),
parts AS (
    SELECT c.restaurant_id,
           TRIM(s.onboarded_date)                  AS raw_date,
           CHARINDEX('/', TRIM(s.onboarded_date))  AS p1
    FROM clean.restaurants AS c
    LEFT JOIN stg.restaurants AS s ON TRIM(s.restaurant_id) = c.restaurant_id
),
fmt AS (
    SELECT restaurant_id,
           CASE WHEN p1 = 0 THEN 'yyyy-mm-dd (not ambiguous)'
                WHEN TRY_CAST(LEFT(raw_date, p1 - 1) AS INT) > 12 THEN 'dd/mm/yyyy, day above 12 (not ambiguous)'
                ELSE 'dd/mm/yyyy, day 12 or below (ambiguous)' END AS raw_format
    FROM parts
)
SELECT f.raw_format,
       COUNT(*)                                                       AS restaurants,
       SUM(CASE WHEN e.restaurant_id IS NOT NULL THEN 1 ELSE 0 END)   AS with_orders_before_onboarding
FROM fmt AS f
LEFT JOIN early AS e ON e.restaurant_id = f.restaurant_id
GROUP BY f.raw_format
ORDER BY f.raw_format;
GO

-- ---------------------------------------------------------------------
-- 15. clean.orders: flag orders placed before the restaurant's onboarded_date (log #51)
--     The flag column is added once; the UPDATE resets and refills it, so this section can be run again.
--     NOTE: Part 4B drops and rebuilds clean.orders, so this section must be run again after Part 4B is re-run.
--     Orders of orphan restaurants (no restaurant row) and restaurants without an onboarded date stay at 0.
-- ---------------------------------------------------------------------
IF COL_LENGTH('clean.orders', 'ordered_before_onboarding') IS NULL
    ALTER TABLE clean.orders
    ADD ordered_before_onboarding BIT NOT NULL
        CONSTRAINT DF_orders_ordered_before_onboarding DEFAULT 0;
GO

UPDATE clean.orders SET ordered_before_onboarding = 0;
GO

UPDATE o
SET o.ordered_before_onboarding = 1
FROM clean.orders      AS o
JOIN clean.restaurants AS r ON r.restaurant_id = o.restaurant_id
WHERE r.onboarded_date IS NOT NULL
  AND CAST(o.order_datetime AS DATE) < r.onboarded_date;
GO

-- ---------------------------------------------------------------------
-- PART 6C CHECK
-- ---------------------------------------------------------------------

-- VF6E. Flagged orders (expected 1,730 flagged out of 52,325 orders, the same 1,730 as in VF6)
SELECT SUM(CAST(ordered_before_onboarding AS INT)) AS flagged_orders,
       COUNT(*)                                    AS orders
FROM clean.orders;
GO

