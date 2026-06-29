-- ============================================================
-- Day 6: Data-quality checks — a single PASS/FAIL scorecard view
-- Prereq: Days 3-5 (bronze, silver, gold, governance) loaded
-- Run as ACCOUNTADMIN (or any role with SELECT on raw/silver/gold)
--
-- Every check returns (check_name, category, status, metric).
-- Any status='FAIL' = investigate. Re-run the scorecard anytime:
--   SELECT * FROM aml.reporting.v_data_quality ORDER BY status DESC, category;
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE aml;

-- STEP 0: confirm the accepted-value sets match the data before trusting
--         the validity checks below. If these return values NOT in
--         ('CASH','WIRE','ACH','CARD') / ('CREDIT','DEBIT'), update the
--         IN-lists in the view.
SELECT DISTINCT txn_type  FROM aml.silver.transactions ORDER BY 1;
SELECT DISTINCT direction FROM aml.silver.transactions ORDER BY 1;


-- ============================================================
-- The scorecard view
-- ============================================================
CREATE OR REPLACE VIEW aml.reporting.v_data_quality AS
WITH checks AS (

  -- ---- Rowcount reconciliation: bronze vs data-generator output ----
  SELECT 'bronze_customers_count' AS check_name, 'rowcount' AS category,
         IFF((SELECT COUNT(*) FROM aml.raw.customers) = 500, 'PASS', 'FAIL') AS status,
         'expected=500 actual='   || (SELECT COUNT(*) FROM aml.raw.customers)    AS metric
  UNION ALL
  SELECT 'bronze_accounts_count', 'rowcount',
         IFF((SELECT COUNT(*) FROM aml.raw.accounts) = 773, 'PASS', 'FAIL'),
         'expected=773 actual='   || (SELECT COUNT(*) FROM aml.raw.accounts)
  UNION ALL
  SELECT 'bronze_transactions_count', 'rowcount',
         IFF((SELECT COUNT(*) FROM aml.raw.transactions) = 31153, 'PASS', 'FAIL'),
         'expected=31153 actual=' || (SELECT COUNT(*) FROM aml.raw.transactions)
  UNION ALL

  -- ---- Reconciliation: star build dropped no transactions ----
  SELECT 'fact_vs_silver_txns', 'reconciliation',
         IFF((SELECT COUNT(*) FROM aml.gold.fact_transaction)
           = (SELECT COUNT(*) FROM aml.silver.transactions), 'PASS', 'FAIL'),
         'fact='   || (SELECT COUNT(*) FROM aml.gold.fact_transaction) ||
         ' silver=' || (SELECT COUNT(*) FROM aml.silver.transactions)
  UNION ALL

  -- ---- PK uniqueness ----
  SELECT 'pk_dim_customer_unique', 'uniqueness',
         IFF(COUNT(*) = 0, 'PASS', 'FAIL'),
         COUNT(*) || ' duplicate current customer_id'
  FROM (SELECT customer_id FROM aml.silver.dim_customer WHERE is_current
        GROUP BY customer_id HAVING COUNT(*) > 1)
  UNION ALL
  SELECT 'pk_dim_account_unique', 'uniqueness',
         IFF(COUNT(*) = 0, 'PASS', 'FAIL'),
         COUNT(*) || ' duplicate account_id'
  FROM (SELECT account_id FROM aml.gold.dim_account
        GROUP BY account_id HAVING COUNT(*) > 1)
  UNION ALL
  SELECT 'pk_fact_txn_unique', 'uniqueness',
         IFF(COUNT(*) = 0, 'PASS', 'FAIL'),
         COUNT(*) || ' duplicate txn_id'
  FROM (SELECT txn_id FROM aml.gold.fact_transaction
        GROUP BY txn_id HAVING COUNT(*) > 1)
  UNION ALL

  -- ---- NULL / completeness on key columns ----
  SELECT 'null_customer_id', 'completeness',
         IFF(COUNT(*) = 0, 'PASS', 'FAIL'),
         COUNT(*) || ' null customer_id'
  FROM aml.silver.dim_customer WHERE customer_id IS NULL
  UNION ALL
  SELECT 'null_ssn', 'completeness',
         IFF(COUNT(*) = 0, 'PASS', 'FAIL'),
         COUNT(*) || ' null ssn (current rows)'
  FROM aml.silver.dim_customer WHERE is_current AND ssn IS NULL
  UNION ALL

  -- ---- Referential integrity ----
  SELECT 'fk_account_to_customer', 'integrity',
         IFF(COUNT(*) = 0, 'PASS', 'FAIL'),
         COUNT(*) || ' orphan accounts (no current customer)'
  FROM aml.silver.accounts a
  LEFT JOIN aml.silver.dim_customer c
    ON a.customer_id = c.customer_id AND c.is_current
  WHERE c.customer_id IS NULL
  UNION ALL
  SELECT 'fk_fact_to_account', 'integrity',
         IFF(COUNT(*) = 0, 'PASS', 'FAIL'),
         COUNT(*) || ' fact rows with no dim_account'
  FROM aml.gold.fact_transaction f
  LEFT JOIN aml.gold.dim_account d ON f.account_sk = d.account_sk
  WHERE d.account_sk IS NULL
  UNION ALL

  -- ---- SCD2 integrity: exactly one current row per customer ----
  SELECT 'scd2_one_current_per_customer', 'scd2',
         IFF(COUNT(*) = 0, 'PASS', 'FAIL'),
         COUNT(*) || ' customers with != 1 current row'
  FROM (SELECT customer_id FROM aml.silver.dim_customer WHERE is_current
        GROUP BY customer_id HAVING COUNT(*) <> 1)
  UNION ALL

  -- ---- Accepted values (see STEP 0 — adjust IN-lists if needed) ----
  SELECT 'accepted_txn_type', 'validity',
         IFF(COUNT(*) = 0, 'PASS', 'FAIL'),
         COUNT(*) || ' rows with unexpected txn_type'
  FROM aml.silver.transactions
  WHERE txn_type NOT IN ('CASH', 'WIRE', 'ACH', 'CARD')
  UNION ALL
  SELECT 'accepted_direction', 'validity',
         IFF(COUNT(*) = 0, 'PASS', 'FAIL'),
         COUNT(*) || ' rows with unexpected direction'
  FROM aml.silver.transactions
  WHERE direction NOT IN ('CREDIT', 'DEBIT')
  UNION ALL
  SELECT 'amount_positive', 'validity',
         IFF(COUNT(*) = 0, 'PASS', 'FAIL'),
         COUNT(*) || ' rows with amount <= 0'
  FROM aml.silver.transactions
  WHERE amount <= 0
)
SELECT * FROM checks;


-- ============================================================
-- Run the scorecard (FAILs sort to the top)
-- ============================================================
SELECT * FROM aml.reporting.v_data_quality
ORDER BY status DESC, category, check_name;

-- One-line gate (good for a screenshot / CI step)
SELECT IFF(COUNT_IF(status = 'FAIL') = 0,
           'ALL CHECKS PASSED',
           COUNT_IF(status = 'FAIL') || ' CHECK(S) FAILED') AS overall_result
FROM aml.reporting.v_data_quality;
