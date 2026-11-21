-- =====================================================================
-- Sabores Royal — Precios PC (StarPOS) vs App
-- =====================================================================
-- El sincronizador de la PC de StarPOS ya manda todos los productos cada
-- 15 minutos, pero de los que ya están en la tienda no guardaba nada.
-- Desde ahora guarda su precio de StarPOS en starpos_precios, y el admin
-- los compara con el de la App en la solapa "Precios PC vs App".
-- No cambia nada de la tienda ni del catálogo del local, y no hace falta
-- tocar nada en la PC. Los datos aparecen en la próxima pasada (<= 15 min).
--
-- Incluye todo supabase-migration-sync-starpos.sql (no hace falta correr
-- ese aparte). Seguro de correr más de una vez.
-- =====================================================================

-- ---------- 1) Sincronización StarPOS (igual que supabase-migration-sync-starpos.sql) ----------

-- =====================================================================
-- Sabores Royal — Sincronización automática StarPOS → catálogo del local
-- =====================================================================
-- Un programa chico en la PC de StarPOS (sincronizar-starpos.bat, se baja
-- desde Admin → Catálogo del local) lee cada 15 minutos los productos y
-- precios de StarPOS y los manda acá con starpos_sync_lote():
--   * productos nuevos de StarPOS  → se agregan al catálogo del local;
--   * precios / códigos cambiados  → se actualizan;
--   * si el producto ya está en la tienda (mismo código o PLU) no se toca
--     nada de la tienda: la fila del catálogo queda vinculada y la Caja
--     usa el de la tienda.
--   * los nombres que se corrigieron a mano en el catálogo no se pisan.
-- Cada pasada queda anotada en starpos_sync_log (el admin ve la última).
--
-- El programa se identifica con una clave (token) que se genera acá y que
-- solo el admin puede leer. Aditivo, seguro de correr más de una vez.
-- Requiere supabase-migration-catalogo-local.sql.
-- =====================================================================

CREATE TABLE IF NOT EXISTS starpos_sync_config (
  id     int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  token  text NOT NULL
);
INSERT INTO starpos_sync_config (id, token)
VALUES (1, md5(random()::text || clock_timestamp()::text) || md5(random()::text))
ON CONFLICT (id) DO NOTHING;
ALTER TABLE starpos_sync_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin read starpos sync config" ON starpos_sync_config;
CREATE POLICY "Admin read starpos sync config" ON starpos_sync_config FOR SELECT USING (is_admin());

CREATE TABLE IF NOT EXISTS starpos_sync_log (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  ok          boolean NOT NULL,
  resumen     jsonb,
  error       text
);
ALTER TABLE starpos_sync_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin read starpos sync log" ON starpos_sync_log;
CREATE POLICY "Admin read starpos sync log" ON starpos_sync_log FOR SELECT USING (is_admin());

-- Para que la Caja traiga solo lo que cambió.
CREATE INDEX IF NOT EXISTS catalogo_local_updated_idx ON catalogo_local(updated_at);

-- Nombre "lindo" a partir del de StarPOS (MAYÚSCULAS → Tipo Título, unidades
-- en minúscula). Mismo criterio que se usó en la carga inicial.
CREATE OR REPLACE FUNCTION sr_titulo(n text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  units jsonb := '{"GR":"gr","GRS":"gr","G":"gr","GRAMOS":"gr","KG":"Kg","KGS":"Kg","ML":"ml","M.L":"ml","M.L.":"ml","CC":"cc","L":"L","LT":"L","LTS":"L","UN":"un","UNI":"un","UNID":"un","UNIDADES":"un","U":"un","X":"x","C/U":"c/u"}';
  small text[] := ARRAY['DE','DEL','LA','EL','LOS','LAS','CON','SIN','Y','EN','AL','A','P/','S/','C/'];
  outw text[] := '{}';
  w text; u text; m text[]; i int := 0;
BEGIN
  FOREACH w IN ARRAY regexp_split_to_array(btrim(coalesce(n, '')), '\s+') LOOP
    CONTINUE WHEN w = '';
    u := upper(w);
    IF units ? u THEN
      outw := array_append(outw, units->>u);
    ELSE
      m := regexp_match(u, '^(\d+[.,]?\d*)(GRS|GR|G|KG|ML|CC|L|LT|UN|UNI)$');
      IF m IS NOT NULL THEN
        outw := array_append(outw, m[1] || (units->>m[2]));
      ELSIF i > 0 AND u = ANY(small) THEN
        outw := array_append(outw, lower(w));
      ELSIF w ~ '\d' OR (length(w) <= 2 AND w !~ '^[[:alpha:]]+$') THEN
        outw := array_append(outw, w);
      ELSE
        outw := array_append(outw, upper(left(w, 1)) || lower(substr(w, 2)));
      END IF;
    END IF;
    i := i + 1;
  END LOOP;
  RETURN array_to_string(outw, ' ');
END;
$$;

CREATE OR REPLACE FUNCTION sr_codigo(c text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(ltrim(regexp_replace(coalesce(c, ''), '\D', '', 'g'), '0'), '')
$$;

-- Recibe un lote de productos de StarPOS (hasta ~500 por llamada).
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
    SELECT id, sr_codigo(barcode) AS c FROM products WHERE sr_codigo(barcode) IS NOT NULL
    UNION ALL
    SELECT id, sr_codigo(display_barcode) FROM products WHERE sr_codigo(display_barcode) IS NOT NULL;

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
    coalesce(
      (SELECT a.id FROM _sp_app a WHERE a.c = cc.main OR a.c = ANY(cc.unidades) LIMIT 1),
      (SELECT p.id FROM products p WHERE cc.plu_n IS NOT NULL AND p.plu = cc.plu_n LIMIT 1)
    ) AS app_id
  FROM cc;

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

  RETURN jsonb_build_object('recibidos', v_recibidos, 'nuevos', v_nuevos, 'precios', v_precios,
                            'vinculados', v_vinc, 'cambios', v_cambios);
END;
$$;

-- Al terminar cada pasada (o si falló), el programa deja anotado el resultado.
CREATE OR REPLACE FUNCTION starpos_sync_registrar(p_token text, p_ok boolean, p_resumen jsonb, p_error text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM starpos_sync_config WHERE id = 1 AND token = p_token) THEN
    RAISE EXCEPTION 'token_invalido';
  END IF;
  INSERT INTO starpos_sync_log (ok, resumen, error) VALUES (p_ok, p_resumen, left(p_error, 2000));
  DELETE FROM starpos_sync_log WHERE id < (SELECT max(id) - 500 FROM starpos_sync_log);
END;
$$;


-- ---------- 2) Precios PC vs App ----------

CREATE TABLE IF NOT EXISTS starpos_precios (
  starpos_id       text PRIMARY KEY,
  product_id       bigint NOT NULL,        -- producto de la tienda con el mismo código o PLU
  nombre           text,                   -- nombre en StarPOS
  barcode          text,
  plu              int,
  precio           numeric(14,2) NOT NULL DEFAULT 0,   -- final, por kilo si por_peso
  precio_antes     numeric(14,2),          -- precio anterior en StarPOS (último cambio)
  precio_cantidad  numeric(14,2),
  cantidad_min     int,
  por_peso         boolean NOT NULL DEFAULT false,
  updated_at       timestamptz NOT NULL DEFAULT now(), -- cuándo cambió el precio en StarPOS
  visto            timestamptz NOT NULL DEFAULT now()  -- última pasada que lo trajo
);
CREATE INDEX IF NOT EXISTS starpos_precios_product_idx ON starpos_precios(product_id);
ALTER TABLE starpos_precios ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON starpos_precios FROM anon;
DROP POLICY IF EXISTS "Admin lee starpos precios" ON starpos_precios;
CREATE POLICY "Admin lee starpos precios" ON starpos_precios FOR SELECT USING (is_admin());
GRANT SELECT ON starpos_precios TO authenticated;

-- Misma función de siempre + el bloque de starpos_precios al final.
-- Recibe un lote de productos de StarPOS (hasta ~500 por llamada).
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
    SELECT id, sr_codigo(barcode) AS c FROM products WHERE sr_codigo(barcode) IS NOT NULL
    UNION ALL
    SELECT id, sr_codigo(display_barcode) FROM products WHERE sr_codigo(display_barcode) IS NOT NULL;

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
    coalesce(
      (SELECT a.id FROM _sp_app a WHERE a.c = cc.main OR a.c = ANY(cc.unidades) LIMIT 1),
      (SELECT p.id FROM products p WHERE cc.plu_n IS NOT NULL AND p.plu = cc.plu_n LIMIT 1)
    ) AS app_id
  FROM cc;

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
                               cantidad_min, por_peso, updated_at, visto)
  SELECT starpos_id, app_id, nombre_original, barcode, plu, precio, precio_cantidad,
         cantidad_min, por_peso, now(), now()
  FROM _sp WHERE app_id IS NOT NULL
  ON CONFLICT (starpos_id) DO UPDATE SET
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
