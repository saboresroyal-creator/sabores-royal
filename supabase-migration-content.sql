-- =====================================================================
-- Sabores Royal — Migración: sugerencias y comprobantes reales
-- =====================================================================
-- Cierra dos huecos de localStorage:
--  1) suggestions — hoy un cliente manda una sugerencia y queda en SU
--     PROPIO navegador; el admin, en otro dispositivo, nunca la ve.
--  2) vouchers — facturas/remitos/tickets/presupuestos que genera el
--     admin, hoy solo en el navegador que los creó (se pierden si se
--     borra, no se ven entre computadoras). Son comprobantes internos,
--     no facturación fiscal AFIP (así lo dice el pie de cada uno), por
--     lo que no requieren numeración correlativa atómica estricta.
--
-- Categorías, config del negocio, datos fiscales y banners genéricos NO
-- requieren SQL: son nuevas setting_key dentro de app_settings, que ya
-- tiene policies genéricas de lectura pública / escritura admin-only
-- (igual que novedades/ofertas).
--
-- Aditivo, seguro de correr más de una vez (usa IF NOT EXISTS / OR
-- REPLACE). Requiere haber corrido antes supabase-migration-2026.sql
-- (usa is_admin(), que se define ahí).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) suggestions
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS suggestions (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_phone text,
  client_name  text,
  message      text NOT NULL,
  read         boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE suggestions ENABLE ROW LEVEL SECURITY;

-- Sin policy pública: todo insert pasa por submit_suggestion() más
-- abajo, que es SECURITY DEFINER y esquiva RLS. Nadie de afuera puede
-- leer, editar ni borrar sugerencias directamente.
DROP POLICY IF EXISTS "Admin full access suggestions" ON suggestions;
CREATE POLICY "Admin full access suggestions" ON suggestions
  FOR ALL USING (is_admin()) WITH CHECK (is_admin());

-- Manda una sugerencia COMO CLIENTE. read se fuerza a false acá adentro
-- (no se recibe como parámetro), igual que send_chat_message fuerza
-- sender='client' — nadie puede insertar una sugerencia ya marcada
-- como leída.
CREATE OR REPLACE FUNCTION submit_suggestion(
  p_phone   text,
  p_name    text,
  p_message text
) RETURNS suggestions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_row suggestions;
BEGIN
  IF COALESCE(trim(p_message), '') = '' THEN
    RAISE EXCEPTION 'mensaje_vacio';
  END IF;

  INSERT INTO suggestions (client_phone, client_name, message)
  VALUES (NULLIF(p_phone, ''), COALESCE(NULLIF(p_name, ''), 'Anónimo'), p_message)
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- ---------------------------------------------------------------------
-- 2) vouchers
-- ---------------------------------------------------------------------
-- id queda como text (no autogenerado por la base) porque createVoucher
-- en el front es síncrona: genera el id, navega a viewVoucher(id) y
-- recién después dispara el guardado remoto en segundo plano.
CREATE TABLE IF NOT EXISTS vouchers (
  id                       text PRIMARY KEY,
  type                     text NOT NULL,
  number                   integer NOT NULL,
  voucher_date             timestamptz NOT NULL,
  items                    jsonb NOT NULL,
  customer                 jsonb NOT NULL,
  total                    numeric NOT NULL,
  general_discount         jsonb,
  general_discount_amount  numeric,
  show_iva                 boolean DEFAULT false,
  iva_pct                  numeric,
  iva                      numeric,
  neto                     numeric,
  order_id                 text,
  edited_at                timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS vouchers_type_idx ON vouchers(type);

ALTER TABLE vouchers ENABLE ROW LEVEL SECURITY;

-- Datos financieros del negocio: acceso total solo para admin, igual
-- que clients/orders. Nada de lectura pública.
DROP POLICY IF EXISTS "Admin full access vouchers" ON vouchers;
CREATE POLICY "Admin full access vouchers" ON vouchers
  FOR ALL USING (is_admin()) WITH CHECK (is_admin());

-- Verificación rápida
SELECT 'suggestions' AS tabla, count(*) FROM suggestions
UNION ALL
SELECT 'vouchers', count(*) FROM vouchers;
