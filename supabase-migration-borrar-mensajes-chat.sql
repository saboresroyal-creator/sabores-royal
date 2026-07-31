-- =====================================================================
-- Sabores Royal — Borrar mensajes del chat
-- =====================================================================
-- Permite borrar mensajes individuales del chat:
--  - El admin puede borrar cualquier mensaje (ya tiene acceso total a
--    chat_messages via RLS "Admin full access chat").
--  - El cliente (clave anon, sin login) solo puede borrar SUS PROPIOS
--    mensajes ('sender' = 'client' y el mismo client_phone), a través
--    de esta función RPC — igual que send_chat_message, que ya fuerza
--    sender='client' del lado del servidor.
--
-- Seguro de correr más de una vez.
-- =====================================================================

BEGIN;

CREATE OR REPLACE FUNCTION delete_chat_message(p_phone text, p_id text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  DELETE FROM chat_messages
  WHERE id::text = p_id
    AND client_phone = p_phone
    AND sender = 'client';
END;
$$;

GRANT EXECUTE ON FUNCTION delete_chat_message(text, text) TO anon;

COMMIT;
