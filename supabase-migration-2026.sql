-- =====================================================================
-- Sabores Royal — Migración de seguridad 2026 (Parte A)
-- =====================================================================
-- Este script es ADITIVO: crea tablas, funciones y policies nuevas.
-- NO activa Row Level Security todavía (eso es la Parte D, al final,
-- después de probar que el sitio nuevo funciona). Correrlo no rompe
-- nada de lo que hoy está funcionando en producción.
--
-- Cómo correrlo: Supabase Dashboard → tu proyecto → SQL Editor →
-- "New query" → pegar TODO este archivo → Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) admin_users — reemplaza el JSON de sub_admins con contraseñas en
--    texto plano. Un admin/sub-admin = un usuario real de Supabase Auth
--    (creado desde el Dashboard) más una fila acá con sus permisos.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS admin_users (
  user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  is_super   boolean NOT NULL DEFAULT false,
  perms      text[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 2) orders — una fila por pedido (reemplaza el blob JSON en
--    app_settings.orders_list). "items" queda como JSONB porque nada
--    en la app consulta ítems sueltos, siempre se leen junto al pedido.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS orders (
  id                text PRIMARY KEY,
  client_phone      text NOT NULL,
  customer_name     text NOT NULL,
  customer_address  text,
  items             jsonb NOT NULL,
  discount_pct      numeric,
  discount_amount   numeric,
  total             numeric NOT NULL,
  status            text NOT NULL DEFAULT 'Pendiente',
  payment_method    text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS orders_client_phone_idx ON orders(client_phone);
CREATE INDEX IF NOT EXISTS orders_created_at_idx ON orders(created_at DESC);

-- Mantiene updated_at al día en cada cambio de estado
CREATE OR REPLACE FUNCTION set_orders_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_orders_updated_at ON orders;
CREATE TRIGGER trg_orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION set_orders_updated_at();

-- ---------------------------------------------------------------------
-- 3) Funciones helper para políticas RLS
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM admin_users WHERE user_id = auth.uid());
$$;

CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM admin_users WHERE user_id = auth.uid() AND is_super = true);
$$;

-- ---------------------------------------------------------------------
-- 4) RPCs para clientes anónimos (reemplazan el acceso directo a las
--    tablas). Cada una solo puede leer/escribir lo que corresponde al
--    teléfono que se le pasa como parámetro — ya no hay "SELECT *"
--    abierto a nadie.
-- ---------------------------------------------------------------------

-- Busca o crea un cliente por teléfono, devuelve SOLO esa fila.
CREATE OR REPLACE FUNCTION find_or_create_client(
  p_phone   text,
  p_name    text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_email   text DEFAULT NULL
) RETURNS clients
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_client clients;
BEGIN
  SELECT * INTO v_client FROM clients WHERE phone = p_phone;
  IF FOUND THEN
    IF COALESCE(p_name,'') <> '' OR COALESCE(p_address,'') <> '' OR COALESCE(p_email,'') <> '' THEN
      UPDATE clients
      SET full_name = COALESCE(NULLIF(p_name,''), full_name),
          address    = COALESCE(NULLIF(p_address,''), address),
          email      = COALESCE(NULLIF(p_email,''), email)
      WHERE phone = p_phone
      RETURNING * INTO v_client;
    END IF;
    RETURN v_client;
  END IF;

  INSERT INTO clients (full_name, phone, address, email)
  VALUES (COALESCE(NULLIF(p_name,''), 'Cliente'), p_phone, NULLIF(p_address,''), NULLIF(p_email,''))
  RETURNING * INTO v_client;
  RETURN v_client;
END;
$$;

-- Crea un pedido Y descuenta stock de forma atómica en la misma
-- transacción (arregla el bug de concurrencia + sobreventa).
-- p_items: array de objetos {id, name, price, qty, grams, lineTotal}
-- igual a como ya los arma el front (el "id" es el id numérico del
-- producto en la tabla products).
CREATE OR REPLACE FUNCTION create_order(
  p_phone           text,
  p_name            text,
  p_address         text,
  p_items           jsonb,
  p_discount_pct    numeric DEFAULT NULL,
  p_discount_amount numeric DEFAULT NULL,
  p_total           numeric DEFAULT 0,
  p_payment_method  text DEFAULT NULL
) RETURNS orders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_order   orders;
  v_id      text;
  v_item    jsonb;
  v_ok      boolean;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'carrito_vacio';
  END IF;

  PERFORM find_or_create_client(p_phone, p_name, p_address, NULL);

  -- id legible tipo SR250711143205 (prefijo + timestamp), único por diseño
  v_id := 'SR' || to_char(now(), 'YYMMDDHH24MISS') || lpad(floor(random()*100)::text, 2, '0');

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    -- Los productos vendidos por peso (grams) no descuentan stock en unidades
    IF (v_item ? 'grams') AND (v_item->>'grams') IS NOT NULL AND (v_item->>'grams') NOT IN ('null','false','0','') THEN
      CONTINUE;
    END IF;

    UPDATE products
    SET stock = stock - (v_item->>'qty')::int
    WHERE id = (v_item->>'id')::bigint
      AND stock >= (v_item->>'qty')::int;

    GET DIAGNOSTICS v_ok = ROW_COUNT;
    IF v_ok = 0 OR NOT FOUND THEN
      -- No alcanza el stock (o el producto no existe) → aborta todo el pedido
      RAISE EXCEPTION 'sin_stock:%', COALESCE(v_item->>'name', v_item->>'id');
    END IF;
  END LOOP;

  INSERT INTO orders (id, client_phone, customer_name, customer_address, items, discount_pct, discount_amount, total, payment_method)
  VALUES (v_id, p_phone, p_name, p_address, p_items, p_discount_pct, p_discount_amount, p_total, p_payment_method)
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;

-- Pedidos de un teléfono (para "Mis pedidos" del cliente)
CREATE OR REPLACE FUNCTION get_my_orders(p_phone text)
RETURNS SETOF orders
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM orders WHERE client_phone = p_phone ORDER BY created_at DESC LIMIT 100;
$$;

-- Mensajes de chat de un teléfono (para el cliente)
CREATE OR REPLACE FUNCTION get_chat_messages(p_phone text)
RETURNS SETOF chat_messages
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM chat_messages WHERE client_phone = p_phone ORDER BY created_at ASC LIMIT 150;
$$;

-- Marca como leídos los mensajes del admin hacia este teléfono
CREATE OR REPLACE FUNCTION mark_chat_read_by_client(p_phone text)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  UPDATE chat_messages SET read = true WHERE client_phone = p_phone AND sender = 'admin' AND read = false;
$$;

-- Manda un mensaje COMO CLIENTE. sender se fuerza acá adentro —
-- no se recibe como parámetro — para que nadie pueda mandar un
-- mensaje haciéndose pasar por 'admin' llamando esta función.
CREATE OR REPLACE FUNCTION send_chat_message(
  p_phone            text,
  p_client_name      text,
  p_message          text,
  p_attachment_url   text DEFAULT NULL,
  p_attachment_type  text DEFAULT NULL
) RETURNS chat_messages
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_row chat_messages;
BEGIN
  INSERT INTO chat_messages (client_phone, client_name, sender, message, attachment_url, attachment_type, read)
  VALUES (p_phone, COALESCE(NULLIF(p_client_name,''), 'Cliente'), 'client', p_message, p_attachment_url, p_attachment_type, false)
  RETURNING * INTO v_row;
  RETURN v_row;
END;
$$;

-- ---------------------------------------------------------------------
-- 5) RPC de administración: vincula un usuario de Supabase Auth
--    (creado a mano en el Dashboard) como admin/sub-admin de la app.
--    Solo puede llamarla alguien que YA es super-admin.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION admin_link_user(
  p_email    text,
  p_name     text,
  p_perms    text[] DEFAULT '{}',
  p_is_super boolean DEFAULT false
) RETURNS admin_users
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid;
  v_row admin_users;
BEGIN
  IF NOT is_super_admin() THEN
    RAISE EXCEPTION 'no_autorizado';
  END IF;

  SELECT id INTO v_uid FROM auth.users WHERE email = p_email;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'usuario_no_encontrado: creá el usuario en Supabase Dashboard primero';
  END IF;

  INSERT INTO admin_users (user_id, name, is_super, perms)
  VALUES (v_uid, p_name, p_is_super, p_perms)
  ON CONFLICT (user_id) DO UPDATE
    SET name = EXCLUDED.name, is_super = EXCLUDED.is_super, perms = EXCLUDED.perms
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION admin_unlink_user(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT is_super_admin() THEN
    RAISE EXCEPTION 'no_autorizado';
  END IF;
  DELETE FROM admin_users WHERE user_id = p_user_id;
END;
$$;

-- ---------------------------------------------------------------------
-- 6) Policies RLS — se crean ahora pero NO tienen efecto todavía
--    porque RLS sigue apagado en estas tablas (ver Parte D). Cuando
--    se active, quedan así:
-- ---------------------------------------------------------------------

-- products / categories: lectura pública (catálogo), escritura solo admin
DROP POLICY IF EXISTS "Public read products" ON products;
CREATE POLICY "Public read products" ON products FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admin write products" ON products;
CREATE POLICY "Admin write products" ON products FOR ALL USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS "Public read categories" ON categories;
CREATE POLICY "Public read categories" ON categories FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admin write categories" ON categories;
CREATE POLICY "Admin write categories" ON categories FOR ALL USING (is_admin()) WITH CHECK (is_admin());

-- clients / orders / chat_messages: nada para anon (todo pasa por RPC), admin full
DROP POLICY IF EXISTS "Admin full access clients" ON clients;
CREATE POLICY "Admin full access clients" ON clients FOR ALL USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS "Admin full access orders" ON orders;
CREATE POLICY "Admin full access orders" ON orders FOR ALL USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS "Admin full access chat" ON chat_messages;
CREATE POLICY "Admin full access chat" ON chat_messages FOR ALL USING (is_admin()) WITH CHECK (is_admin());

-- app_settings: lectura pública salvo claves sensibles/obsoletas, escritura solo admin
DROP POLICY IF EXISTS "Public read app settings" ON app_settings;
CREATE POLICY "Public read app settings" ON app_settings
  FOR SELECT USING (setting_key NOT IN ('sub_admins', 'orders_list'));
DROP POLICY IF EXISTS "Admin write app settings" ON app_settings;
CREATE POLICY "Admin write app settings" ON app_settings FOR ALL USING (is_admin()) WITH CHECK (is_admin());

-- admin_users: nadie de afuera lo ve; los admins se ven entre sí; solo super-admin gestiona
DROP POLICY IF EXISTS "Admins view admin_users" ON admin_users;
CREATE POLICY "Admins view admin_users" ON admin_users FOR SELECT USING (is_admin());
DROP POLICY IF EXISTS "Super admin manages admin_users" ON admin_users;
CREATE POLICY "Super admin manages admin_users" ON admin_users FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- =====================================================================
-- Fin Parte A. Todavía falta (no lo corras aún):
--  - Crear tu usuario admin en Authentication → Users, y esta fila:
--      INSERT INTO admin_users (user_id, name, is_super)
--      VALUES ('<tu-user-id-de-auth.users>', 'Tu nombre', true);
--  - Parte B: migrar los pedidos viejos del blob de app_settings.
--  - Parte D: recién ahí, ENABLE ROW LEVEL SECURITY en cada tabla.
-- =====================================================================
