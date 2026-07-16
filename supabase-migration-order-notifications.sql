-- =====================================================================
-- Sabores Royal — Notificación push de pedidos nuevos (vía ntfy.sh)
-- =====================================================================
-- Cada vez que se inserta una fila en `orders` (un cliente confirma un
-- pedido), este trigger manda un POST a ntfy.sh, que le llega como
-- notificación push al celu del admin — sin depender de tener la app
-- abierta ni de WhatsApp.
--
-- Requiere:
--  1) Instalar la app "ntfy" (Android/iOS) o abrir https://ntfy.sh/app
--     en el navegador y suscribirse ahí.
--  2) Suscribirse al tema (canal) que se usa acá abajo — es un nombre
--     largo y aleatorio a propósito, tratalo como una contraseña:
--     cualquiera que lo sepa puede ver tus notificaciones de pedidos.
--
-- El texto del aviso va todo en headers (no en el body, que en pg_net
-- es jsonb y mandaría el texto entre comillas) — es el uso estándar
-- documentado de ntfy para publicar por HTTP.
--
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

-- pg_net permite hacer llamadas HTTP desde una función/trigger de Postgres.
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION notify_new_order()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_qty numeric;
BEGIN
  SELECT COALESCE(sum((item->>'qty')::numeric), 0) INTO v_qty
  FROM jsonb_array_elements(NEW.items) AS item;

  PERFORM net.http_post(
    url := 'https://ntfy.sh/sabores-royal-pedidos-13f559350aa4',
    headers := jsonb_build_object(
      'Title', 'Nuevo pedido - Sabores Royal',
      'Message', NEW.customer_name || ' - $' || round(NEW.total)::text || ' (' || v_qty::int || ' items)',
      'Priority', 'urgent',
      'Tags', 'shopping_cart'
    ),
    body := '{}'::jsonb
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_new_order ON orders;
CREATE TRIGGER trg_notify_new_order
  AFTER INSERT ON orders
  FOR EACH ROW EXECUTE FUNCTION notify_new_order();
