-- Run this in the Supabase SQL editor for project fcagxvjxfqqkmuposmcb
--
-- Adds module permission columns and a force_password_change flag to erp_users.
-- Existing RLS policies on erp_users already cover these new columns — no RLS
-- changes are needed.

-- Add module permission columns to erp_users
ALTER TABLE erp_users
  ADD COLUMN IF NOT EXISTS module_finance boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS module_sales boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS module_operations boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS force_password_change boolean NOT NULL DEFAULT false;
