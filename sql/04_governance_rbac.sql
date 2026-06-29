-- ============================================================
-- Day 5: Governance — RBAC + dynamic masking + row access policy + tags
-- Prereq: Days 3-4 done (silver.dim_customer, gold star, reporting views)
-- Run as ACCOUNTADMIN.
--
-- Roles & what they see:
--   eng                -> builds pipelines; sees raw+silver+gold; SSN MASKED; all rows
--   compliance_analyst -> AML investigator; silver+gold+reporting (NO raw);
--                         SSN FULL; rows SCOPED to their region (branches 1-6)
--   auditor            -> read-only oversight; everything; SSN MASKED; all rows
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE aml;
-- USE WAREHOUSE COMPUTE_WH;   -- uncomment if you hit "no active warehouse"

-- Central schema to hold governance objects (policies, tags, mapping table)
CREATE SCHEMA IF NOT EXISTS aml.governance;


-- ============================================================
-- STEP 1: RBAC — three least-privilege roles
--   Created under SYSADMIN so the standard role hierarchy owns them;
--   because SYSADMIN rolls up to ACCOUNTADMIN, you can USE ROLE each
--   one for testing without granting to your user explicitly.
-- ============================================================
CREATE ROLE IF NOT EXISTS eng;
CREATE ROLE IF NOT EXISTS compliance_analyst;
CREATE ROLE IF NOT EXISTS auditor;

GRANT ROLE eng                TO ROLE SYSADMIN;
GRANT ROLE compliance_analyst TO ROLE SYSADMIN;
GRANT ROLE auditor            TO ROLE SYSADMIN;
-- Non-admin tester? also: GRANT ROLE compliance_analyst TO USER <your_user>;

-- Warehouse usage (swap COMPUTE_WH if yours is named differently)
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE eng;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE compliance_analyst;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE auditor;

GRANT USAGE ON DATABASE aml TO ROLE eng;
GRANT USAGE ON DATABASE aml TO ROLE compliance_analyst;
GRANT USAGE ON DATABASE aml TO ROLE auditor;

-- eng: full medallion read incl. raw landing (engineers debug the pipeline)
GRANT USAGE ON SCHEMA aml.raw    TO ROLE eng;
GRANT USAGE ON SCHEMA aml.silver TO ROLE eng;
GRANT USAGE ON SCHEMA aml.gold   TO ROLE eng;
GRANT SELECT ON ALL TABLES IN SCHEMA aml.raw    TO ROLE eng;
GRANT SELECT ON ALL TABLES IN SCHEMA aml.silver TO ROLE eng;
GRANT SELECT ON ALL TABLES IN SCHEMA aml.gold   TO ROLE eng;

-- compliance_analyst: silver+gold+reporting only — NO raw (least privilege)
GRANT USAGE ON SCHEMA aml.silver    TO ROLE compliance_analyst;
GRANT USAGE ON SCHEMA aml.gold      TO ROLE compliance_analyst;
GRANT USAGE ON SCHEMA aml.reporting TO ROLE compliance_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA aml.silver TO ROLE compliance_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA aml.gold   TO ROLE compliance_analyst;
GRANT SELECT ON ALL VIEWS  IN SCHEMA aml.reporting TO ROLE compliance_analyst;

-- auditor: read-only across the whole mart
GRANT USAGE ON SCHEMA aml.raw       TO ROLE auditor;
GRANT USAGE ON SCHEMA aml.silver    TO ROLE auditor;
GRANT USAGE ON SCHEMA aml.gold      TO ROLE auditor;
GRANT USAGE ON SCHEMA aml.reporting TO ROLE auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA aml.raw       TO ROLE auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA aml.silver    TO ROLE auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA aml.gold      TO ROLE auditor;
GRANT SELECT ON ALL VIEWS  IN SCHEMA aml.reporting TO ROLE auditor;

-- FUTURE grants so objects created later are covered automatically
GRANT SELECT ON FUTURE TABLES IN SCHEMA aml.silver TO ROLE compliance_analyst;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA aml.reporting TO ROLE compliance_analyst;
GRANT SELECT ON FUTURE TABLES IN SCHEMA aml.silver TO ROLE auditor;


-- ============================================================
-- STEP 2: Dynamic data masking on SSN
--   Compliance (and admin) see the real value; everyone else sees
--   XXX-XX-#### . The policy is evaluated on the SESSION role, so it
--   works no matter which view/table surfaces the column.
-- ============================================================
CREATE OR REPLACE MASKING POLICY aml.governance.mask_ssn AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('COMPLIANCE_ANALYST', 'ACCOUNTADMIN') THEN val
    ELSE 'XXX-XX-' || RIGHT(val, 4)
  END;

ALTER TABLE aml.silver.dim_customer
  MODIFY COLUMN ssn SET MASKING POLICY aml.governance.mask_ssn;


-- ============================================================
-- STEP 3: Row access policy — scope analysts to their region
--   Mapping table drives which branches a role may see. Admin/eng/
--   auditor are unrestricted; compliance_analyst is regional (1-6).
-- ============================================================
CREATE OR REPLACE TABLE aml.governance.branch_access (role_name STRING, branch_id INT);
INSERT INTO aml.governance.branch_access (role_name, branch_id)
SELECT 'COMPLIANCE_ANALYST', n FROM (VALUES (1),(2),(3),(4),(5),(6)) v(n);

CREATE OR REPLACE ROW ACCESS POLICY aml.governance.branch_rap
AS (branch_id INT) RETURNS BOOLEAN ->
  CURRENT_ROLE() IN ('ACCOUNTADMIN', 'SYSADMIN', 'AUDITOR', 'ENG')
  OR EXISTS (
    SELECT 1 FROM aml.governance.branch_access m
    WHERE m.role_name = CURRENT_ROLE()
      AND m.branch_id = branch_id
  );

ALTER TABLE aml.silver.dim_customer
  ADD ROW ACCESS POLICY aml.governance.branch_rap ON (branch_id);


-- ============================================================
-- STEP 4: Object tags — data classification metadata
--   Tags don't enforce anything; they let you DISCOVER & report on
--   where sensitive data lives (governance/lineage).
-- ============================================================
CREATE TAG IF NOT EXISTS aml.governance.data_classification
  ALLOWED_VALUES 'PUBLIC', 'INTERNAL', 'PII', 'PII_RESTRICTED'
  COMMENT = 'Sensitivity classification for AML data mart columns';

ALTER TABLE aml.silver.dim_customer MODIFY COLUMN ssn       SET TAG aml.governance.data_classification = 'PII_RESTRICTED';
ALTER TABLE aml.silver.dim_customer MODIFY COLUMN full_name SET TAG aml.governance.data_classification = 'PII';
ALTER TABLE aml.silver.dim_customer MODIFY COLUMN country   SET TAG aml.governance.data_classification = 'INTERNAL';


-- ============================================================
-- STEP 5: Tests — switch roles and confirm the controls behave
-- ============================================================

-- 5a) MASKING — SAME 5 rows under each role (branch 1-6 so the row
--     policy returns an identical set; only the SSN column differs).
USE ROLE COMPLIANCE_ANALYST;
SELECT customer_id, full_name, ssn, branch_id
FROM aml.silver.dim_customer
WHERE branch_id BETWEEN 1 AND 6
ORDER BY customer_id LIMIT 5;        -- ssn shown IN FULL (e.g. 229-18-1680)

USE ROLE AUDITOR;
SELECT customer_id, full_name, ssn, branch_id
FROM aml.silver.dim_customer
WHERE branch_id BETWEEN 1 AND 6
ORDER BY customer_id LIMIT 5;        -- ssn MASKED (XXX-XX-1680), same 5 customers

-- 5b) ROW ACCESS — visible row count differs by role
USE ROLE ACCOUNTADMIN;
SELECT COUNT(*) AS rows_visible FROM aml.silver.dim_customer;   -- 500 (all)

USE ROLE AUDITOR;
SELECT COUNT(*) AS rows_visible FROM aml.silver.dim_customer;   -- 500 (unrestricted)

USE ROLE COMPLIANCE_ANALYST;
SELECT COUNT(*) AS rows_visible FROM aml.silver.dim_customer;   -- < 500 (branches 1-6 only)
SELECT DISTINCT branch_id FROM aml.silver.dim_customer ORDER BY 1;  -- only 1..6

-- 5c) LEAST PRIVILEGE — analyst cannot touch raw landing
--     IMPORTANT: Snowsight defaults to USE SECONDARY ROLES ALL, which unions
--     in EVERY role your user has (incl. ACCOUNTADMIN) for object-access checks
--     — so a privilege test leaks unless you disable secondary roles first.
--     (Masking/row-access in 5a/5b are unaffected: they read CURRENT_ROLE(),
--      which is the PRIMARY role only.)
USE ROLE COMPLIANCE_ANALYST;
USE SECONDARY ROLES NONE;
SELECT CURRENT_ROLE();                    -- COMPLIANCE_ANALYST
SELECT COUNT(*) FROM aml.raw.customers;   -- expect: does not exist / not authorized

-- 5d) TAGS — discover where sensitive data lives
USE ROLE ACCOUNTADMIN;
SELECT * FROM TABLE(
  aml.information_schema.tag_references('aml.silver.dim_customer.ssn', 'COLUMN')
);

-- reset
USE ROLE ACCOUNTADMIN;
USE SECONDARY ROLES ALL;
