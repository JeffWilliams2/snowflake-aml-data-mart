-- ============================================================
-- Day 2: Snowflake Storage Integration + External Stage
-- Run everything as ACCOUNTADMIN
-- ============================================================

USE ROLE ACCOUNTADMIN;

-- ------------------------------------------------------------
-- STEP 1: Storage integration
-- Replace <your-azure-tenant-id> before running
-- Find it: Azure Portal → Microsoft Entra ID → Overview → Tenant ID
-- ------------------------------------------------------------
CREATE STORAGE INTEGRATION azure_aml_int
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'AZURE'
  ENABLED = TRUE
  AZURE_TENANT_ID = 'debedd20-dae1-4dd8-8ccd-589f157a7b0e'
  STORAGE_ALLOWED_LOCATIONS = ('azure://lakeamldemo2407.blob.core.windows.net/lake/');

-- ------------------------------------------------------------
-- STEP 2: Get the consent URL and app name
-- This returns two critical values:
--   AZURE_CONSENT_URL  → open this in a browser and click Accept
--   AZURE_MULTI_TENANT_APP_NAME → the app you must grant IAM access to in Azure
-- ------------------------------------------------------------
DESC INTEGRATION azure_aml_int;

-- After running DESC above:
--   1. Copy AZURE_CONSENT_URL → open in browser → Accept
--   2. Copy AZURE_MULTI_TENANT_APP_NAME (looks like "snowflake-cdp-app-...")
--   3. In Azure Portal:
--        lakeamldemo2407 → Access Control (IAM) → Add role assignment
--        Role: "Storage Blob Data Contributor"
--        Assign to: the app name from step 2 (search by name)

-- ------------------------------------------------------------
-- STEP 3: Database context + file format + external stage (run after consent is done)
-- ------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS aml;
USE DATABASE aml;

CREATE OR REPLACE FILE FORMAT ff_parquet
  TYPE = PARQUET
  SNAPPY_COMPRESSION = TRUE;

CREATE OR REPLACE STAGE bronze_stage
  STORAGE_INTEGRATION = azure_aml_int
  URL = 'azure://lakeamldemo2407.blob.core.windows.net/lake/bronze/'
  FILE_FORMAT = ff_parquet;

-- ------------------------------------------------------------
-- STEP 4: Sanity check — should list your 4 parquet files
-- ------------------------------------------------------------
LIST @bronze_stage;
