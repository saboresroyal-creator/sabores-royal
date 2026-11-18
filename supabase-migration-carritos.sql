-- =====================================================================
-- Sabores Royal — Carritos guardados en el servidor
-- =====================================================================
-- El carrito de la app de clientes vivía solo en el navegador. Si el
-- navegador borraba los datos (navegador interno de WhatsApp/Instagram,
-- Safari que limpia, entrar por otro link o dominio, otro celular), el
-- cliente volvía y tenía que armar el pedido de cero.
--
-- Ahora cada carrito se guarda también acá (por dispositivo y, si el
-- cliente ya se identificó, por teléfono), se recupera solo si el del
-- navegador está vacío, y el admin lo ve en la solapa "Carritos".
--
-- Los clientes solo escriben y leen a través de las dos funciones de
-- abajo; leer la tabla entera es solo para el admin.
--
-- Seguro de correr más de una vez.
-- =====================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS carritos (
  device_id   text PRIMARY KEY,
  phone       text,
  nombre      text,
  items       jsonb NOT NULL DEFAULT '[]'::jsonb,
  unidades    numeric NOT NULL DEFAULT 0,
  total       numeric(14,2) NOT NULL DEFAULT 0,
  estado      text NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto','comprado','vaciado')),
  dominio     text,
  creado      timestamptz NOT NULL DEFAULT now(),
  actualizado timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS carritos_actualizado ON carritos (actualizado DESC);
CREATE INDEX IF NOT EXISTS carritos_phone ON carritos (phone);

ALTER TABLE carritos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON carritos FROM anon;
DROP POLICY IF EXISTS "Admin lee carritos" ON carritos;
CREATE POLICY "Admin lee carritos" ON carritos FOR SELECT USING (is_admin());
DROP POLICY IF EXISTS "Admin borra carritos" ON carritos;
CREATE POLICY "Admin borra carritos" ON carritos FOR DELETE USING (is_admin());
GRANT SELECT, DELETE ON carritos TO authenticated;

-- Guarda el carrito de un dispositivo. El device_id es un código al azar
-- que genera cada navegador (no se puede adivinar el de otro).
CREATE OR REPLACE FUNCTION guardar_carrito(p_device text, p_phone text, p_nombre text, p_items jsonb, p_unidades numeric, p_total numeric, p_estado text, p_dominio text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_device IS NULL OR length(p_device) NOT BETWEEN 20 AND 64 THEN RAISE EXCEPTION 'device inválido'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) > 300 OR length(p_items::text) > 60000 THEN
    RAISE EXCEPTION 'carrito inválido';
  END IF;
  IF p_estado NOT IN ('abierto','comprado','vaciado') THEN p_estado := 'abierto'; END IF;
  INSERT INTO carritos (device_id, phone, nombre, items, unidades, total, estado, dominio, actualizado)
  VALUES (p_device, nullif(left(p_phone, 30), ''), nullif(left(p_nombre, 120), ''), p_items, coalesce(p_unidades, 0), coalesce(p_total, 0), p_estado, left(p_dominio, 80), now())
  ON CONFLICT (device_id) DO UPDATE SET
    phone = coalesce(EXCLUDED.phone, carritos.phone),
    nombre = coalesce(EXCLUDED.nombre, carritos.nombre),
    items = EXCLUDED.items, unidades = EXCLUDED.unidades, total = EXCLUDED.total,
    estado = EXCLUDED.estado, dominio = EXCLUDED.dominio, actualizado = now(),
    creado = CASE WHEN carritos.estado <> 'abierto' AND EXCLUDED.estado = 'abierto' THEN now() ELSE carritos.creado END;
  -- Si compró, los otros carritos abiertos con su teléfono (otro celular,
  -- otro navegador) también quedan como comprados.
  IF p_estado = 'comprado' AND nullif(p_phone, '') IS NOT NULL THEN
    UPDATE carritos SET estado = 'comprado', actualizado = now() WHERE phone = p_phone AND estado = 'abierto' AND device_id <> p_device;
  END IF;
  -- Limpieza: lo que no se tocó en 60 días.
  DELETE FROM carritos WHERE actualizado < now() - interval '60 days';
END $$;

-- Devuelve el último carrito abierto (de los últimos 14 días) de este
-- dispositivo o, si el cliente ya se identificó, de su teléfono.
CREATE OR REPLACE FUNCTION traer_carrito(p_device text, p_phone text)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT items FROM carritos
   WHERE estado = 'abierto' AND jsonb_array_length(items) > 0 AND actualizado > now() - interval '14 days'
     AND ((p_device IS NOT NULL AND length(p_device) >= 20 AND device_id = p_device)
          OR (nullif(p_phone, '') IS NOT NULL AND phone = p_phone))
   ORDER BY (device_id = p_device) DESC, actualizado DESC
   LIMIT 1;
$$;

REVOKE ALL ON FUNCTION guardar_carrito(text, text, text, jsonb, numeric, numeric, text, text), traer_carrito(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION guardar_carrito(text, text, text, jsonb, numeric, numeric, text, text), traer_carrito(text, text) TO anon, authenticated;

COMMIT;
