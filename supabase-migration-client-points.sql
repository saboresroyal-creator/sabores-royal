-- =====================================================================
-- Sabores Royal — Puntos Royal persistidos en el servidor
-- =====================================================================
-- Hasta ahora los puntos de cada cliente vivían solo en el localStorage
-- de cada dispositivo: se sumaban con creditPointsToClient() al
-- confirmar un pedido/comprobante y se corregían a mano con
-- editClientPoints(), pero nunca se guardaban en Supabase. Resultado:
-- el mismo cliente tenía puntos distintos en el celu y en la PC, y
-- ninguno de los dos se enteraba de lo que pasaba en el otro.
--
-- Esta migración agrega la columna y dos funciones:
--   - credit_client_points: suma (o resta) puntos de forma atómica,
--     para no perder puntos si dos dispositivos venden al mismo tiempo.
--   - set_client_points: corrección manual desde el admin (pisa el
--     valor en vez de sumar).
--
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE clients ADD COLUMN IF NOT EXISTS points integer NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION credit_client_points(p_phone text, p_delta integer, p_name text DEFAULT NULL)
RETURNS clients
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_client clients;
BEGIN
  UPDATE clients SET points = GREATEST(points + p_delta, 0) WHERE phone = p_phone RETURNING * INTO v_client;
  IF FOUND THEN RETURN v_client; END IF;

  INSERT INTO clients (full_name, phone, points)
  VALUES (COALESCE(NULLIF(p_name,''), 'Cliente'), p_phone, GREATEST(p_delta,0))
  RETURNING * INTO v_client;
  RETURN v_client;
END;
$$;

CREATE OR REPLACE FUNCTION set_client_points(p_phone text, p_points integer)
RETURNS clients
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  UPDATE clients SET points = GREATEST(p_points, 0) WHERE phone = p_phone RETURNING *;
$$;
