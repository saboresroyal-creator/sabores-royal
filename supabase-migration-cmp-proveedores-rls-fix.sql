-- =====================================================================
-- Sabores Royal — Arreglo de RLS en Comparador (cmp_proveedores / cmp_listas)
-- =====================================================================
-- Al intentar guardar un proveedor nuevo desde el panel admin, Supabase
-- devuelve: "new row violates row-level security policy for table
-- cmp_proveedores". Los proveedores que ya estaban cargados se insertaron
-- directo en Supabase (con la service role, que ignora RLS), así que el
-- camino de "guardar desde la app" con la sesión del superadmin nunca se
-- había probado — y a la tabla le falta (o le quedó mal) la policy que
-- permite insertar/actualizar.
--
-- Esto crea (o reemplaza) una policy permisiva igual a la de cmp_pedidos:
-- solo el superadmin puede leer/escribir. Es seguro correrlo aunque ya
-- exista alguna policy con otro nombre — las policies "FOR ALL" son
-- permisivas (se combinan con OR), así que esto no rompe nada existente,
-- solo agrega el permiso que falta.
--
-- Corré esto en el SQL Editor de Supabase.
-- =====================================================================

ALTER TABLE cmp_proveedores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Super admin full access cmp_proveedores" ON cmp_proveedores;
CREATE POLICY "Super admin full access cmp_proveedores" ON cmp_proveedores
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

ALTER TABLE cmp_listas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Super admin full access cmp_listas" ON cmp_listas;
CREATE POLICY "Super admin full access cmp_listas" ON cmp_listas
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());
