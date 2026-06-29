-- ============================================================
-- Day 4: Gold star schema + report views
-- Prereq: Day 3 done — aml.silver.{dim_customer, accounts, transactions, watchlist}
-- Run as ACCOUNTADMIN (or a role with rights on the aml database)
--
-- Star schema (Kimball), grain of fact = ONE transaction:
--
--          dim_date      dim_branch
--              \             /
--   dim_account — fact_transaction — dim_transaction_type
--                       |
--   reporting views: ctr_candidates / structuring_flags / sanctions_hits
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE aml;
-- USE WAREHOUSE COMPUTE_WH;   -- uncomment if you hit "no active warehouse"


-- ============================================================
-- STEP 1: dim_date — a generated date spine (role-played by txn_date)
--   date_sk is a smart key YYYYMMDD (INT) — easy to read, stable.
--   Spine is generous (2020-2027) so it covers every txn/open date.
-- ============================================================
CREATE OR REPLACE TABLE aml.gold.dim_date AS
SELECT
  TO_NUMBER(TO_CHAR(d, 'YYYYMMDD'))      AS date_sk,
  d                                       AS date,
  YEAR(d)                                 AS year,
  QUARTER(d)                              AS quarter,
  MONTH(d)                                AS month,
  MONTHNAME(d)                            AS month_name,
  DAY(d)                                  AS day,
  DAYOFWEEK(d)                            AS day_of_week,
  DAYNAME(d)                              AS day_name,
  IFF(DAYOFWEEK(d) IN (0, 6), TRUE, FALSE) AS is_weekend
FROM (
  SELECT DATEADD(day, SEQ4(), DATE '2020-01-01') AS d
  FROM TABLE(GENERATOR(ROWCOUNT => 2922))   -- ~8 years of days
);


-- ============================================================
-- STEP 2: dim_branch — conformed branch dimension
--   Only branch_id exists in source; synthesize a readable name.
-- ============================================================
CREATE OR REPLACE TABLE aml.gold.dim_branch AS
SELECT
  ROW_NUMBER() OVER (ORDER BY branch_id)  AS branch_sk,
  branch_id,
  'Branch ' || branch_id                  AS branch_name
FROM (SELECT DISTINCT branch_id FROM aml.silver.dim_customer WHERE branch_id IS NOT NULL);


-- ============================================================
-- STEP 3: dim_transaction_type — the small "type" dimension
-- ============================================================
CREATE OR REPLACE TABLE aml.gold.dim_transaction_type AS
SELECT
  ROW_NUMBER() OVER (ORDER BY txn_type)   AS txn_type_sk,
  txn_type,
  CASE txn_type
    WHEN 'CASH' THEN 'Cash'
    WHEN 'WIRE' THEN 'Wire Transfer'
    WHEN 'ACH'  THEN 'ACH Transfer'
    WHEN 'CARD' THEN 'Card'
    ELSE txn_type
  END                                     AS txn_type_desc
FROM (SELECT DISTINCT txn_type FROM aml.silver.transactions);


-- ============================================================
-- STEP 4: dim_account — one row per account, carries customer_id
--   so report views can hop account -> customer (SCD2 dim).
-- ============================================================
CREATE OR REPLACE TABLE aml.gold.dim_account AS
SELECT
  ROW_NUMBER() OVER (ORDER BY account_id) AS account_sk,
  account_id,
  customer_id,
  account_type,
  open_date
FROM aml.silver.accounts;


-- ============================================================
-- STEP 5: fact_transaction — grain = one transaction
--   FKs to every dim; keeps txn_type/direction/amount/txn_date
--   as columns so the report views can filter them directly.
-- ============================================================
CREATE OR REPLACE TABLE aml.gold.fact_transaction AS
SELECT
  t.txn_id,                              -- degenerate dimension (natural key)
  da.account_sk,                         -- FK -> dim_account
  dtt.txn_type_sk,                       -- FK -> dim_transaction_type
  db.branch_sk,                          -- FK -> dim_branch (via account's customer)
  dd.date_sk,                            -- FK -> dim_date
  t.txn_date,
  t.txn_type,
  t.direction,
  t.amount
FROM aml.silver.transactions t
JOIN      aml.gold.dim_account          da  ON t.account_id = da.account_id
JOIN      aml.gold.dim_transaction_type dtt ON t.txn_type   = dtt.txn_type
LEFT JOIN aml.silver.dim_customer       c   ON da.customer_id = c.customer_id AND c.is_current
LEFT JOIN aml.gold.dim_branch           db  ON c.branch_id    = db.branch_id
LEFT JOIN aml.gold.dim_date             dd  ON t.txn_date     = dd.date;

-- Verify: fact row count must equal silver.transactions (no rows dropped)
SELECT
  (SELECT COUNT(*) FROM aml.gold.fact_transaction) AS fact_rows,
  (SELECT COUNT(*) FROM aml.silver.transactions)   AS silver_rows;   -- expect 31153 / 31153


-- ============================================================
-- STEP 6a: CTR candidates
--   Cash CREDITs aggregating over $10k per customer per day
--   (Currency Transaction Report threshold).
-- ============================================================
CREATE OR REPLACE VIEW aml.reporting.ctr_candidates AS
SELECT
  c.customer_id,
  c.full_name,
  f.txn_date,
  COUNT(*)        AS cash_txn_count,
  SUM(f.amount)   AS total_cash
FROM aml.gold.fact_transaction f
JOIN aml.gold.dim_account     a ON f.account_sk = a.account_sk
JOIN aml.silver.dim_customer  c ON a.customer_id = c.customer_id AND c.is_current
WHERE f.txn_type = 'CASH' AND f.direction = 'CREDIT'
GROUP BY 1, 2, 3
HAVING SUM(f.amount) > 10000;


-- ============================================================
-- STEP 6b: Structuring / SAR flag
--   3+ SUB-$10k cash deposits same day that SUM over $10k —
--   the classic "smurfing under the CTR threshold" pattern.
-- ============================================================
CREATE OR REPLACE VIEW aml.reporting.structuring_flags AS
SELECT
  c.customer_id,
  c.full_name,
  f.txn_date,
  COUNT(*)        AS deposit_count,
  SUM(f.amount)   AS total_cash
FROM aml.gold.fact_transaction f
JOIN aml.gold.dim_account     a ON f.account_sk = a.account_sk
JOIN aml.silver.dim_customer  c ON a.customer_id = c.customer_id AND c.is_current
WHERE f.txn_type = 'CASH' AND f.direction = 'CREDIT' AND f.amount < 10000
GROUP BY 1, 2, 3
HAVING COUNT(*) >= 3 AND SUM(f.amount) > 10000;


-- ============================================================
-- STEP 6c: Sanctions screening
--   Current customers whose name matches the OFAC-style watchlist.
--   UPPER(TRIM(..)) = a forgiving exact match (real systems fuzzy-match).
-- ============================================================
CREATE OR REPLACE VIEW aml.reporting.sanctions_hits AS
SELECT DISTINCT
  c.customer_id,
  c.full_name,
  w.list_source
FROM aml.silver.dim_customer c
JOIN aml.silver.watchlist    w
  ON UPPER(TRIM(c.full_name)) = UPPER(TRIM(w.name))
WHERE c.is_current;


-- ============================================================
-- STEP 7: Confirm the planted patterns actually surface
-- ============================================================
SELECT * FROM aml.reporting.ctr_candidates    ORDER BY total_cash DESC;   -- planted structuring accts (~$12.5k cash/day)
SELECT * FROM aml.reporting.structuring_flags ORDER BY total_cash DESC;   -- the 6 smurfing accounts
SELECT * FROM aml.reporting.sanctions_hits;                              -- Viktor Petrov / OFAC SDN
