-- =====================================================================
-- Sabores Royal — Código de barras de la caja/display
-- =====================================================================
-- Agrega "display_barcode" a products: el código de la caja cerrada,
-- distinto al código de la unidad suelta (columna "barcode").
--
-- Seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE products ADD COLUMN IF NOT EXISTS display_barcode text;
CREATE INDEX IF NOT EXISTS products_display_barcode_idx ON products(display_barcode);
