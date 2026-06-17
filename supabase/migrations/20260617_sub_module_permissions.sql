-- Sub-module permission flags for granular view-level access within Finance and Sales
ALTER TABLE erp_users
  ADD COLUMN IF NOT EXISTS module_finance_ar       boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS module_finance_ap       boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS module_finance_bank     boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS module_finance_ledger   boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS module_finance_reports  boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS module_sales_crm        boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS module_sales_orders     boolean DEFAULT true;
