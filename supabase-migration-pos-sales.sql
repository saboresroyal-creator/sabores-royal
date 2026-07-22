-- =====================================================================
-- Sabores Royal — Punto de Venta (venta de mostrador)
-- =====================================================================
-- Fase 0 del sistema de caja: registra las ventas hechas en el mostrador
-- (public/caja-venta.html) y descuenta el mismo stock que usa
-- Admin Productos / la tienda online, con el mismo patrón atómico que ya
-- usa create_order() para pedidos.
--
-- caja-venta.html es una pantalla standalone sin login de Supabase Auth
-- (mismo criterio que caja_diaria_data: el cajero se identifica por PIN,
-- no por sesión). Por eso create_pos_sale() es SECURITY DEFINER y queda
-- alcanzable con la clave anon, igual que create_order(). El PIN es solo
-- trazabilidad, no el límite de seguridad real.
--
-- Seguro de correr más de una vez.
-- =====================================================================

CREATE TABLE IF NOT EXISTS pos_sales (
  id              text PRIMARY KEY,
  caja            text NOT NULL,
  cajero          text,
  items           jsonb NOT NULL,
  subtotal        numeric NOT NULL,
  total           numeric NOT NULL,
  payment_method  text NOT NULL,
  status          text NOT NULL DEFAULT 'completada',
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS pos_sales_created_idx ON pos_sales(created_at);

ALTER TABLE pos_sales ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read pos sales" ON pos_sales;
CREATE POLICY "Public read pos sales" ON pos_sales FOR SELECT USING (true);

DROP POLICY IF EXISTS "Admin write pos sales" ON pos_sales;
CREATE POLICY "Admin write pos sales" ON pos_sales FOR ALL USING (is_admin()) WITH CHECK (is_admin());

CREATE OR REPLACE FUNCTION create_pos_sale(
  p_caja            text,
  p_cajero          text,
  p_items           jsonb,
  p_subtotal        numeric,
  p_total           numeric,
  p_payment_method  text
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

  INSERT INTO pos_sales (id, caja, cajero, items, subtotal, total, payment_method)
  VALUES (v_id, p_caja, p_cajero, p_items, p_subtotal, p_total, p_payment_method)
  RETURNING * INTO v_sale;

  RETURN v_sale;
END;
$$;

-- Config de cajeros/PIN (public/caja-venta.html + Admin > Configuración).
-- Lectura pública ya cubierta por la policy existente "Public read app
-- settings" (es de exclusión, no de inclusión). Escritura ya cubierta por
-- "Admin write app settings" (is_admin(), ya existente para toda la tabla).
-- Se precargan los mismos nombres que ya usa Caja Diaria (state.cajeros en
-- caja-diaria.html) con un PIN por defecto "0000" — cambiarlo desde
-- Admin > Configuración antes de usar la caja en serio.
INSERT INTO app_settings (setting_key, setting_value)
VALUES ('pos_config', '{"cajeros":[{"nombre":"Gastón","pin":"0000"},{"nombre":"Matías","pin":"0000"},{"nombre":"Gabriel","pin":"0000"},{"nombre":"Emanuel","pin":"0000"}]}')
ON CONFLICT (setting_key) DO NOTHING;
