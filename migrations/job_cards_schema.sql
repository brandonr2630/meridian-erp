-- ─────────────────────────────────────────────────────────────────────────────
-- Job Cards schema — migrated into Meridian ERP Supabase project
-- Run this in the Supabase SQL editor (fcagxvjxfqq…) in one shot.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── JOB NUMBER SEQUENCE & RPC ─────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS job_no_seq START 1;

CREATE OR REPLACE FUNCTION next_job_no()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT 'JC-' || LPAD(nextval('job_no_seq')::text, 4, '0');
$$;


-- ── JOBS ─────────────────────────────────────────────────────────────────────

CREATE TABLE jobs (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id        uuid        NOT NULL REFERENCES companies(id) ON DELETE RESTRICT,
  job_no            text        NOT NULL,
  job_category      text,
  job_type          text,
  location          text,
  status            text        NOT NULL DEFAULT 'Open',
  priority          text        NOT NULL DEFAULT 'Normal',
  customer          text,
  contact           text,
  phone             text,
  email             text,
  date_received     date,
  due_date          date,
  description       text,
  part_name         text,
  customer_po       text,
  accepted_by       text,
  modified_by       text,
  quoted_ttd        numeric(12,2),
  payment_terms     text,
  misc_ttd          numeric(12,2) NOT NULL DEFAULT 0,
  costing_notes     text,
  jsa_ref           text,
  jsa_title         text,
  jsa_date_issued   date,
  jsa_issued_by     text,
  date_completed    date,
  inspected_by      text,
  qc_result         text,
  qc_notes          text,
  qc_state          jsonb        NOT NULL DEFAULT '[]',
  drawings          jsonb        NOT NULL DEFAULT '[]',
  specs             jsonb        NOT NULL DEFAULT '[]',
  reports           jsonb        NOT NULL DEFAULT '[]',
  created_by        uuid         REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at        timestamptz  NOT NULL DEFAULT now(),
  updated_at        timestamptz  NOT NULL DEFAULT now(),
  UNIQUE (company_id, job_no)
);

CREATE INDEX jobs_company_id_idx  ON jobs (company_id);
CREATE INDEX jobs_status_idx      ON jobs (status);
CREATE INDEX jobs_due_date_idx    ON jobs (due_date);


-- ── LABOUR ENTRIES ────────────────────────────────────────────────────────────

CREATE TABLE labour_entries (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id          uuid        NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  sort_order      int         NOT NULL DEFAULT 0,
  entry_date      date,
  classification  text,
  technician      text,
  location        text        NOT NULL DEFAULT 'Workshop',
  start_time      time,
  end_time        time,
  hours           numeric(8,2) NOT NULL DEFAULT 0,
  rate_ttd        numeric(10,2) NOT NULL DEFAULT 0,
  amount_ttd      numeric(12,2) NOT NULL DEFAULT 0,
  is_overtime     boolean      NOT NULL DEFAULT false,
  tasks           jsonb        NOT NULL DEFAULT '[]',
  created_at      timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX labour_entries_job_id_idx ON labour_entries (job_id);


-- ── EQUIPMENT ENTRIES ─────────────────────────────────────────────────────────

CREATE TABLE equipment_entries (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id        uuid        NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  sort_order    int         NOT NULL DEFAULT 0,
  entry_date    date,
  machine_name  text,
  asset_no      text,
  location      text        NOT NULL DEFAULT 'Workshop',
  setup_hours   numeric(8,2) NOT NULL DEFAULT 0,
  run_hours     numeric(8,2) NOT NULL DEFAULT 0,
  rate_ttd      numeric(10,2) NOT NULL DEFAULT 0,
  amount_ttd    numeric(12,2) NOT NULL DEFAULT 0,
  tasks         jsonb        NOT NULL DEFAULT '[]',
  created_at    timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX equipment_entries_job_id_idx ON equipment_entries (job_id);


-- ── MATERIAL ENTRIES ──────────────────────────────────────────────────────────

CREATE TABLE material_entries (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id          uuid        NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  sort_order      int         NOT NULL DEFAULT 0,
  entry_date      date,
  description     text,
  stock_code      text,
  quantity        numeric(10,3) NOT NULL DEFAULT 0,
  unit            text,
  unit_cost_ttd   numeric(10,2) NOT NULL DEFAULT 0,
  total_cost_ttd  numeric(12,2) NOT NULL DEFAULT 0,
  created_at      timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX material_entries_job_id_idx ON material_entries (job_id);


-- ── CONSUMABLE ENTRIES ────────────────────────────────────────────────────────

CREATE TABLE consumable_entries (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id          uuid        NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  sort_order      int         NOT NULL DEFAULT 0,
  entry_date      date,
  description     text,
  category        text,
  quantity        numeric(10,3) NOT NULL DEFAULT 0,
  unit            text,
  unit_cost_ttd   numeric(10,2) NOT NULL DEFAULT 0,
  total_cost_ttd  numeric(12,2) NOT NULL DEFAULT 0,
  created_at      timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX consumable_entries_job_id_idx ON consumable_entries (job_id);


-- ── SUBCONTRACTOR ENTRIES ─────────────────────────────────────────────────────

CREATE TABLE subcontractor_entries (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id              uuid        NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  sort_order          int         NOT NULL DEFAULT 0,
  entry_date          date,
  name                text,
  service_description text,
  invoice_ref         text,
  cost_ttd            numeric(12,2) NOT NULL DEFAULT 0,
  created_at          timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX subcontractor_entries_job_id_idx ON subcontractor_entries (job_id);


-- ── JOB AUDIT LOG ─────────────────────────────────────────────────────────────

CREATE TABLE job_audit_log (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id      uuid        REFERENCES jobs(id) ON DELETE SET NULL,
  job_no      text,
  user_id     uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  username    text,
  action_type text        NOT NULL,
  description text,
  metadata    jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX job_audit_log_job_id_idx ON job_audit_log (job_id);
CREATE INDEX job_audit_log_created_at_idx ON job_audit_log (created_at DESC);


-- ── EMPLOYEES ─────────────────────────────────────────────────────────────────

CREATE TABLE employees (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name                text        NOT NULL,
  job_classification  text,
  nationality         text,
  date_of_birth       date,
  date_of_employment  date,
  contact_no          text,
  address             text,
  email               text,
  next_of_kin         text,
  next_of_kin_contact text,
  created_by          uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);


-- ── CONFIG: LABOUR ────────────────────────────────────────────────────────────

CREATE TABLE config_labour (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  classification      text        NOT NULL,
  workshop_rate_ttd   numeric(10,2) NOT NULL DEFAULT 0,
  onsite_rate_ttd     numeric(10,2) NOT NULL DEFAULT 0,
  sort_order          int         NOT NULL DEFAULT 0,
  status              text        NOT NULL DEFAULT 'approved',
  is_active           boolean     NOT NULL DEFAULT true,
  submitted_by        uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);


-- ── CONFIG: MATERIALS ─────────────────────────────────────────────────────────

CREATE TABLE config_materials (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  item_name             text        NOT NULL,
  stock_code            text,
  unit                  text,
  default_unit_cost_ttd numeric(10,2) NOT NULL DEFAULT 0,
  sort_order            int         NOT NULL DEFAULT 0,
  status                text        NOT NULL DEFAULT 'approved',
  is_active             boolean     NOT NULL DEFAULT true,
  submitted_by          uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);


-- ── CONFIG: CONSUMABLES ───────────────────────────────────────────────────────

CREATE TABLE config_consumables (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  item_name             text        NOT NULL,
  category              text,
  unit                  text,
  default_unit_cost_ttd numeric(10,2) NOT NULL DEFAULT 0,
  sort_order            int         NOT NULL DEFAULT 0,
  status                text        NOT NULL DEFAULT 'approved',
  is_active             boolean     NOT NULL DEFAULT true,
  submitted_by          uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);


-- ── CONFIG: TASKS ─────────────────────────────────────────────────────────────

CREATE TABLE config_tasks (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  task_name    text        NOT NULL,
  category     text,
  sort_order   int         NOT NULL DEFAULT 0,
  status       text        NOT NULL DEFAULT 'approved',
  is_active    boolean     NOT NULL DEFAULT true,
  submitted_by uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);


-- ── CONFIG: QC CHECKLISTS ─────────────────────────────────────────────────────

CREATE TABLE config_qc_checklists (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  checklist_item text        NOT NULL,
  job_type       text,
  sort_order     int         NOT NULL DEFAULT 0,
  status         text        NOT NULL DEFAULT 'approved',
  is_active      boolean     NOT NULL DEFAULT true,
  submitted_by   uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);


-- ── CONFIG: EQUIPMENT ─────────────────────────────────────────────────────────

CREATE TABLE config_equipment (
  id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  equipment_name          text        NOT NULL,
  description_type        text,
  make                    text,
  model_no                text,
  serial_no               text,
  shop_number             text,
  year_of_manufacture     int,
  date_of_acquisition     date,
  capacity_size           text,
  workshop_rate_ttd       numeric(10,2) NOT NULL DEFAULT 0,
  onsite_rate_ttd         numeric(10,2) NOT NULL DEFAULT 0,
  accessories             jsonb        NOT NULL DEFAULT '[]',
  power_type              text,
  mobility_type           text,
  -- mobile-specific
  tyre_size               text,
  tyre_qty                int,
  -- electric-specific
  hp_kw                   numeric(8,2),
  voltage                 numeric(8,2),
  amps                    numeric(8,2),
  frequency               numeric(8,2),
  phase_type              text,
  electric_notes          text,
  -- diesel-specific
  fuel_capacity           numeric(8,2),
  fuel_filter_no          text,
  fuel_filter_qty         int,
  engine_oil_filter_no    text,
  engine_oil_filter_qty   int,
  hydraulic_filter_no     text,
  hydraulic_filter_qty    int,
  coolant_spec            text,
  coolant_capacity        numeric(8,2),
  engine_oil_spec         text,
  engine_oil_capacity     numeric(8,2),
  hydraulic_oil_spec      text,
  hydraulic_oil_capacity  numeric(8,2),
  sort_order              int         NOT NULL DEFAULT 0,
  status                  text        NOT NULL DEFAULT 'approved',
  is_active               boolean     NOT NULL DEFAULT true,
  submitted_by            uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);


-- ── UPDATED_AT TRIGGER ────────────────────────────────────────────────────────
-- Reuse if the ERP project already has a set_updated_at() function.
-- If not, create it here:

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

CREATE TRIGGER jobs_updated_at
  BEFORE UPDATE ON jobs
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER employees_updated_at
  BEFORE UPDATE ON employees
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER config_labour_updated_at
  BEFORE UPDATE ON config_labour
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER config_materials_updated_at
  BEFORE UPDATE ON config_materials
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER config_consumables_updated_at
  BEFORE UPDATE ON config_consumables
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER config_tasks_updated_at
  BEFORE UPDATE ON config_tasks
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER config_qc_checklists_updated_at
  BEFORE UPDATE ON config_qc_checklists
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER config_equipment_updated_at
  BEFORE UPDATE ON config_equipment
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ── ROW LEVEL SECURITY ────────────────────────────────────────────────────────
-- Enable RLS on all tables. Add policies to match your ERP's pattern.
-- Adjust the policy logic to match how the ERP handles auth (anon key + JWT).

ALTER TABLE jobs                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE labour_entries        ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_entries     ENABLE ROW LEVEL SECURITY;
ALTER TABLE material_entries      ENABLE ROW LEVEL SECURITY;
ALTER TABLE consumable_entries    ENABLE ROW LEVEL SECURITY;
ALTER TABLE subcontractor_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE job_audit_log         ENABLE ROW LEVEL SECURITY;
ALTER TABLE employees             ENABLE ROW LEVEL SECURITY;
ALTER TABLE config_labour         ENABLE ROW LEVEL SECURITY;
ALTER TABLE config_materials      ENABLE ROW LEVEL SECURITY;
ALTER TABLE config_consumables    ENABLE ROW LEVEL SECURITY;
ALTER TABLE config_tasks          ENABLE ROW LEVEL SECURITY;
ALTER TABLE config_qc_checklists  ENABLE ROW LEVEL SECURITY;
ALTER TABLE config_equipment      ENABLE ROW LEVEL SECURITY;

-- Permissive policies — tighten these once the ERP auth pattern is confirmed.
-- The ERP uses the anon key + user JWT for all requests, so authenticated = logged in.

CREATE POLICY "authenticated users full access" ON jobs
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON labour_entries
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON equipment_entries
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON material_entries
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON consumable_entries
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON subcontractor_entries
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON job_audit_log
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON employees
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON config_labour
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON config_materials
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON config_consumables
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON config_tasks
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON config_qc_checklists
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated users full access" ON config_equipment
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
