-- =====================================================================
-- Sabores Royal — Corregir el bug real de "no se guardan los pedidos"
-- =====================================================================
-- create_order() declaraba v_ok como boolean, pero GET DIAGNOSTICS
-- v_ok = ROW_COUNT le asigna un número, y después se comparaba
-- "v_ok = 0" — comparar boolean contra integer no es válido en
-- Postgres, así que la función tiraba error CADA VEZ que un pedido
-- tenía al menos un producto vendido por unidad (no por peso). Por eso
-- fallaba con pedidos normales pero no con productos "x kg".
--
-- El pedido igual se mandaba por WhatsApp como red de contención, pero
-- nunca quedaba guardado en el servidor (ni descontaba stock, ni
-- aparecía en el panel admin, ni disparaba la notificación).
--
-- Fix: v_ok pasa a ser int, que es lo que realmente devuelve ROW_COUNT.
-- Aditivo (CREATE OR REPLACE), seguro de correr más de una vez.
-- =====================================================================

CREATE OR REPLACE FUNCTION create_order(
  p_phone           text,
  p_name            text,
  p_address         text,
  p_items           jsonb,
  p_discount_pct    numeric DEFAULT NULL,
  p_discount_amount numeric DEFAULT NULL,
  p_total           numeric DEFAULT 0,
  p_payment_method  text DEFAULT NULL
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

  INSERT INTO orders (id, client_phone, customer_name, customer_address, items, discount_pct, discount_amount, total, payment_method)
  VALUES (v_id, p_phone, p_name, p_address, p_items, p_discount_pct, p_discount_amount, p_total, p_payment_method)
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;
