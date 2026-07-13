-- =====================================================================
-- Sabores Royal — Seguimiento de deuda de alquiler
-- =====================================================================
-- Guarda todo (cuota mensual + historial de cargos/pagos) en un único
-- registro de app_settings bajo la clave 'rent_ledger', igual que
-- novedades/ofertas/banners. Es información sensible (deuda real del
-- negocio), así que la excluimos de la política de lectura pública —
-- solo el panel de admin (autenticado) puede leerla o escribirla.
--
-- Seguro de correr más de una vez: el INSERT solo carga el saldo
-- inicial si la clave todavía no existe.
-- =====================================================================

DROP POLICY IF EXISTS "Public read app settings" ON app_settings;
CREATE POLICY "Public read app settings" ON app_settings
  FOR SELECT USING (setting_key NOT IN ('sub_admins', 'orders_list', 'rent_ledger'));

-- Saldo inicial: al 13/07/2026 se deben $4.070.000, monto que ya
-- incluye la cuota de julio 2026. Los meses siguientes se cargan solos
-- desde la app (ver ensureRentAutoCharge en public/index.html).
INSERT INTO app_settings (setting_key, setting_value)
SELECT 'rent_ledger', '{"monthlyAmount":1500000,"movements":[{"id":"seed-2026-07","date":"2026-07-13","type":"ajuste_inicial","period":"2026-07","amount":4070000,"note":"Saldo inicial (incluye alquiler de julio)"}]}'
WHERE NOT EXISTS (SELECT 1 FROM app_settings WHERE setting_key = 'rent_ledger');
