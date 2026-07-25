-- =====================================================================
-- Sabores Royal — Catálogo de códigos de barras (autocompletar alta)
-- =====================================================================
-- Guarda, en un único registro de app_settings bajo la clave
-- 'barcode_catalog', un mapa código de barras → {name, price} que se
-- arma solo con lo que se va cargando en "Nuevo producto" y en
-- "Conteo de Stock". Así, si un código ya visto reaparece (el producto
-- se había contado pero todavía no estaba a la venta, o se había
-- borrado y se vuelve a cargar), el alta de producto se autocompleta
-- y solo queda por completar precio/stock/categoría.
--
-- Excluido de la lectura pública, igual que rent_ledger/stock_count:
-- puede tener precios de productos que todavía no están a la venta.
--
-- Seguro de correr más de una vez.
-- =====================================================================

DROP POLICY IF EXISTS "Public read app settings" ON app_settings;
CREATE POLICY "Public read app settings" ON app_settings
  FOR SELECT USING (setting_key NOT IN ('sub_admins', 'orders_list', 'rent_ledger', 'supplier_debts', 'supplier_checks', 'stock_count', 'barcode_catalog'));

INSERT INTO app_settings (setting_key, setting_value)
SELECT 'barcode_catalog', '{}'
WHERE NOT EXISTS (SELECT 1 FROM app_settings WHERE setting_key = 'barcode_catalog');
