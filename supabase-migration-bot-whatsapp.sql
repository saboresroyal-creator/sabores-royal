-- =====================================================================
-- Sabores Royal — Bot de WhatsApp (clientes + modo dueño)
-- =====================================================================
-- Tablas que usa /api/whatsapp (public/api/whatsapp.js):
--   bot_conversations: una fila por teléfono. Guarda el historial de la
--     charla con Claude, si el bot está pausado para ese chat (porque
--     Matías tomó la conversación a mano) y las acciones del modo dueño
--     que esperan un "sí".
--   bot_inbox: cada mensaje que entra por el webhook. El id es el id de
--     WhatsApp, así si Meta reenvía el mismo mensaje (lo hace cuando
--     tarda la respuesta) no se contesta dos veces.
--
-- Todo esto lo lee/escribe SOLO el servidor con la service_role key: RLS
-- activado y sin policies = nadie con la anon key puede verlo.
--
-- Aditivo, seguro de correr más de una vez.
-- Correr en Supabase: Dashboard > SQL Editor > New query > pegar y ejecutar.
-- =====================================================================

CREATE TABLE IF NOT EXISTS bot_conversations (
  phone            text PRIMARY KEY,            -- formato +549...
  wa_id            text,                        -- como lo manda WhatsApp (549...), para responder
  name             text,                        -- nombre de perfil de WhatsApp
  history          jsonb NOT NULL DEFAULT '[]'::jsonb,
  session_context  text,                        -- datos del cliente + info del negocio, fijos durante la sesión
  session_started  timestamptz,
  last_message_at  timestamptz,
  paused_until     timestamptz,                 -- bot callado en este chat hasta esta hora
  pending_actions  jsonb NOT NULL DEFAULT '[]'::jsonb,
  locked_until     timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bot_inbox (
  id           text PRIMARY KEY,               -- id del mensaje de WhatsApp (wamid...)
  phone        text NOT NULL,
  type         text NOT NULL,
  body         text,
  received_at  timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);
CREATE INDEX IF NOT EXISTS bot_inbox_pending_idx ON bot_inbox(phone, received_at) WHERE processed_at IS NULL;

ALTER TABLE bot_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE bot_inbox ENABLE ROW LEVEL SECURITY;

-- Toma el "turno" de un chat: si dos mensajes del mismo cliente llegan
-- casi juntos, Vercel los procesa en dos funciones a la vez. Solo una
-- consigue el lock; la otra se va y la primera contesta los dos mensajes
-- juntos. El lock vence solo (por si la función se cae a mitad).
CREATE OR REPLACE FUNCTION bot_try_lock(p_phone text, p_seconds int DEFAULT 90)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_ok int;
BEGIN
  INSERT INTO bot_conversations (phone) VALUES (p_phone) ON CONFLICT (phone) DO NOTHING;
  UPDATE bot_conversations
  SET locked_until = now() + make_interval(secs => p_seconds)
  WHERE phone = p_phone AND (locked_until IS NULL OR locked_until < now());
  GET DIAGNOSTICS v_ok = ROW_COUNT;
  RETURN v_ok > 0;
END;
$$;

CREATE OR REPLACE FUNCTION bot_unlock(p_phone text)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  UPDATE bot_conversations SET locked_until = NULL WHERE phone = p_phone;
$$;

-- Igual que cancel_order() pero sin el chequeo is_admin(): el bot llama
-- con la service_role key (no hay usuario logueado, así que is_admin()
-- da false). Por eso NO se le da permiso a anon/authenticated.
CREATE OR REPLACE FUNCTION bot_cancel_order(p_order_id text)
RETURNS orders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_order orders;
  v_item  jsonb;
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pedido_no_encontrado';
  END IF;

  IF v_order.status = 'Cancelado' THEN
    RETURN v_order;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_order.items)
  LOOP
    IF (v_item ? 'grams') AND (v_item->>'grams') IS NOT NULL AND (v_item->>'grams') NOT IN ('null','false','0','') THEN
      CONTINUE;
    END IF;
    UPDATE products
    SET stock = stock + (v_item->>'qty')::int
    WHERE id = (v_item->>'id')::bigint;
  END LOOP;

  UPDATE orders SET status = 'Cancelado' WHERE id = p_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;

REVOKE ALL ON FUNCTION bot_try_lock(text, int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION bot_unlock(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION bot_cancel_order(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION bot_try_lock(text, int) TO service_role;
GRANT EXECUTE ON FUNCTION bot_unlock(text) TO service_role;
GRANT EXECUTE ON FUNCTION bot_cancel_order(text) TO service_role;

-- Texto libre con la info del negocio que el bot les da a los clientes
-- (horarios, envíos, medios de pago...). Se edita mandándole al bot desde
-- el número del dueño algo como "cambiá el horario a ...".
INSERT INTO app_settings (setting_key, setting_value)
VALUES ('bot_info', 'Sabores Royal — golosinas, dietética y almacén.
Dirección: Maipú 734, Rosario.
Transferencias al alias SABORES.ROYAL.MAIPU.
Venta mayorista para comercios: pedido mínimo $50.000.
Catálogo online: https://sabores-royal.vercel.app — mayoristas: https://sabores-royal.vercel.app/mayorista
(Completar: horarios de atención, zonas y costo de envío, medios de pago aceptados.)')
ON CONFLICT (setting_key) DO NOTHING;
