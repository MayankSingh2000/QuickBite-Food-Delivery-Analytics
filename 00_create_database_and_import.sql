/* =====================================================================
   QuickBite Food Delivery Analytics
   00_create_database_and_import.sql
 
   Steps
   1. Create the QuickBite database
   2. Create the stg and clean schemas
   3. Create 8 staging tables (all columns NVARCHAR)
   4. Load the 8 source CSV files with BULK INSERT (set @path to the CSV folder)
   5. Check row counts against the expected values
   ===================================================================== */

IF DB_ID('QuickBite') IS NULL CREATE DATABASE QuickBite;
GO
USE QuickBite;
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');   -- raw / untouched
GO
IF SCHEMA_ID('clean') IS NULL EXEC('CREATE SCHEMA clean'); -- cleaned tables (you build these)
GO

-- ---------- staging tables (all text) ----------
DROP TABLE IF EXISTS stg.customers, stg.restaurants, stg.delivery_partners, stg.promotions,
                     stg.orders, stg.order_items, stg.deliveries, stg.reviews;

CREATE TABLE stg.customers (
    customer_id NVARCHAR(50), customer_name NVARCHAR(200), gender NVARCHAR(50), age NVARCHAR(50),
    city NVARCHAR(100), signup_channel NVARCHAR(100), signup_date NVARCHAR(50),
    email NVARCHAR(200), phone NVARCHAR(50));

CREATE TABLE stg.restaurants (
    restaurant_id NVARCHAR(50), restaurant_name NVARCHAR(200), cuisine NVARCHAR(100), tier NVARCHAR(50),
    city NVARCHAR(100), area NVARCHAR(100), commission_pct NVARCHAR(50), onboarded_date NVARCHAR(50));

CREATE TABLE stg.delivery_partners (
    partner_id NVARCHAR(50), partner_name NVARCHAR(200), city NVARCHAR(100),
    vehicle_type NVARCHAR(50), employment_type NVARCHAR(50), joined_date NVARCHAR(50));

CREATE TABLE stg.promotions (
    promo_code NVARCHAR(50), promo_type NVARCHAR(50), discount_value NVARCHAR(50), max_discount NVARCHAR(50),
    min_order_value NVARCHAR(50), start_date NVARCHAR(50), end_date NVARCHAR(50), eligibility NVARCHAR(100));

CREATE TABLE stg.orders (
    order_id NVARCHAR(50), customer_id NVARCHAR(50), restaurant_id NVARCHAR(50), order_datetime NVARCHAR(50),
    order_status NVARCHAR(100), payment_method NVARCHAR(50), promo_code NVARCHAR(50),
    subtotal NVARCHAR(50), discount_amount NVARCHAR(50), delivery_fee NVARCHAR(50), total_amount NVARCHAR(50),
    delivery_city NVARCHAR(100), order_platform NVARCHAR(50));

CREATE TABLE stg.order_items (
    order_item_id NVARCHAR(50), order_id NVARCHAR(50), item_name NVARCHAR(200), item_category NVARCHAR(100),
    quantity NVARCHAR(50), unit_price NVARCHAR(50));

CREATE TABLE stg.deliveries (
    delivery_id NVARCHAR(50), order_id NVARCHAR(50), partner_id NVARCHAR(50), pickup_time NVARCHAR(50),
    delivered_time NVARCHAR(50), promised_minutes NVARCHAR(50), distance_km NVARCHAR(50), partner_payout NVARCHAR(50));

CREATE TABLE stg.reviews (
    review_id NVARCHAR(50), order_id NVARCHAR(50), rating NVARCHAR(50), review_text NVARCHAR(500), review_date NVARCHAR(50));
GO

-- ---------- load ----------
DECLARE @path NVARCHAR(400) = N'C:\QuickBite\';   -- <<< CHANGE THIS (keep trailing backslash)
DECLARE @sql  NVARCHAR(MAX) = N'';

DECLARE @t TABLE (tbl NVARCHAR(100), f NVARCHAR(100));
INSERT @t VALUES ('customers','customers.csv'), ('restaurants','restaurants.csv'),
                 ('delivery_partners','delivery_partners.csv'), ('promotions','promotions.csv'),
                 ('orders','orders.csv'), ('order_items','order_items.csv'),
                 ('deliveries','deliveries.csv'), ('reviews','reviews.csv');

SELECT @sql += N'BULK INSERT stg.' + tbl + N' FROM ''' + @path + f + N'''
 WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDQUOTE = ''"'', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'', TABLOCK);
'
FROM @t;

EXEC sp_executesql @sql;
GO

-- ---------- sanity check: row counts should match the files (minus header) ----------
SELECT 'customers' AS tbl, COUNT(*) AS row_count FROM stg.customers UNION ALL
SELECT 'restaurants', COUNT(*) FROM stg.restaurants UNION ALL
SELECT 'delivery_partners', COUNT(*) FROM stg.delivery_partners UNION ALL
SELECT 'promotions', COUNT(*) FROM stg.promotions UNION ALL
SELECT 'orders', COUNT(*) FROM stg.orders UNION ALL
SELECT 'order_items', COUNT(*) FROM stg.order_items UNION ALL
SELECT 'deliveries', COUNT(*) FROM stg.deliveries UNION ALL
SELECT 'reviews', COUNT(*) FROM stg.reviews;
-- Expected row counts: customers 6,000 | restaurants 324 | delivery_partners 450 | promotions 7
--                      orders 53,057 | order_items 115,910 | deliveries 48,012 | reviews 22,182
-- (orders/items/reviews are higher than the "true" counts because the raw extract contains duplicates)
