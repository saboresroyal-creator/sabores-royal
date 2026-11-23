-- =====================================================================
-- Sabores Royal — Precios PC vs App: arreglos (23/11/2026)
-- =====================================================================
--  * Distingue cómo coincidió cada producto de StarPOS con el de la tienda:
--    por el código de la unidad, por PLU o por el código de la CAJA cerrada.
--    Si fue por la caja, el admin compara contra el precio de la caja
--    (precio unitario x cantidad de la caja), no contra una unidad.
--  * "No es el mismo producto": el admin puede sacar un par de la
--    comparación (cuando un código está mal cargado en un sistema).
-- Requiere supabase-migration-precios-pc-vs-app.sql. Seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE starpos_precios ADD COLUMN IF NOT EXISTS via text;
ALTER TABLE starpos_precios ADD COLUMN IF NOT EXISTS ignorado boolean NOT NULL DEFAULT false;
GRANT UPDATE (ignorado) ON starpos_precios TO authenticated;
DROP POLICY IF EXISTS "Admin marca starpos precios" ON starpos_precios;
CREATE POLICY "Admin marca starpos precios" ON starpos_precios FOR UPDATE USING (is_admin()) WITH CHECK (is_admin());

CREATE OR REPLACE FUNCTION starpos_sync_lote(p_token text, p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_nuevos int; v_precios int; v_vinc int; v_cambios jsonb; v_recibidos int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM starpos_sync_config WHERE id = 1 AND token = p_token) THEN
    RAISE EXCEPTION 'token_invalido';
  END IF;

  -- Códigos de la tienda (unidad y caja cerrada) y PLU.
  CREATE TEMP TABLE _sp_app ON COMMIT DROP AS
    SELECT id, sr_codigo(barcode) AS c, false AS caja FROM products WHERE sr_codigo(barcode) IS NOT NULL
    UNION ALL
    SELECT id, sr_codigo(display_barcode), true FROM products WHERE sr_codigo(display_barcode) IS NOT NULL;

  CREATE TEMP TABLE _sp ON COMMIT DROP AS
  WITH r AS (
    SELECT DISTINCT ON (x.id) x.*
    FROM jsonb_to_recordset(p_rows) AS x(id text, ref text, code text, tipo text, nombre text, cat text,
         marca text, iva text, precio text, precio2 text, qmin text, codigos text, uv text)
    WHERE coalesce(x.id, '') <> ''
  ), b AS (
    SELECT r.*,
      coalesce(r.tipo, '') IN ('SCALE', 'SCALE_WEIGHT', 'SCALE_UNITS')
        AND coalesce(r.code, '') ~ '^[0-9]{1,6}$' AS es_plu,
      coalesce(r.tipo, '') IN ('SCALE', 'SCALE_WEIGHT') AS peso,
      round(coalesce(NULLIF(r.precio, '')::numeric, 0), 2) AS pr,
      round(NULLIF(r.precio2, '')::numeric, 2) AS pr2,
      NULLIF(r.qmin, '')::numeric AS qm
    FROM r
  ), cc AS (
    SELECT b.*,
      CASE WHEN es_plu THEN NULL ELSE sr_codigo(b.code) END AS main,
      CASE WHEN es_plu THEN b.code::int END AS plu_n,
      (SELECT coalesce(array_agg(DISTINCT sr_codigo(split_part(e, ':', 1))), '{}')
         FROM unnest(string_to_array(NULLIF(b.codigos, ''), '|')) e
        WHERE sr_codigo(split_part(e, ':', 1)) IS NOT NULL
          AND coalesce(NULLIF(split_part(e, ':', 2), ''), '1')::numeric = 1) AS unidades,
      (SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object('codigo', sr_codigo(split_part(e, ':', 1)),
                                                            'cantidad', split_part(e, ':', 2)::numeric)), '[]'::jsonb)
         FROM unnest(string_to_array(NULLIF(b.codigos, ''), '|')) e
        WHERE sr_codigo(split_part(e, ':', 1)) IS NOT NULL
          AND coalesce(NULLIF(split_part(e, ':', 2), ''), '1')::numeric > 1) AS packs_j
    FROM b
  )
  SELECT cc.id AS starpos_id, coalesce(cc.ref, '') AS referencia, cc.nombre AS nombre_original,
    sr_titulo(cc.nombre) AS nombre, cc.main AS barcode,
    (SELECT coalesce(jsonb_agg(u), '[]'::jsonb) FROM unnest(cc.unidades) u WHERE u IS DISTINCT FROM cc.main) AS codigos,
    cc.packs_j AS packs,
    CASE WHEN coalesce(cc.cat, '') = '' THEN 'Otros' ELSE sr_titulo(cc.cat) END AS categoria,
    CASE WHEN coalesce(cc.marca, '') = '' THEN NULL ELSE sr_titulo(cc.marca) END AS marca,
    cc.pr AS precio,
    CASE WHEN cc.pr2 IS NOT NULL AND cc.qm IS NOT NULL AND cc.pr2 < cc.pr THEN cc.pr2 END AS precio_cantidad,
    CASE WHEN cc.pr2 IS NOT NULL AND cc.qm IS NOT NULL AND cc.pr2 < cc.pr THEN cc.qm::int END AS cantidad_min,
    cc.peso AS por_peso, cc.plu_n AS plu,
    coalesce(NULLIF(cc.iva, '')::numeric, 0.21) AS iva,
    NULLIF(cc.uv, '')::date AS ultima_venta,
    m.app_id, m.via
  FROM cc
  LEFT JOIN LATERAL (
    -- Primero el código de la unidad, después el PLU y por último el código de la caja cerrada.
    SELECT x.id AS app_id, x.via FROM (
      SELECT a.id, 'codigo' AS via, 1 AS ord FROM _sp_app a WHERE NOT a.caja AND (a.c = cc.main OR a.c = ANY(cc.unidades))
      UNION ALL
      SELECT p.id, 'plu', 2 FROM products p WHERE cc.plu_n IS NOT NULL AND p.plu = cc.plu_n
      UNION ALL
      SELECT a.id, 'caja', 3 FROM _sp_app a WHERE a.caja AND (a.c = cc.main OR a.c = ANY(cc.unidades))
    ) x ORDER BY x.ord LIMIT 1
  ) m ON true;

  SELECT count(*) INTO v_recibidos FROM _sp;

  -- Ya está en la tienda: se vincula (la Caja usa el de la tienda).
  UPDATE catalogo_local cl SET product_id = s.app_id, updated_at = now()
  FROM _sp s WHERE cl.starpos_id = s.starpos_id AND cl.product_id IS NULL AND s.app_id IS NOT NULL;
  GET DIAGNOSTICS v_vinc = ROW_COUNT;

  SELECT count(*) INTO v_nuevos FROM _sp s
  WHERE s.app_id IS NULL AND NOT EXISTS (SELECT 1 FROM catalogo_local cl WHERE cl.starpos_id = s.starpos_id);

  SELECT count(*),
         coalesce(jsonb_agg(jsonb_build_object('nombre', x.nombre, 'antes', x.antes, 'ahora', x.ahora)) FILTER (WHERE x.rn <= 40), '[]'::jsonb)
    INTO v_precios, v_cambios
  FROM (SELECT cl.nombre, cl.precio AS antes, s.precio AS ahora, row_number() OVER (ORDER BY cl.nombre) AS rn
          FROM catalogo_local cl JOIN _sp s ON s.starpos_id = cl.starpos_id
         WHERE cl.product_id IS NULL AND s.app_id IS NULL AND cl.precio IS DISTINCT FROM s.precio) x;

  INSERT INTO catalogo_local (starpos_id, referencia, nombre, nombre_original, barcode, codigos, packs, categoria, marca,
                              precio, precio_cantidad, cantidad_min, por_peso, plu, iva, ultima_venta)
  SELECT starpos_id, referencia, nombre, nombre_original, barcode, codigos, packs, categoria, marca,
         precio, precio_cantidad, cantidad_min, por_peso, plu, iva, ultima_venta
  FROM _sp WHERE app_id IS NULL
  ON CONFLICT (starpos_id) DO UPDATE SET
    referencia = EXCLUDED.referencia, nombre_original = EXCLUDED.nombre_original, barcode = EXCLUDED.barcode,
    codigos = EXCLUDED.codigos, packs = EXCLUDED.packs, categoria = EXCLUDED.categoria, marca = EXCLUDED.marca,
    precio = EXCLUDED.precio, precio_cantidad = EXCLUDED.precio_cantidad, cantidad_min = EXCLUDED.cantidad_min,
    por_peso = EXCLUDED.por_peso, plu = EXCLUDED.plu, iva = EXCLUDED.iva,
    ultima_venta = greatest(EXCLUDED.ultima_venta, catalogo_local.ultima_venta),
    updated_at = now()
  WHERE catalogo_local.product_id IS NULL
    AND (catalogo_local.referencia, catalogo_local.nombre_original, catalogo_local.barcode, catalogo_local.codigos,
         catalogo_local.packs, catalogo_local.categoria, catalogo_local.marca, catalogo_local.precio,
         catalogo_local.precio_cantidad, catalogo_local.cantidad_min, catalogo_local.por_peso, catalogo_local.plu,
         catalogo_local.iva)
        IS DISTINCT FROM
        (EXCLUDED.referencia, EXCLUDED.nombre_original, EXCLUDED.barcode, EXCLUDED.codigos,
         EXCLUDED.packs, EXCLUDED.categoria, EXCLUDED.marca, EXCLUDED.precio,
         EXCLUDED.precio_cantidad, EXCLUDED.cantidad_min, EXCLUDED.por_peso, EXCLUDED.plu, EXCLUDED.iva)
    -- la fecha de última venta sola no dispara una actualización (para que la Caja no recargue de más)
    ;

  -- La última venta se guarda aparte, sin tocar updated_at.
  UPDATE catalogo_local cl SET ultima_venta = s.ultima_venta
  FROM _sp s WHERE cl.starpos_id = s.starpos_id AND s.ultima_venta IS NOT NULL
    AND (cl.ultima_venta IS NULL OR cl.ultima_venta < s.ultima_venta);

  -- Precios de StarPOS de los productos que YA están en la tienda, para
  -- compararlos en Admin -> Precios PC vs App (no se toca la tienda).
  INSERT INTO starpos_precios (starpos_id, product_id, nombre, barcode, plu, precio, precio_cantidad,
                               cantidad_min, por_peso, via, updated_at, visto)
  SELECT starpos_id, app_id, nombre_original, barcode, plu, precio, precio_cantidad,
         cantidad_min, por_peso, via, now(), now()
  FROM _sp WHERE app_id IS NOT NULL
  ON CONFLICT (starpos_id) DO UPDATE SET
    -- si pasa a coincidir con otro producto de la tienda, se vuelve a mostrar
    ignorado = CASE WHEN starpos_precios.product_id IS DISTINCT FROM EXCLUDED.product_id THEN false ELSE starpos_precios.ignorado END,
    via = EXCLUDED.via,
    product_id = EXCLUDED.product_id, nombre = EXCLUDED.nombre, barcode = EXCLUDED.barcode, plu = EXCLUDED.plu,
    precio_cantidad = EXCLUDED.precio_cantidad, cantidad_min = EXCLUDED.cantidad_min, por_peso = EXCLUDED.por_peso,
    precio_antes = CASE WHEN starpos_precios.precio IS DISTINCT FROM EXCLUDED.precio THEN starpos_precios.precio ELSE starpos_precios.precio_antes END,
    updated_at   = CASE WHEN starpos_precios.precio IS DISTINCT FROM EXCLUDED.precio THEN now() ELSE starpos_precios.updated_at END,
    precio = EXCLUDED.precio,
    visto = now();
  -- Si dejó de coincidir con un producto de la tienda, sale de la comparación.
  DELETE FROM starpos_precios WHERE starpos_id IN (SELECT starpos_id FROM _sp WHERE app_id IS NULL);

  RETURN jsonb_build_object('recibidos', v_recibidos, 'nuevos', v_nuevos, 'precios', v_precios,
                            'vinculados', v_vinc, 'cambios', v_cambios);
END;
$$;
