-- AFTER d0c_config: the role x operation matrix on the nine catalogs, employees and notification_types.
-- Identities (live-shaped): ops = operations_tech (C1), ops2 = operations_tech (C2), viewer, office = Office Admin, fm = finance_manager,
-- sales = sales_rep, adm = company_admin, sup = super_admin (2 companies), cfg = admin:settings only, usr = admin:users only,
-- client (no staff row), removed (inactive staff), anon.
BEGIN;
DO $$
DECLARE
  labels text[] := ARRAY['ops','viewer','office','fm','sales','ops2','client','removed','anon','adm','sup','cfg','usr'];
  subs   uuid[] := ARRAY['11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222','55555555-5555-5555-5555-555555555555',
                         'cccccccc-cccc-cccc-cccc-cccccccccccc','dddddddd-dddd-dddd-dddd-dddddddddddd','77777777-7777-7777-7777-777777777777',
                         '88888888-8888-8888-8888-888888888888','66666666-6666-6666-6666-666666666666',NULL,
                         '33333333-3333-3333-3333-333333333333','44444444-4444-4444-4444-444444444444',
                         'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb']::uuid[];
  rd  boolean[] := ARRAY[true,true,true,true,false,true,false,false,false,true,true,true,true];
  adm boolean[] := ARRAY[false,false,false,false,false,false,false,false,false,true,true,true,true];
  ap  boolean[] := ARRAY[false,false,true,true,false,false,false,false,false,true,true,false,false];
  cats text[] := ARRAY['config_consumables','config_equipment','config_fuel','config_hardware','config_labour','config_materials',
                       'config_qc_checklists','config_tasks','config_tooling'];
  ap_ins text[] := ARRAY['config_consumables','config_equipment','config_hardware','config_materials','config_tooling'];
  ap_upd text[] := ARRAY['config_consumables','config_hardware','config_materials','config_tooling'];
  t text; nm text; i int; r text; k int; expect_n int; ins_ok boolean; upd_ok boolean; stmt text;
  role_of text; other uuid := '99999999-9999-9999-9999-999999999999';
  staff_labels text[] := ARRAY['ops','viewer','office','fm','sales','ops2','adm','sup','cfg','usr'];
BEGIN
  FOREACH t IN ARRAY (cats || ARRAY['employees']) LOOP
    nm := CASE t WHEN 'config_equipment' THEN 'equipment_name' WHEN 'config_labour' THEN 'classification'
                 WHEN 'config_qc_checklists' THEN 'checklist_item' WHEN 'config_tasks' THEN 'task_name'
                 WHEN 'employees' THEN 'name' ELSE 'item_name' END;
    -- 1. SELECT
    FOR i IN 1..array_length(labels,1) LOOP
      role_of := CASE WHEN labels[i] = 'anon' THEN 'anon' ELSE 'authenticated' END;
      PERFORM t_expect(t || ' select ' || labels[i], t_count(role_of, subs[i], 'select * from public.' || t), CASE WHEN rd[i] THEN 'n:2' ELSE 'n:0' END);
    END LOOP;
    PERFORM t_expect(t || ' select service_role (edge functions bypass)', t_count('service_role', NULL, 'select * from public.' || t), 'n:2');

    -- 2. UPDATE (no-op value change, so counts stay stable)
    FOR i IN 1..array_length(labels,1) LOOP
      role_of := CASE WHEN labels[i] = 'anon' THEN 'anon' ELSE 'authenticated' END;
      upd_ok := adm[i] OR (ap[i] AND t = ANY(ap_upd));
      stmt := format('update public.%I set %I = %I where %I = %L', t, nm, nm, nm, 'fx-approved');
      PERFORM t_expect(t || ' update approved row ' || labels[i], t_dml(role_of, subs[i], stmt), CASE WHEN upd_ok THEN 'rows:1' ELSE 'rows:0' END);
      stmt := format('update public.%I set %I = %I where %I = %L', t, nm, nm, nm, 'fx-pending');
      PERFORM t_expect(t || ' update pending row ' || labels[i], t_dml(role_of, subs[i], stmt), CASE WHEN adm[i] THEN 'rows:1' ELSE 'rows:0' END);
    END LOOP;
    IF t = ANY(ap_upd) THEN
      -- AP writers re-price only; they cannot un-approve (WITH CHECK keeps status = approved)
      FOREACH r IN ARRAY ARRAY['office','fm'] LOOP
        k := array_position(labels, r);
        PERFORM t_expect(t || ' ' || r || ' cannot flip status', t_dml('authenticated', subs[k],
          format('update public.%I set status = ''pending'' where %I = %L', t, nm, 'fx-approved')), 'err:42501');
        PERFORM t_expect(t || ' ' || r || ' can re-price', t_dml('authenticated', subs[k],
          format('update public.%I set default_unit_cost_ttd = 12.5 where %I = %L', t, nm, 'fx-approved')), 'rows:1');
      END LOOP;
    END IF;

    -- 3. INSERT
    FOR i IN 1..array_length(labels,1) LOOP
      role_of := CASE WHEN labels[i] = 'anon' THEN 'anon' ELSE 'authenticated' END;
      ins_ok := adm[i] OR (ap[i] AND t = ANY(ap_ins));
      IF t = 'employees' THEN
        stmt := format('insert into public.employees (name, created_by) values (%L, %L)', 'ins-' || labels[i], subs[i]);
      ELSE
        stmt := format('insert into public.%I (%I, submitted_by) values (%L, %L)', t, nm, 'ins-' || labels[i], subs[i]);
      END IF;
      PERFORM t_expect(t || ' insert ' || labels[i], t_dml(role_of, subs[i], stmt), CASE WHEN ins_ok THEN 'rows:1' ELSE 'err:42501' END);
    END LOOP;
    IF t = ANY(ap_ins) THEN
      FOREACH r IN ARRAY ARRAY['office','fm'] LOOP
        k := array_position(labels, r);
        PERFORM t_expect(t || ' ' || r || ' insert with NULL submitted_by', t_dml('authenticated', subs[k],
          format('insert into public.%I (%I) values (%L)', t, nm, 'bad-null')), 'err:42501');
        PERFORM t_expect(t || ' ' || r || ' insert as someone else', t_dml('authenticated', subs[k],
          format('insert into public.%I (%I, submitted_by) values (%L, %L)', t, nm, 'bad-other', other)), 'err:42501');
      END LOOP;
    END IF;

    -- 4. DELETE: non-admins (including AP writers, even for rows they inserted) delete nothing; admins last
    FOR i IN 1..array_length(labels,1) LOOP
      CONTINUE WHEN adm[i];
      role_of := CASE WHEN labels[i] = 'anon' THEN 'anon' ELSE 'authenticated' END;
      PERFORM t_expect(t || ' delete fixtures ' || labels[i], t_dml(role_of, subs[i],
        format('delete from public.%I where %I IN (%L, %L, %L)', t, nm, 'fx-approved', 'fx-pending', 'ins-' || labels[i])), 'rows:0');
    END LOOP;
    FOREACH r IN ARRAY ARRAY['adm','sup','cfg','usr'] LOOP
      k := array_position(labels, r);
      PERFORM t_expect(t || ' delete own insert ' || r, t_dml('authenticated', subs[k],
        format('delete from public.%I where %I = %L', t, nm, 'ins-' || r)), 'rows:1');
    END LOOP;
    PERFORM t_expect(t || ' delete pending sup', t_dml('authenticated', subs[array_position(labels,'sup')],
      format('delete from public.%I where %I = %L', t, nm, 'fx-pending')), 'rows:1');
    PERFORM t_expect(t || ' delete approved cfg', t_dml('authenticated', subs[array_position(labels,'cfg')],
      format('delete from public.%I where %I = %L', t, nm, 'fx-approved')), 'rows:1');
    -- what is left: the rows AP writers inserted (office + fm) on the five tables that allow it
    expect_n := CASE WHEN t = ANY(ap_ins) THEN 2 ELSE 0 END;
    PERFORM t_expect(t || ' left after deletes', t_count('authenticated', subs[array_position(labels,'sup')], 'select * from public.' || t), 'n:' || expect_n);
  END LOOP;

  -- ── notification_types: every active staff reads, nobody writes through the API ──
  FOR i IN 1..array_length(labels,1) LOOP
    role_of := CASE WHEN labels[i] = 'anon' THEN 'anon' ELSE 'authenticated' END;
    PERFORM t_expect('notification_types select ' || labels[i], t_count(role_of, subs[i], 'select * from public.notification_types'),
      CASE WHEN labels[i] = ANY(staff_labels) THEN 'n:2' ELSE 'n:0' END);
    PERFORM t_expect('notification_types insert ' || labels[i], t_dml(role_of, subs[i],
      format('insert into public.notification_types (event_key, label, subject_tpl, body_html, recipient) values (%L,''l'',''s'',''b'',''direct'')', 'x-' || labels[i])), 'err:42501');
    PERFORM t_expect('notification_types update ' || labels[i], t_dml(role_of, subs[i], 'update public.notification_types set enabled = false'), 'rows:0');
    PERFORM t_expect('notification_types delete ' || labels[i], t_dml(role_of, subs[i], 'delete from public.notification_types'), 'rows:0');
  END LOOP;
  PERFORM t_expect('notification_types service_role reads (send-notification)', t_count('service_role', NULL, 'select * from public.notification_types where enabled = true'), 'n:2');
  PERFORM t_expect('notification_types service_role can write', t_dml('service_role', NULL, 'update public.notification_types set enabled = true'), 'rows:2');

  -- ── policy structure ──
  PERFORM t_expect('no legacy full-access policy left',
    (SELECT count(*)::text FROM pg_policies WHERE schemaname='public' AND policyname = 'authenticated users full access'
       AND tablename IN ('config_consumables','config_equipment','config_fuel','config_hardware','config_labour','config_materials','config_qc_checklists','config_tasks','config_tooling','employees')), '0');
  PERFORM t_expect('no notif_types_read left', (SELECT count(*)::text FROM pg_policies WHERE tablename='notification_types' AND policyname='notif_types_read'), '0');
  PERFORM t_expect('no permissive policy with a literal true on the 11 tables',
    (SELECT count(*)::text FROM pg_policies WHERE schemaname='public' AND permissive='PERMISSIVE'
       AND tablename IN ('config_consumables','config_equipment','config_fuel','config_hardware','config_labour','config_materials',
                         'config_qc_checklists','config_tasks','config_tooling','employees','notification_types')
       AND (qual = 'true' OR with_check = 'true')), '0');
  PERFORM t_expect('D0a restrictive pairs intact (22 policies)',
    (SELECT count(*)::text FROM pg_policies WHERE permissive='RESTRICTIVE' AND policyname IN ('d0_staff_only','d0_no_anon')
       AND tablename IN ('config_consumables','config_equipment','config_fuel','config_hardware','config_labour','config_materials',
                         'config_qc_checklists','config_tasks','config_tooling','employees','notification_types')), '22');
  PERFORM t_expect('d0c policy count (40 + 5 + 4 + 1)', (SELECT count(*)::text FROM pg_policies WHERE policyname LIKE 'd0c\_%'), '50');
END $$;
ROLLBACK;
