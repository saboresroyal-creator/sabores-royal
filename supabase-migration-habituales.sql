-- =====================================================================
-- Sabores Royal — Mis habituales del cliente en todos sus dispositivos
-- =====================================================================
-- La lista automática sale de los pedidos. Esta tabla guarda solo lo que
-- el cliente agrega o quita a mano. Igual que get_my_orders, se accede por
-- teléfono mediante funciones: la tabla no se lee directo.
--
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

CREATE TABLE IF NOT EXISTS client_habituales (
  phone text PRIMARY KEY,
  added jsonb NOT NULL DEFAULT '[]'::jsonb,
  hidden jsonb NOT NULL DEFAULT '[]'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE client_habituales ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION get_my_habituales(p_phone text)
RETURNS SETOF client_habituales
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM client_habituales WHERE phone = p_phone;
$$;

CREATE OR REPLACE FUNCTION save_my_habituales(p_phone text, p_added jsonb, p_hidden jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  IF length(p_phone) > 20
    OR jsonb_typeof(p_added) <> 'array' OR jsonb_array_length(p_added) > 500
    OR jsonb_typeof(p_hidden) <> 'array' OR jsonb_array_length(p_hidden) > 500 THEN
    RAISE EXCEPTION 'habituales_invalidos';
  END IF;

  INSERT INTO client_habituales (phone, added, hidden, updated_at)
  VALUES (p_phone, p_added, p_hidden, now())
  ON CONFLICT (phone) DO UPDATE
    SET added = EXCLUDED.added, hidden = EXCLUDED.hidden, updated_at = now();
END;
$$;

GRANT EXECUTE ON FUNCTION get_my_habituales(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION save_my_habituales(text, jsonb, jsonb) TO anon, authenticated;
