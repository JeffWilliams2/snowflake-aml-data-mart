-- ============================================================
-- Day 3: Bronze (raw landing) + Silver (conform & historize)
-- Prereq: Day 2 done — `aml` DB, ff_parquet, bronze_stage all exist
-- Run as ACCOUNTADMIN (or a role with rights on the aml database)
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE aml;

-- (Optional) make sure a warehouse is running for the COPY/MERGE work
-- USE WAREHOUSE COMPUTE_WH;

-- ============================================================
-- STEP 1: Schemas (the medallion layers)
--   raw       = bronze: untyped VARIANT landing + audit columns
--   silver    = conformed/typed, deduped, SCD2 dimensions
--   gold      = star schema (Day 4)
--   reporting = governed report views (Day 4/5)
-- ============================================================
CREATE SCHEMA IF NOT EXISTS aml.raw;
CREATE SCHEMA IF NOT EXISTS aml.silver;
CREATE SCHEMA IF NOT EXISTS aml.gold;
CREATE SCHEMA IF NOT EXISTS aml.reporting;

SHOW SCHEMAS IN DATABASE aml;


-- ============================================================
-- STEP 2: Bronze load — land each parquet as raw VARIANT + audit cols
--   data      = the whole parquet row as a VARIANT (parquet $1)
--   _load_ts  = when we loaded it
--   _file     = which file it came from (METADATA$FILENAME)
-- Bronze stays faithful & replayable: if silver logic is wrong,
-- we rebuild silver from here without re-ingesting from Azure.
-- ============================================================

-- customers
CREATE OR REPLACE TABLE aml.raw.customers (data VARIANT, _load_ts TIMESTAMP, _file STRING);
COPY INTO aml.raw.customers (data, _load_ts, _file)
  FROM (SELECT $1, CURRENT_TIMESTAMP(), METADATA$FILENAME FROM @aml.public.bronze_stage/customers/)
  FILE_FORMAT = ff_parquet;

-- accounts
CREATE OR REPLACE TABLE aml.raw.accounts (data VARIANT, _load_ts TIMESTAMP, _file STRING);
COPY INTO aml.raw.accounts (data, _load_ts, _file)
  FROM (SELECT $1, CURRENT_TIMESTAMP(), METADATA$FILENAME FROM @aml.public.bronze_stage/accounts/)
  FILE_FORMAT = ff_parquet;

-- transactions
CREATE OR REPLACE TABLE aml.raw.transactions (data VARIANT, _load_ts TIMESTAMP, _file STRING);
COPY INTO aml.raw.transactions (data, _load_ts, _file)
  FROM (SELECT $1, CURRENT_TIMESTAMP(), METADATA$FILENAME FROM @aml.public.bronze_stage/transactions/)
  FILE_FORMAT = ff_parquet;

-- watchlist
CREATE OR REPLACE TABLE aml.raw.watchlist (data VARIANT, _load_ts TIMESTAMP, _file STRING);
COPY INTO aml.raw.watchlist (data, _load_ts, _file)
  FROM (SELECT $1, CURRENT_TIMESTAMP(), METADATA$FILENAME FROM @aml.public.bronze_stage/watchlist/)
  FILE_FORMAT = ff_parquet;

-- Verify bronze rowcounts (expect ~500 / 773 / 31153 / 2)
-- NOTE: `rows` is a reserved word in Snowflake — alias as row_count
SELECT 'customers'    AS tbl, COUNT(*) AS row_count FROM aml.raw.customers
UNION ALL SELECT 'accounts',     COUNT(*) FROM aml.raw.accounts
UNION ALL SELECT 'transactions', COUNT(*) FROM aml.raw.transactions
UNION ALL SELECT 'watchlist',    COUNT(*) FROM aml.raw.watchlist;

-- Peek at one VARIANT row to confirm field names/types came through
SELECT * FROM aml.raw.customers LIMIT 1;


-- ============================================================
-- STEP 3: Silver — typed, deduped tables for the "type 1" entities
--   accounts / transactions / watchlist don't need history,
--   so they're a straight flatten + cast + dedup (CTAS, rebuildable).
--   QUALIFY ROW_NUMBER() keeps one row per business key.
-- ============================================================

-- accounts
CREATE OR REPLACE TABLE aml.silver.accounts AS
SELECT
  data:account_id::INT        AS account_id,
  data:customer_id::INT       AS customer_id,
  data:account_type::STRING   AS account_type,
  data:open_date::DATE        AS open_date,
  data:last_modified::TIMESTAMP_NTZ AS last_modified
FROM aml.raw.accounts
QUALIFY ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY last_modified DESC) = 1;

-- transactions
CREATE OR REPLACE TABLE aml.silver.transactions AS
SELECT
  data:txn_id::INT            AS txn_id,
  data:account_id::INT        AS account_id,
  data:txn_date::DATE         AS txn_date,
  data:amount::NUMBER(12,2)   AS amount,
  data:txn_type::STRING       AS txn_type,
  data:direction::STRING      AS direction,
  data:last_modified::TIMESTAMP_NTZ AS last_modified
FROM aml.raw.transactions
QUALIFY ROW_NUMBER() OVER (PARTITION BY txn_id ORDER BY last_modified DESC) = 1;

-- watchlist
CREATE OR REPLACE TABLE aml.silver.watchlist AS
SELECT
  data:name::STRING        AS name,
  data:list_source::STRING AS list_source
FROM aml.raw.watchlist
QUALIFY ROW_NUMBER() OVER (PARTITION BY name ORDER BY name) = 1;

-- Verify
SELECT 'accounts'     AS tbl, COUNT(*) AS row_count FROM aml.silver.accounts
UNION ALL SELECT 'transactions', COUNT(*) FROM aml.silver.transactions
UNION ALL SELECT 'watchlist',    COUNT(*) FROM aml.silver.watchlist;


-- ============================================================
-- STEP 4: Silver SCD Type 2 — dim_customer (historize KYC/country/etc.)
--   - A typed+deduped *source view* over bronze
--   - The SCD2 table with valid_from / valid_to / is_current
--   - A two-statement load: (A) close out changed current rows,
--     then (B) insert new + changed rows as the current version.
-- ============================================================

-- 4a) typed, deduped source over bronze (one row per customer_id)
CREATE OR REPLACE VIEW aml.silver.v_customer_src AS
SELECT
  data:customer_id::INT     AS customer_id,
  data:full_name::STRING    AS full_name,
  data:ssn::STRING          AS ssn,
  data:country::STRING      AS country,
  data:branch_id::INT       AS branch_id,
  data:kyc_status::STRING   AS kyc_status
FROM aml.raw.customers
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY data:customer_id::INT
  ORDER BY data:last_modified::TIMESTAMP_NTZ DESC
) = 1;

-- 4b) the SCD2 dimension table
CREATE OR REPLACE TABLE aml.silver.dim_customer (
  customer_sk INT AUTOINCREMENT START 1 INCREMENT 1,  -- surrogate key
  customer_id INT,                                     -- natural/business key
  full_name   STRING,
  ssn         STRING,
  country     STRING,
  branch_id   INT,
  kyc_status  STRING,
  valid_from  TIMESTAMP,
  valid_to    TIMESTAMP,
  is_current  BOOLEAN
);

-- 4c) STEP A — close out current rows whose tracked attributes changed
MERGE INTO aml.silver.dim_customer tgt
USING aml.silver.v_customer_src src
  ON tgt.customer_id = src.customer_id AND tgt.is_current = TRUE
WHEN MATCHED AND (
       tgt.kyc_status <> src.kyc_status
    OR tgt.country    <> src.country
    OR tgt.full_name  <> src.full_name
  )
  THEN UPDATE SET tgt.valid_to = CURRENT_TIMESTAMP(), tgt.is_current = FALSE;

-- 4d) STEP B — insert brand-new customers AND newly-changed versions as current
--      (anything in the source with no matching *current* row gets inserted)
INSERT INTO aml.silver.dim_customer
  (customer_id, full_name, ssn, country, branch_id, kyc_status, valid_from, valid_to, is_current)
SELECT
  src.customer_id, src.full_name, src.ssn, src.country, src.branch_id, src.kyc_status,
  CURRENT_TIMESTAMP(), NULL, TRUE
FROM aml.silver.v_customer_src src
LEFT JOIN aml.silver.dim_customer tgt
  ON tgt.customer_id = src.customer_id AND tgt.is_current = TRUE
WHERE tgt.customer_id IS NULL;

-- Verify: row count == 500 on first load, all is_current = TRUE
SELECT COUNT(*) AS total_rows,
       SUM(IFF(is_current, 1, 0)) AS current_rows
FROM aml.silver.dim_customer;

-- Sanity: the planted sanctioned name should be here
SELECT * FROM aml.silver.dim_customer WHERE full_name = 'Viktor Petrov';


-- ============================================================
-- (OPTIONAL) Prove SCD2 works: simulate a KYC change for customer 1,
-- re-run the close-out + insert, and watch a 2nd version appear.
-- This uses an inline source that flips customer 1 to 'PENDING'.
-- ============================================================
-- MERGE INTO aml.silver.dim_customer tgt
-- USING (
--   SELECT customer_id, full_name, ssn, country, branch_id,
--          IFF(customer_id = 1, 'PENDING', kyc_status) AS kyc_status
--   FROM aml.silver.v_customer_src
-- ) src
--   ON tgt.customer_id = src.customer_id AND tgt.is_current = TRUE
-- WHEN MATCHED AND (tgt.kyc_status <> src.kyc_status OR tgt.country <> src.country OR tgt.full_name <> src.full_name)
--   THEN UPDATE SET tgt.valid_to = CURRENT_TIMESTAMP(), tgt.is_current = FALSE;
--
-- INSERT INTO aml.silver.dim_customer
--   (customer_id, full_name, ssn, country, branch_id, kyc_status, valid_from, valid_to, is_current)
-- SELECT src.customer_id, src.full_name, src.ssn, src.country, src.branch_id, src.kyc_status,
--        CURRENT_TIMESTAMP(), NULL, TRUE
-- FROM (
--   SELECT customer_id, full_name, ssn, country, branch_id,
--          IFF(customer_id = 1, 'PENDING', kyc_status) AS kyc_status
--   FROM aml.silver.v_customer_src
-- ) src
-- LEFT JOIN aml.silver.dim_customer tgt
--   ON tgt.customer_id = src.customer_id AND tgt.is_current = TRUE
-- WHERE tgt.customer_id IS NULL;
--
-- -- now customer 1 has 2 rows: old (is_current=FALSE, valid_to set) + new (PENDING, current)
-- SELECT customer_sk, customer_id, kyc_status, valid_from, valid_to, is_current
-- FROM aml.silver.dim_customer WHERE customer_id = 1 ORDER BY customer_sk;
