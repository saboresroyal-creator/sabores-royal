-- =====================================================================
-- Sabores Royal — Cajas navideñas (solapa "Cajas Navideñas" del admin)
-- =====================================================================
-- Una fila por artículo, modelo de caja o pedido. Así dos personas pueden
-- cargar pedidos distintos a la vez sin pisarse.
-- Costos, precios y lo que debe cada cliente: solo lo leen y escriben los
-- administradores (is_admin()). La tienda no tiene acceso.
--
-- Seguro de correr más de una vez.
-- =====================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS navidad_docs (
  id          text PRIMARY KEY,
  tipo        text NOT NULL CHECK (tipo IN ('articulo','modelo','pedido')),
  data        jsonb NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE navidad_docs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin navidad_docs" ON navidad_docs;
CREATE POLICY "Admin navidad_docs" ON navidad_docs
  FOR ALL USING (is_admin()) WITH CHECK (is_admin());

COMMIT;
