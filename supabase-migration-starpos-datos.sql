-- =====================================================================
-- Sabores Royal — Datos de StarPOS en el Admin (solapa "StarPOS")
-- =====================================================================
-- El sincronizador de la PC del local, además de productos y precios,
-- manda ventas, turnos (cierres), anulaciones, retiros y stock.
-- Solo lectura: no se cambia nada en StarPOS. Solo el admin puede leerlo.
--   * starpos_turnos / _turno_medios: cada turno de caja (POS001 mañana,
--     POS002 tarde) con totales y por medio de pago. Todo el historial.
--   * starpos_ventas_hora / _ventas_medio: ventas por día (fecha del ticket),
--     hora, caja y medio de pago. Todo el historial.
--   * starpos_ventas_prod: unidades y $ por producto y por día (120 días).
--   * starpos_tickets / _ticket_lineas: tickets con detalle (20 días).
--   * starpos_anulaciones, starpos_retiros: todo el historial.
--   * starpos_stock: stock actual según StarPOS (se manda una vez por hora).
-- Las fechas son la hora local del local (como las guarda StarPOS).
-- Requiere supabase-migration-sync-starpos.sql. Seguro de correr más de una vez.
-- =====================================================================

CREATE TABLE IF NOT EXISTS starpos_turnos (
  money       text PRIMARY KEY,
  caja        text,
  numero      int,
  inicio      timestamp,
  fin         timestamp,
  cajeros     text,
  tickets     int NOT NULL DEFAULT 0,
  total       numeric(14,2) NOT NULL DEFAULT 0,
  retiros     numeric(14,2) NOT NULL DEFAULT 0,
  anulados    int NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS starpos_turnos_inicio_idx ON starpos_turnos(inicio);

CREATE TABLE IF NOT EXISTS starpos_turno_medios (
  money  text NOT NULL,
  medio  text NOT NULL,
  total  numeric(14,2) NOT NULL DEFAULT 0,
  cant   int NOT NULL DEFAULT 0,
  PRIMARY KEY (money, medio)
);

CREATE TABLE IF NOT EXISTS starpos_ventas_hora (
  fecha    date NOT NULL,
  hora     int NOT NULL,
  caja     text NOT NULL DEFAULT '',
  total    numeric(14,2) NOT NULL DEFAULT 0,
  tickets  int NOT NULL DEFAULT 0,
  PRIMARY KEY (fecha, hora, caja)
);

CREATE TABLE IF NOT EXISTS starpos_ventas_medio (
  fecha  date NOT NULL,
  caja   text NOT NULL DEFAULT '',
  medio  text NOT NULL,
  total  numeric(14,2) NOT NULL DEFAULT 0,
  cant   int NOT NULL DEFAULT 0,
  PRIMARY KEY (fecha, caja, medio)
);

CREATE TABLE IF NOT EXISTS starpos_ventas_prod (
  fecha       date NOT NULL,
  starpos_id  text NOT NULL,
  nombre      text,
  unidades    numeric(14,3) NOT NULL DEFAULT 0,
  total       numeric(14,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (fecha, starpos_id)
);

CREATE TABLE IF NOT EXISTS starpos_tickets (
  id       text PRIMARY KEY,
  fecha    timestamp NOT NULL,
  money    text,
  caja     text,
  cajero   text,
  numero   int,
  tipo     int NOT NULL DEFAULT 0,      -- 0 venta, 1 devolución
  total    numeric(14,2) NOT NULL DEFAULT 0,
  medios   text                          -- "EFECTIVO:1500.00|VISA:2000.00"
);
CREATE INDEX IF NOT EXISTS starpos_tickets_fecha_idx ON starpos_tickets(fecha);

CREATE TABLE IF NOT EXISTS starpos_ticket_lineas (
  ticket       text NOT NULL,
  linea        int NOT NULL,
  descripcion  text,
  unidades     numeric(14,3) NOT NULL DEFAULT 0,
  total        numeric(14,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (ticket, linea)
);

CREATE TABLE IF NOT EXISTS starpos_anulaciones (
  id       text PRIMARY KEY,
  fecha    timestamp NOT NULL,
  caja     text,
  cajero   text,
  numero   int,
  total    numeric(14,2) NOT NULL DEFAULT 0,
  items    int NOT NULL DEFAULT 0,
  detalle  text
);
CREATE INDEX IF NOT EXISTS starpos_anulaciones_fecha_idx ON starpos_anulaciones(fecha);

CREATE TABLE IF NOT EXISTS starpos_retiros (
  id           text PRIMARY KEY,
  fecha        timestamp NOT NULL,
  caja         text,
  cajero       text,
  tipo         text,                    -- '2' retiro, '1' ingreso
  monto        numeric(14,2) NOT NULL DEFAULT 0,  -- positivo = sale plata de la caja
  descripcion  text
);
CREATE INDEX IF NOT EXISTS starpos_retiros_fecha_idx ON starpos_retiros(fecha);

CREATE TABLE IF NOT EXISTS starpos_stock (
  starpos_id  text PRIMARY KEY,
  nombre      text,
  unidades    numeric(14,3) NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Solo el admin lee; escribe únicamente el sincronizador (función de abajo).
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['starpos_turnos','starpos_turno_medios','starpos_ventas_hora','starpos_ventas_medio','starpos_ventas_prod',
                           'starpos_tickets','starpos_ticket_lineas','starpos_anulaciones','starpos_retiros','starpos_stock']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON %I FROM anon', t);
    EXECUTE format('GRANT SELECT ON %I TO authenticated', t);
    EXECUTE format('DROP POLICY IF EXISTS "Admin lee %s" ON %I', t, t);
    EXECUTE format('CREATE POLICY "Admin lee %s" ON %I FOR SELECT USING (is_admin())', t, t);
  END LOOP;
END $$;

-- Recibe un lote de datos de StarPOS de un tipo. Todos los valores llegan como texto.
CREATE OR REPLACE FUNCTION starpos_sync_datos(p_token text, p_tipo text, p_rows jsonb)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE n int := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM starpos_sync_config WHERE id = 1 AND token = p_token) THEN
    RAISE EXCEPTION 'token_invalido';
  END IF;

  IF p_tipo = 'turnos' THEN
    INSERT INTO starpos_turnos (money, caja, numero, inicio, fin, cajeros, tickets, total, retiros, anulados, updated_at)
    SELECT money, caja, NULLIF(numero,'')::int, NULLIF(inicio,'')::timestamp, NULLIF(fin,'')::timestamp, NULLIF(cajeros,''),
           coalesce(NULLIF(tickets,'')::int,0), coalesce(NULLIF(total,'')::numeric,0), coalesce(NULLIF(retiros,'')::numeric,0),
           coalesce(NULLIF(anulados,'')::int,0), now()
    FROM jsonb_to_recordset(p_rows) AS x(money text, caja text, numero text, inicio text, fin text, cajeros text,
                                         tickets text, total text, retiros text, anulados text)
    WHERE coalesce(money,'') <> ''
    ON CONFLICT (money) DO UPDATE SET caja = EXCLUDED.caja, numero = EXCLUDED.numero, inicio = EXCLUDED.inicio,
      fin = EXCLUDED.fin, cajeros = EXCLUDED.cajeros, tickets = EXCLUDED.tickets, total = EXCLUDED.total,
      retiros = EXCLUDED.retiros, anulados = EXCLUDED.anulados, updated_at = now();

  ELSIF p_tipo = 'medios' THEN
    INSERT INTO starpos_turno_medios (money, medio, total, cant)
    SELECT money, medio, coalesce(NULLIF(total,'')::numeric,0), coalesce(NULLIF(cant,'')::int,0)
    FROM jsonb_to_recordset(p_rows) AS x(money text, medio text, total text, cant text)
    WHERE coalesce(money,'') <> '' AND coalesce(medio,'') <> ''
    ON CONFLICT (money, medio) DO UPDATE SET total = EXCLUDED.total, cant = EXCLUDED.cant;

  ELSIF p_tipo = 'vhoras' THEN
    INSERT INTO starpos_ventas_hora (fecha, hora, caja, total, tickets)
    SELECT fecha::date, hora::int, coalesce(caja,''), coalesce(NULLIF(total,'')::numeric,0), coalesce(NULLIF(tickets,'')::int,0)
    FROM jsonb_to_recordset(p_rows) AS x(fecha text, hora text, caja text, total text, tickets text)
    WHERE coalesce(fecha,'') <> '' AND coalesce(hora,'') <> ''
    ON CONFLICT (fecha, hora, caja) DO UPDATE SET total = EXCLUDED.total, tickets = EXCLUDED.tickets;

  ELSIF p_tipo = 'vmedios' THEN
    INSERT INTO starpos_ventas_medio (fecha, caja, medio, total, cant)
    SELECT fecha::date, coalesce(caja,''), medio, coalesce(NULLIF(total,'')::numeric,0), coalesce(NULLIF(cant,'')::int,0)
    FROM jsonb_to_recordset(p_rows) AS x(fecha text, caja text, medio text, total text, cant text)
    WHERE coalesce(fecha,'') <> '' AND coalesce(medio,'') <> ''
    ON CONFLICT (fecha, caja, medio) DO UPDATE SET total = EXCLUDED.total, cant = EXCLUDED.cant;

  ELSIF p_tipo = 'prod' THEN
    INSERT INTO starpos_ventas_prod (fecha, starpos_id, nombre, unidades, total)
    SELECT fecha::date, id, nombre, coalesce(NULLIF(unidades,'')::numeric,0), coalesce(NULLIF(total,'')::numeric,0)
    FROM jsonb_to_recordset(p_rows) AS x(fecha text, id text, nombre text, unidades text, total text)
    WHERE coalesce(id,'') <> '' AND coalesce(fecha,'') <> ''
    ON CONFLICT (fecha, starpos_id) DO UPDATE SET nombre = EXCLUDED.nombre, unidades = EXCLUDED.unidades, total = EXCLUDED.total;
    DELETE FROM starpos_ventas_prod WHERE fecha < current_date - 120;

  ELSIF p_tipo = 'tickets' THEN
    INSERT INTO starpos_tickets (id, fecha, money, caja, cajero, numero, tipo, total, medios)
    SELECT id, fecha::timestamp, money, caja, cajero, NULLIF(numero,'')::int, coalesce(NULLIF(tipo,'')::int,0),
           coalesce(NULLIF(total,'')::numeric,0), NULLIF(medios,'')
    FROM jsonb_to_recordset(p_rows) AS x(id text, fecha text, money text, caja text, cajero text, numero text,
                                         tipo text, total text, medios text)
    WHERE coalesce(id,'') <> '' AND coalesce(fecha,'') <> ''
    ON CONFLICT (id) DO UPDATE SET fecha = EXCLUDED.fecha, money = EXCLUDED.money, caja = EXCLUDED.caja,
      cajero = EXCLUDED.cajero, numero = EXCLUDED.numero, tipo = EXCLUDED.tipo, total = EXCLUDED.total, medios = EXCLUDED.medios;
    DELETE FROM starpos_ticket_lineas WHERE ticket IN (SELECT id FROM starpos_tickets WHERE fecha < current_date - 20);
    DELETE FROM starpos_tickets WHERE fecha < current_date - 20;

  ELSIF p_tipo = 'lineas' THEN
    INSERT INTO starpos_ticket_lineas (ticket, linea, descripcion, unidades, total)
    SELECT ticket, linea::int, descripcion, coalesce(NULLIF(unidades,'')::numeric,0), coalesce(NULLIF(total,'')::numeric,0)
    FROM jsonb_to_recordset(p_rows) AS x(ticket text, linea text, descripcion text, unidades text, total text)
    WHERE coalesce(ticket,'') <> '' AND coalesce(linea,'') <> ''
    ON CONFLICT (ticket, linea) DO UPDATE SET descripcion = EXCLUDED.descripcion, unidades = EXCLUDED.unidades, total = EXCLUDED.total;
    GET DIAGNOSTICS n = ROW_COUNT;
    DELETE FROM starpos_ticket_lineas l WHERE NOT EXISTS (SELECT 1 FROM starpos_tickets t WHERE t.id = l.ticket);
    RETURN n;

  ELSIF p_tipo = 'anulaciones' THEN
    INSERT INTO starpos_anulaciones (id, fecha, caja, cajero, numero, total, items, detalle)
    SELECT id, fecha::timestamp, caja, cajero, NULLIF(numero,'')::int, coalesce(NULLIF(total,'')::numeric,0),
           coalesce(NULLIF(items,'')::int,0), NULLIF(detalle,'')
    FROM jsonb_to_recordset(p_rows) AS x(id text, fecha text, caja text, cajero text, numero text, total text, items text, detalle text)
    WHERE coalesce(id,'') <> '' AND coalesce(fecha,'') <> ''
    ON CONFLICT (id) DO UPDATE SET fecha = EXCLUDED.fecha, caja = EXCLUDED.caja, cajero = EXCLUDED.cajero,
      numero = EXCLUDED.numero, total = EXCLUDED.total, items = EXCLUDED.items, detalle = EXCLUDED.detalle;

  ELSIF p_tipo = 'retiros' THEN
    INSERT INTO starpos_retiros (id, fecha, caja, cajero, tipo, monto, descripcion)
    SELECT id, fecha::timestamp, caja, cajero, tipo, coalesce(NULLIF(monto,'')::numeric,0), NULLIF(descripcion,'')
    FROM jsonb_to_recordset(p_rows) AS x(id text, fecha text, caja text, cajero text, tipo text, monto text, descripcion text)
    WHERE coalesce(id,'') <> '' AND coalesce(fecha,'') <> ''
    ON CONFLICT (id) DO UPDATE SET fecha = EXCLUDED.fecha, caja = EXCLUDED.caja, cajero = EXCLUDED.cajero,
      tipo = EXCLUDED.tipo, monto = EXCLUDED.monto, descripcion = EXCLUDED.descripcion;

  ELSIF p_tipo = 'stock' THEN
    INSERT INTO starpos_stock (starpos_id, nombre, unidades, updated_at)
    SELECT id, nombre, coalesce(NULLIF(unidades,'')::numeric,0), now()
    FROM jsonb_to_recordset(p_rows) AS x(id text, nombre text, unidades text)
    WHERE coalesce(id,'') <> ''
    ON CONFLICT (starpos_id) DO UPDATE SET nombre = EXCLUDED.nombre, unidades = EXCLUDED.unidades, updated_at = now()
    WHERE starpos_stock.unidades IS DISTINCT FROM EXCLUDED.unidades OR starpos_stock.nombre IS DISTINCT FROM EXCLUDED.nombre;

  ELSE
    RAISE EXCEPTION 'tipo_desconocido: %', p_tipo;
  END IF;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

-- Productos más vendidos entre dos fechas (para la solapa StarPOS del admin).
-- SECURITY INVOKER: respeta los permisos (solo el admin ve starpos_ventas_prod).
CREATE OR REPLACE FUNCTION starpos_top_productos(p_desde date, p_hasta date, p_q text DEFAULT NULL)
RETURNS TABLE (starpos_id text, nombre text, unidades numeric, total numeric, dias bigint)
LANGUAGE sql STABLE SET search_path = public, pg_temp
AS $$
  SELECT v.starpos_id, max(v.nombre), sum(v.unidades), sum(v.total), count(*)
  FROM starpos_ventas_prod v
  WHERE v.fecha >= p_desde AND v.fecha < p_hasta
    AND (coalesce(p_q, '') = '' OR v.nombre ILIKE '%' || p_q || '%')
  GROUP BY v.starpos_id
  ORDER BY sum(v.total) DESC
  LIMIT 300
$$;
