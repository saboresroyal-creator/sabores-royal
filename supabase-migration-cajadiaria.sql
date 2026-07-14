-- =====================================================================
-- Caja Diaria (archivo HTML suelto en el escritorio) — sync remoto
-- =====================================================================
-- El dashboard de Caja Diaria (CAJA DIARIA.html, fuera de este repo)
-- ahora guarda su estado en este mismo proyecto Supabase, en
-- app_settings bajo la clave 'caja_diaria_data' — igual patrón que
-- rent_ledger. Es información financiera sensible (ventas, efectivo,
-- gastos), así que la excluimos de la lectura pública: solo el login
-- de administrador (autenticado) puede leerla o escribirla.
--
-- Seguro de correr más de una vez.
-- =====================================================================

DROP POLICY IF EXISTS "Public read app settings" ON app_settings;
CREATE POLICY "Public read app settings" ON app_settings
  FOR SELECT USING (setting_key NOT IN ('sub_admins', 'orders_list', 'rent_ledger', 'caja_diaria_data'));
