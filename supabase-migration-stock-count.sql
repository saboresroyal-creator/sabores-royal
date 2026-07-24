-- =====================================================================
-- Sabores Royal — Conteo de stock (inventario físico)
-- =====================================================================
-- Guarda el conteo físico de mercadería (código, nombre, cantidad
-- contada, precio de venta) en un único registro de app_settings bajo
-- la clave 'stock_count', igual que rent_ledger/supplier_debts. Es un
-- registro aparte del stock que usa la caja para vender (products.stock),
-- así que no toca esa tabla — solo sirve para saber cuánto hay y
-- cuánto vale. Lo excluimos de la lectura pública: solo el panel de
-- admin (autenticado) puede leerlo o escribirlo.
--
-- Seguro de correr más de una vez.
-- =====================================================================

DROP POLICY IF EXISTS "Public read app settings" ON app_settings;
CREATE POLICY "Public read app settings" ON app_settings
  FOR SELECT USING (setting_key NOT IN ('sub_admins', 'orders_list', 'rent_ledger', 'supplier_debts', 'supplier_checks', 'stock_count'));

INSERT INTO app_settings (setting_key, setting_value)
SELECT 'stock_count', '{"items":[]}'
WHERE NOT EXISTS (SELECT 1 FROM app_settings WHERE setting_key = 'stock_count');
