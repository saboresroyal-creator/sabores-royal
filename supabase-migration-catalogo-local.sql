-- =====================================================================
-- Sabores Royal — Catálogo del local (productos traídos de StarPOS)
-- =====================================================================
-- Todos los productos activos de StarPOS que todavía no están en la App.
-- Viven en una tabla aparte de `products` para que la tienda online no los
-- descargue (son ~6.600 y la tienda guarda el catálogo en el celular de
-- cada cliente). La Caja los usa para cobrar; el admin los ve y los
-- "activa" cuando quiere que pasen a la tienda (se crean en products y
-- acá queda anotado en product_id).
--
-- También ajusta create_pos_sale() y cancel_pos_sale():
--  * las líneas del catálogo del local (src = 'local') no tocan stock;
--  * en la caja una venta ya no se frena por stock en cero o negativo:
--    el producto está físicamente en el mostrador (igual que StarPOS).
--    La tienda online (create_order) sigue controlando stock como antes.
--
-- Aditivo, seguro de correr más de una vez. Después correr los 4 archivos
-- supabase-catalogo-local-datos-1..4.sql, en orden.
-- =====================================================================

CREATE TABLE IF NOT EXISTS catalogo_local (
  id                 bigserial PRIMARY KEY,
  starpos_id         text UNIQUE NOT NULL,
  referencia         text,
  nombre             text NOT NULL,
  nombre_original    text,
  barcode            text,
  codigos            jsonb NOT NULL DEFAULT '[]'::jsonb,  -- otros códigos de la misma unidad
  packs              jsonb NOT NULL DEFAULT '[]'::jsonb,  -- [{codigo, cantidad}] códigos de caja/bulto
  categoria          text,
  marca              text,
  precio             numeric(14,2) NOT NULL DEFAULT 0,    -- final con IVA (por kilo si por_peso)
  precio_cantidad    numeric(14,2),                       -- precio unitario llevando cantidad_min o más
  cantidad_min       int,
  por_peso           boolean NOT NULL DEFAULT false,
  plu                int,
  iva                numeric(6,4),
  ultima_venta       date,
  posible_duplicado  bigint,                              -- id de products que parece ser el mismo
  product_id         bigint,                              -- cuando se activa en la tienda
  oculto_caja        boolean NOT NULL DEFAULT false,      -- para sacarlo también de la caja
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS catalogo_local_barcode_idx ON catalogo_local(barcode);
CREATE INDEX IF NOT EXISTS catalogo_local_plu_idx ON catalogo_local(plu);

ALTER TABLE catalogo_local ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Public read catalogo local" ON catalogo_local;
CREATE POLICY "Public read catalogo local" ON catalogo_local FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admin write catalogo local" ON catalogo_local;
CREATE POLICY "Admin write catalogo local" ON catalogo_local FOR ALL USING (is_admin()) WITH CHECK (is_admin());

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
    -- Pesable por balanza o producto del catálogo del local: no toca stock.
    CONTINUE WHEN COALESCE(v_item->>'grams', '') <> '';
    CONTINUE WHEN COALESCE(v_item->>'src', '') = 'local';
    CONTINUE WHEN COALESCE(v_item->>'id', '') !~ '^[0-9]+$';

    UPDATE products
    SET stock = stock - (v_item->>'qty')::numeric
    WHERE id = (v_item->>'id')::bigint;
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
    CONTINUE WHEN COALESCE(v_item->>'src', '') = 'local';
    CONTINUE WHEN COALESCE(v_item->>'id', '') !~ '^[0-9]+$';
    UPDATE products
    SET stock = stock + (v_item->>'qty')::numeric
    WHERE id = (v_item->>'id')::bigint;
  END LOOP;

  UPDATE pos_sales SET status = 'anulada' WHERE id = p_sale_id
  RETURNING * INTO v_sale;

  RETURN v_sale;
END;
$$;
