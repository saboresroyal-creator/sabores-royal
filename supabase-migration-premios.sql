-- =====================================================================
-- Sabores Royal — Catálogo de premios (canje de Puntos Royal)
-- =====================================================================
-- El catálogo vive en app_settings.rewards (JSON, lectura pública y
-- escritura admin, igual que novedades/ofertas):
--   [{ "id":"r123", "name":"Alfajor", "desc":"", "points":500,
--      "photo":"https://...", "active":true }]
--
-- Cada canje queda en reward_redemptions con un código corto que el
-- cliente muestra en el local. El costo en puntos se lee SIEMPRE del
-- catálogo guardado en el servidor (nunca del celular), y el descuento
-- de puntos se hace con la fila del cliente bloqueada, así dos canjes
-- simultáneos no pueden dejar el saldo en negativo.
--
-- Requiere supabase-migration-2026.sql (is_admin) y
-- supabase-migration-client-points.sql (clients.points).
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS reward_redemptions (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         text NOT NULL UNIQUE,
  client_phone text NOT NULL,
  client_name  text,
  reward_id    text NOT NULL,
  reward_name  text NOT NULL,
  points       integer NOT NULL,
  status       text NOT NULL DEFAULT 'pendiente' CHECK (status IN ('pendiente','entregado','cancelado')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  resolved_at  timestamptz
);
CREATE INDEX IF NOT EXISTS reward_redemptions_phone_idx ON reward_redemptions (client_phone, created_at DESC);

ALTER TABLE reward_redemptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin full access reward_redemptions" ON reward_redemptions;
CREATE POLICY "Admin full access reward_redemptions" ON reward_redemptions
  FOR ALL USING (is_admin()) WITH CHECK (is_admin());

-- Canjear un premio como cliente.
CREATE OR REPLACE FUNCTION redeem_reward(p_phone text, p_reward_id text)
RETURNS reward_redemptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_reward jsonb;
  v_cost   integer;
  v_client clients;
  v_code   text;
  v_row    reward_redemptions;
BEGIN
  SELECT r.item INTO v_reward
  FROM app_settings s, jsonb_array_elements(s.setting_value::jsonb) AS r(item)
  WHERE s.setting_key = 'rewards' AND r.item->>'id' = p_reward_id
  LIMIT 1;
  IF v_reward IS NULL OR COALESCE((v_reward->>'active')::boolean, true) = false THEN
    RAISE EXCEPTION 'premio_no_disponible';
  END IF;
  v_cost := (v_reward->>'points')::integer;
  IF v_cost IS NULL OR v_cost <= 0 THEN
    RAISE EXCEPTION 'premio_no_disponible';
  END IF;

  SELECT * INTO v_client FROM clients WHERE phone = p_phone FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cliente_no_encontrado';
  END IF;
  IF COALESCE(v_client.points,0) < v_cost THEN
    RAISE EXCEPTION 'puntos_insuficientes';
  END IF;

  UPDATE clients SET points = points - v_cost WHERE phone = p_phone;

  -- Código corto sin letras confundibles (sin 0/O, 1/I).
  LOOP
    v_code := '';
    FOR i IN 1..5 LOOP
      v_code := v_code || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random()*32)::int, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM reward_redemptions WHERE code = v_code);
  END LOOP;

  INSERT INTO reward_redemptions (code, client_phone, client_name, reward_id, reward_name, points)
  VALUES (v_code, p_phone, v_client.full_name, p_reward_id, v_reward->>'name', v_cost)
  RETURNING * INTO v_row;
  RETURN v_row;
END;
$$;

-- Últimos canjes de un cliente (para "Mis canjes" en la app).
CREATE OR REPLACE FUNCTION client_reward_redemptions(p_phone text)
RETURNS SETOF reward_redemptions
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM reward_redemptions WHERE client_phone = p_phone ORDER BY created_at DESC LIMIT 20;
$$;

-- Cancelar un canje pendiente (solo admin): devuelve los puntos.
CREATE OR REPLACE FUNCTION admin_cancel_reward_redemption(p_id bigint)
RETURNS reward_redemptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_row reward_redemptions;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'solo_admin'; END IF;
  UPDATE reward_redemptions SET status = 'cancelado', resolved_at = now()
  WHERE id = p_id AND status = 'pendiente'
  RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'canje_no_pendiente'; END IF;
  UPDATE clients SET points = points + v_row.points WHERE phone = v_row.client_phone;
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION redeem_reward(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION client_reward_redemptions(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin_cancel_reward_redemption(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION redeem_reward(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION client_reward_redemptions(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_cancel_reward_redemption(bigint) TO authenticated;

COMMIT;
