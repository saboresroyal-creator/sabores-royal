-- =====================================================================
-- Sabores Royal — Migración de seguridad 2026 (Parte B)
-- =====================================================================
-- Copia los pedidos existentes desde el blob JSON viejo
-- (app_settings.setting_key = 'orders_list') hacia la tabla `orders`
-- nueva, una fila por pedido. NO borra el blob viejo (queda de
-- respaldo). Es seguro correrlo más de una vez: los pedidos que ya
-- estén migrados se saltean (ON CONFLICT DO NOTHING).
-- =====================================================================

DO $$
DECLARE
  v_blob  jsonb;
  v_order jsonb;
BEGIN
  SELECT setting_value::jsonb INTO v_blob
  FROM app_settings WHERE setting_key = 'orders_list';

  IF v_blob IS NULL THEN
    RAISE NOTICE 'No hay orders_list guardado — nada para migrar.';
    RETURN;
  END IF;

  FOR v_order IN SELECT * FROM jsonb_array_elements(v_blob)
  LOOP
    INSERT INTO orders (
      id, client_phone, customer_name, customer_address,
      items, discount_pct, discount_amount, total, status, created_at
    )
    VALUES (
      v_order->>'id',
      COALESCE(v_order->'customer'->>'phone', 'desconocido'),
      COALESCE(v_order->'customer'->>'name', 'Cliente'),
      v_order->'customer'->>'address',
      COALESCE(v_order->'items', '[]'::jsonb),
      NULLIF(v_order->>'clientDiscountPct', '')::numeric,
      NULLIF(v_order->>'clientDiscountAmount', '')::numeric,
      COALESCE((v_order->>'total')::numeric, 0),
      COALESCE(v_order->>'status', 'Pendiente'),
      COALESCE((v_order->>'date')::timestamptz, now())
    )
    ON CONFLICT (id) DO NOTHING;
  END LOOP;
END $$;

-- Verificación: cuántos pedidos quedaron en la tabla nueva
SELECT count(*) AS pedidos_migrados FROM orders;
