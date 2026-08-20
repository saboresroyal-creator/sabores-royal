-- =====================================================================
-- Sabores Royal — Vínculos manuales de productos (dentro del Comparador)
-- =====================================================================
-- Agrega la tabla cmp_links: permite marcar a mano que una fila de un
-- proveedor y una fila de otro proveedor son "el mismo producto",
-- para los casos donde el matching automático por texto no puede
-- adivinarlo (nombres abreviados sin correspondencia clara, ej. "SA"
-- vs "60%CACAO"). Un vínculo manual tiene prioridad absoluta sobre el
-- matching automático: no se re-evalúa por similitud de nombre ni por
-- el gate de precio por unidad.
--
-- Modelo: cada fila de cmp_links es UN producto de UN proveedor que
-- pertenece a un grupo (group_id). Todas las filas que comparten el
-- mismo group_id se muestran juntas en la tabla de "Comparar",
-- reemplazando lo que hubiera decidido el algoritmo automático para
-- esas filas puntuales.
--
-- La identidad de una fila entre reimportaciones es (prov_id, norm) —
-- no hay un ID estable por fila en cmp_listas (reimportar reemplaza la
-- lista entera). Es la misma clave que ya usa el matching automático,
-- así que si el proveedor cambia el texto del nombre en una lista
-- nueva, el vínculo deja de aplicar silenciosamente (mismo
-- comportamiento que ya tiene el auto-match ante un cambio de texto).
--
-- Mismo patrón de seguridad que cmp_pedidos (ver
-- supabase-migration-cmp-pedidos.sql): RLS habilitado, solo superadmin.
--
-- Corré esto en el SQL Editor de Supabase antes de usar "vincular
-- producto" en el Comparador. Si no lo corrés, el resto del comparador
-- sigue andando normal, pero vincular un producto va a fallar con un
-- error claro pidiendo la tabla.
-- =====================================================================

CREATE TABLE IF NOT EXISTS cmp_links (
  id text PRIMARY KEY,
  group_id text NOT NULL,
  prov_id text NOT NULL REFERENCES cmp_proveedores(id) ON DELETE CASCADE,
  norm text NOT NULL,
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS cmp_links_group_id_idx ON cmp_links(group_id);
CREATE UNIQUE INDEX IF NOT EXISTS cmp_links_prov_norm_idx ON cmp_links(prov_id, norm);

ALTER TABLE cmp_links ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Super admin full access cmp_links" ON cmp_links;
CREATE POLICY "Super admin full access cmp_links" ON cmp_links
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());
