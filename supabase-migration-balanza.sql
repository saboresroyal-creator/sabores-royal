-- =====================================================================
-- Sabores Royal — Caja: productos pesables con etiqueta de balanza
-- =====================================================================
-- * products.plu: número de artículo (PLU) que el producto tiene cargado
--   en la balanza. La caja lo saca del código EAN-13 que empieza con 2
--   impreso en la etiqueta (2X + PLU + importe/peso + verificador).
-- * create_pos_sale() / cancel_pos_sale(): las líneas pesables llegan con
--   "grams" y no tocan products.stock (el stock es en unidades enteras y
--   los pesables no lo usan, igual que en la tienda online).
--
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE products ADD COLUMN IF NOT EXISTS plu integer;
CREATE UNIQUE INDEX IF NOT EXISTS products_plu_unique ON products(plu) WHERE plu IS NOT NULL;

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
    -- Pesable vendido por balanza: no descuenta stock en unidades.
    CONTINUE WHEN COALESCE(v_item->>'grams', '') <> '';

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

CREATE OR REPLACE FUNCTION cancel_pos_sale(p_sale_id text)
RETURNS pos_sales
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_sale pos_sales;
  v_item jsonb;
BEGIN
  SELECT * INTO v_sale FROM pos_sales WHERE id = p_sale_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'venta_no_encontrada';
  END IF;

  IF v_sale.status = 'anulada' THEN
    RETURN v_sale; -- ya estaba anulada, no volver a sumar stock
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_sale.items)
  LOOP
    CONTINUE WHEN COALESCE(v_item->>'grams', '') <> '';
    UPDATE products
    SET stock = stock + (v_item->>'qty')::int
    WHERE id = (v_item->>'id')::bigint;
  END LOOP;

  UPDATE pos_sales SET status = 'anulada' WHERE id = p_sale_id
  RETURNING * INTO v_sale;

  RETURN v_sale;
END;
$$;
