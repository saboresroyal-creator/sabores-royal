-- =====================================================================
-- Sabores Royal — Punto de Venta: clientes, anular venta, Cierre X/Z
-- =====================================================================
-- Fase 4 de caja-venta.html: buscar/crear clientes desde el mostrador,
-- anular una venta (devuelve stock, no borra el registro), y Cierre de
-- lote X (resumen sin guardar) / Z (resumen que se guarda y arranca un
-- período nuevo). No hay impresora fiscal todavía, así que el Cierre Z
-- es "de sistema" — no reemplaza un cierre Z fiscal real ante AFIP.
--
-- caja-venta.html sigue sin sesión de Supabase Auth (PIN de cajero nada
-- más, mismo criterio que caja-diaria.html), así que estas funciones son
-- SECURITY DEFINER alcanzables con la clave anon, igual que
-- create_pos_sale() ya lo es.
--
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

-- ── CLIENTES: buscar por nombre o teléfono ──────────────────────────
CREATE OR REPLACE FUNCTION search_clients(p_query text)
RETURNS SETOF clients
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM clients
  WHERE phone ILIKE '%'||p_query||'%' OR full_name ILIKE '%'||p_query||'%'
  ORDER BY full_name
  LIMIT 20;
$$;

-- ── ANULAR VENTA: devuelve el stock, marca "anulada" (no borra) ─────
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
    UPDATE products
    SET stock = stock + (v_item->>'qty')::int
    WHERE id = (v_item->>'id')::bigint;
  END LOOP;

  UPDATE pos_sales SET status = 'anulada' WHERE id = p_sale_id
  RETURNING * INTO v_sale;

  RETURN v_sale;
END;
$$;

-- ── CIERRE X / Z: registro de cierres de caja ───────────────────────
CREATE TABLE IF NOT EXISTS pos_closures (
  id            text PRIMARY KEY,
  caja          text NOT NULL,
  cajero        text,
  period_start  timestamptz NOT NULL,
  period_end    timestamptz NOT NULL,
  total         numeric NOT NULL,
  sale_count    int NOT NULL,
  by_payment    jsonb NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS pos_closures_caja_idx ON pos_closures(caja, period_end);

ALTER TABLE pos_closures ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read pos closures" ON pos_closures;
CREATE POLICY "Public read pos closures" ON pos_closures FOR SELECT USING (true);

DROP POLICY IF EXISTS "Admin write pos closures" ON pos_closures;
CREATE POLICY "Admin write pos closures" ON pos_closures FOR ALL USING (is_admin()) WITH CHECK (is_admin());

-- El "período abierto" de una caja son las ventas no anuladas desde su
-- último Cierre Z (o desde siempre, si nunca cerró uno). Cierre X en el
-- front consulta pos_sales directo con ese mismo criterio, sin guardar
-- nada — solo Cierre Z llama a esta función, que sí persiste el resumen
-- y corre el piso del próximo período hasta "ahora".
CREATE OR REPLACE FUNCTION close_pos_batch(p_caja text, p_cajero text)
RETURNS pos_closures
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_start   timestamptz;
  v_end     timestamptz := now();
  v_total   numeric;
  v_count   int;
  v_by_pay  jsonb;
  v_closure pos_closures;
BEGIN
  SELECT COALESCE(MAX(period_end), '2000-01-01'::timestamptz) INTO v_start
  FROM pos_closures WHERE caja = p_caja;

  SELECT COALESCE(SUM(total),0), COUNT(*)
  INTO v_total, v_count
  FROM pos_sales
  WHERE caja = p_caja AND status <> 'anulada' AND created_at > v_start AND created_at <= v_end;

  SELECT COALESCE(jsonb_object_agg(payment_method, info), '{}'::jsonb)
  INTO v_by_pay
  FROM (
    SELECT payment_method, jsonb_build_object('total', SUM(total), 'cant', COUNT(*)) AS info
    FROM pos_sales
    WHERE caja = p_caja AND status <> 'anulada' AND created_at > v_start AND created_at <= v_end
    GROUP BY payment_method
  ) t;

  INSERT INTO pos_closures (id, caja, cajero, period_start, period_end, total, sale_count, by_payment)
  VALUES (
    'LZ' || to_char(now(), 'YYMMDDHH24MISS') || lpad(floor(random()*100)::text, 2, '0'),
    p_caja, p_cajero, v_start, v_end, v_total, v_count, v_by_pay
  )
  RETURNING * INTO v_closure;

  RETURN v_closure;
END;
$$;
