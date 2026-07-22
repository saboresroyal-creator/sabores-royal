-- =====================================================================
-- Sabores Royal — Código de barras por producto
-- =====================================================================
-- Agrega la columna "barcode" a products. No es obligatoria ni única a
-- nivel de base (dos productos podrían coincidir por error de tipeo/
-- escaneo; el front avisa si eso pasa, pero no lo bloquea acá).
--
-- Seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE products ADD COLUMN IF NOT EXISTS barcode text;
CREATE INDEX IF NOT EXISTS products_barcode_idx ON products(barcode);
