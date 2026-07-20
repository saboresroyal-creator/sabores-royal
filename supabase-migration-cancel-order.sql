-- =====================================================================
-- Sabores Royal — Anular pedido (devuelve el stock descontado)
-- =====================================================================
-- Hoy, borrar un pedido no devuelve el stock que create_order() había
-- descontado — el producto queda con menos stock del real para
-- siempre. Este RPC anula el pedido (lo deja como "Cancelado" en vez
-- de borrarlo) y devuelve el stock de los ítems vendidos por unidad
-- (los vendidos por peso/grams nunca descontaron stock, así que no
-- hay nada que devolverles). Solo lo puede llamar un admin, y es
-- seguro llamarlo dos veces: si el pedido ya está Cancelado, no
-- vuelve a sumar stock.
--
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

CREATE OR REPLACE FUNCTION cancel_order(p_order_id text)
RETURNS orders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_order orders;
  v_item  jsonb;
BEGIN
  IF NOT is_admin() THEN
    RAISE EXCEPTION 'no_autorizado';
  END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pedido_no_encontrado';
  END IF;

  IF v_order.status = 'Cancelado' THEN
    RETURN v_order; -- ya estaba anulado, no volver a sumar stock
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_order.items)
  LOOP
    IF (v_item ? 'grams') AND (v_item->>'grams') IS NOT NULL AND (v_item->>'grams') NOT IN ('null','false','0','') THEN
      CONTINUE; -- vendido por peso, nunca descontó stock por unidad
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
