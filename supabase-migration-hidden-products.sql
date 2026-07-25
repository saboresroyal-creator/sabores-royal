-- =====================================================================
-- Sabores Royal — Ocultar productos del catálogo de clientes
-- =====================================================================
-- Agrega la columna `hidden` a products: si está en true, el producto
-- sigue existiendo y siendo editable desde el panel de Admin, pero no
-- aparece en el catálogo, en Apto Celíaco, ni en las sugerencias de
-- búsqueda que ve un cliente.
--
-- Seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE products ADD COLUMN IF NOT EXISTS hidden BOOLEAN NOT NULL DEFAULT false;
