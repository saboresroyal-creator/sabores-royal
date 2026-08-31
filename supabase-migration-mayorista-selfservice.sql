-- Alta mayorista autoservicio (/mayorista): columnas nuevas en clients,
-- RPC de registro público, y status inicial configurable en create_order
-- para poder mandar los pedidos mayoristas bajo el mínimo a "Revision"
-- en vez de "Pendiente" (quedan esperando que Matías los habilite a mano).
--
-- Correr en Supabase: Dashboard > SQL Editor > New query > pegar y ejecutar.

ALTER TABLE clients ADD COLUMN IF NOT EXISTS wholesale boolean NOT NULL DEFAULT false;
ALTER TABLE clients ADD COLUMN IF NOT EXISTS rubro text;

-- Backfill: los clientes que ya eran mayoristas por el mecanismo viejo
-- (lista de teléfonos en app_settings.wholesale_clients) pasan a tener
-- la columna real en true, para que ambos caminos queden consistentes.
UPDATE clients c
SET wholesale = true
WHERE c.phone IN (
  SELECT jsonb_array_elements_text(s.setting_value::jsonb)
  FROM app_settings s
  WHERE s.setting_key = 'wholesale_clients'
);

-- RPC pública (SECURITY DEFINER): alta de un comercio como mayorista,
-- auto-aprobado. La llama el sitio público con la anon key, sin sesión
-- de admin — por eso NO toca nada más que este cliente puntual.
CREATE OR REPLACE FUNCTION register_wholesale_client(
  p_phone text,
  p_name  text,
  p_rubro text
) RETURNS clients
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_client clients;
BEGIN
  IF p_phone IS NULL OR length(trim(p_phone)) < 6 THEN
    RAISE EXCEPTION 'telefono_invalido';
  END IF;
  IF p_name IS NULL OR length(trim(p_name)) < 2 THEN
    RAISE EXCEPTION 'nombre_invalido';
  END IF;

  INSERT INTO clients (phone, full_name, rubro, wholesale)
  VALUES (p_phone, p_name, p_rubro, true)
  ON CONFLICT (phone) DO UPDATE
    SET wholesale = true,
        rubro = COALESCE(EXCLUDED.rubro, clients.rubro),
        full_name = COALESCE(clients.full_name, EXCLUDED.full_name)
  RETURNING * INTO v_client;

  RETURN v_client;
END;
$$;

GRANT EXECUTE ON FUNCTION register_wholesale_client(text, text, text) TO anon, authenticated;

-- create_order: nuevo parámetro opcional p_status. Si no se manda (o es
-- NULL), se comporta exactamente igual que antes (status arranca en
-- 'Pendiente'). Los pedidos mayoristas bajo el mínimo lo van a mandar
-- en 'Revision' para que no salgan a producción sin que Matías los mire.
-- Basada al pie de la letra en la versión corregida de
-- supabase-migration-fix-create-order.sql (v_ok como int, no boolean —
-- ese fix era real, no lo toco), sumando únicamente p_status al final.
--
-- IMPORTANTE: en Postgres, CREATE OR REPLACE con una firma de parámetros
-- distinta (acá: +p_status) no reemplaza la función vieja, crea una
-- segunda función en paralelo — y PostgREST después no sabe cuál de las
-- dos usar ("Could not choose the best candidate function"). Por eso
-- primero hay que borrar explícitamente la versión vieja de 8 parámetros.
DROP FUNCTION IF EXISTS create_order(text, text, text, jsonb, numeric, numeric, numeric, text);
CREATE OR REPLACE FUNCTION create_order(
  p_phone           text,
  p_name            text,
  p_address         text,
  p_items           jsonb,
  p_discount_pct    numeric DEFAULT NULL,
  p_discount_amount numeric DEFAULT NULL,
  p_total           numeric DEFAULT 0,
  p_payment_method  text DEFAULT NULL,
  p_status          text DEFAULT NULL
) RETURNS orders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_order   orders;
  v_id      text;
  v_item    jsonb;
  v_ok      int;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'carrito_vacio';
  END IF;

  PERFORM find_or_create_client(p_phone, p_name, p_address, NULL);

  v_id := 'SR' || to_char(now(), 'YYMMDDHH24MISS') || lpad(floor(random()*100)::text, 2, '0');

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF (v_item ? 'grams') AND (v_item->>'grams') IS NOT NULL AND (v_item->>'grams') NOT IN ('null','false','0','') THEN
      CONTINUE;
    END IF;

    UPDATE products
    SET stock = stock - (v_item->>'qty')::int
    WHERE id = (v_item->>'id')::bigint
      AND stock >= (v_item->>'qty')::int;

    GET DIAGNOSTICS v_ok = ROW_COUNT;
    IF v_ok = 0 THEN
      RAISE EXCEPTION 'sin_stock:%', COALESCE(v_item->>'name', v_item->>'id');
    END IF;
  END LOOP;

  INSERT INTO orders (id, client_phone, customer_name, customer_address, items, discount_pct, discount_amount, total, status, payment_method)
  VALUES (v_id, p_phone, p_name, p_address, p_items, p_discount_pct, p_discount_amount, p_total, COALESCE(p_status, 'Pendiente'), p_payment_method)
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;

GRANT EXECUTE ON FUNCTION create_order(text, text, text, jsonb, numeric, numeric, numeric, text, text) TO anon, authenticated;
