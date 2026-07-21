-- =====================================================================
-- Sabores Royal — Pedidos a proveedores (dentro del Comparador)
-- =====================================================================
-- Agrega:
--   1) columna "phone" a cmp_proveedores, para poder armar el link de
--      WhatsApp del pedido (si no se carga, se cae al número propio de
--      la tienda, como ya hace "Enviar lista de precios").
--   2) tabla cmp_pedidos: un pedido generado desde la pestaña "Pedidos"
--      del Comparador para un proveedor puntual, con sus items (jsonb),
--      total y estado (pendiente / enviado / recibido).
--
-- Mismo patrón de seguridad que products/clients/orders (ver
-- supabase-migration-2026.sql): RLS habilitado, acceso solo para admins
-- autenticados. Se usa is_super_admin() porque la pestaña "Comparador"
-- ya está oculta para sub-admins en el front-end (solo el superadmin la
-- ve). Si tus políticas existentes en cmp_proveedores/cmp_listas usan
-- is_admin() en lugar de is_super_admin(), cambiá la función acá abajo
-- para que quede consistente.
--
-- Corré esto en el SQL Editor de Supabase ANTES de usar "Pedidos" en el
-- Comparador. Si no lo corrés, vas a poder seguir comparando precios
-- normalmente, pero guardar un proveedor con teléfono o generar un
-- pedido va a fallar con un error claro pidiendo la columna/tabla.
-- =====================================================================

ALTER TABLE cmp_proveedores ADD COLUMN IF NOT EXISTS phone text;

CREATE TABLE IF NOT EXISTS cmp_pedidos (
  id text PRIMARY KEY,
  prov_id text NOT NULL REFERENCES cmp_proveedores(id) ON DELETE CASCADE,
  items jsonb NOT NULL DEFAULT '[]'::jsonb,
  total numeric NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'pendiente',
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS cmp_pedidos_prov_id_idx ON cmp_pedidos(prov_id);
CREATE INDEX IF NOT EXISTS cmp_pedidos_created_at_idx ON cmp_pedidos(created_at DESC);

ALTER TABLE cmp_pedidos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Super admin full access cmp_pedidos" ON cmp_pedidos;
CREATE POLICY "Super admin full access cmp_pedidos" ON cmp_pedidos
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());
