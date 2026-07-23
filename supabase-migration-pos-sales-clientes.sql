-- =====================================================================
-- Sabores Royal — Punto de Venta: vincular cliente a la venta (opcional)
-- =====================================================================
-- Fase 2 de caja-venta.html: permite cargar el teléfono (y nombre) del
-- cliente al cobrar. No es obligatorio — la mayoría de las ventas de
-- mostrador siguen siendo anónimas.
--
-- Reusa find_or_create_client() (la misma función que ya usa
-- create_order() para pedidos online), así un cliente que compra en el
-- local y por WhatsApp queda vinculado por el mismo teléfono.
--
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE pos_sales ADD COLUMN IF NOT EXISTS client_phone text;
ALTER TABLE pos_sales ADD COLUMN IF NOT EXISTS client_name text;

CREATE OR REPLACE FUNCTION create_pos_sale(
  p_caja            text,
  p_cajero          text,
  p_items           jsonb,
  p_subtotal        numeric,
  p_total           numeric,
  p_payment_method  text,
  p_client_phone    text DEFAULT NULL,
  p_client_name     text DEFAULT NULL
) RETURNS pos_sales
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_sale  pos_sales;
  v_id    text;
  v_item  jsonb;
  v_ok    int;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'carrito_vacio';
  END IF;

  IF COALESCE(p_client_phone, '') <> '' THEN
    PERFORM find_or_create_client(p_client_phone, p_client_name, NULL, NULL);
  END IF;

  v_id := 'CJ' || to_char(now(), 'YYMMDDHH24MISS') || lpad(floor(random()*100)::text, 2, '0');

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    UPDATE products
    SET stock = stock - (v_item->>'qty')::int
    WHERE id = (v_item->>'id')::bigint
      AND stock >= (v_item->>'qty')::int;

    GET DIAGNOSTICS v_ok = ROW_COUNT;
    IF v_ok = 0 THEN
      RAISE EXCEPTION 'sin_stock:%', COALESCE(v_item->>'name', v_item->>'id');
    END IF;
  END LOOP;

  INSERT INTO pos_sales (id, caja, cajero, items, subtotal, total, payment_method, client_phone, client_name)
  VALUES (v_id, p_caja, p_cajero, p_items, p_subtotal, p_total, p_payment_method, NULLIF(p_client_phone,''), NULLIF(p_client_name,''))
  RETURNING * INTO v_sale;

  RETURN v_sale;
END;
$$;
