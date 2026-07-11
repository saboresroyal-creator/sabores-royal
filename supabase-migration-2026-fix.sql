-- =====================================================================
-- Sabores Royal — Corrección: había una tabla `orders` vieja (sin usar
-- por la app) que impidió crear la nueva. Este script la reemplaza y
-- vuelve a dejar funciones/RPCs/policies en su lugar. Seguro de
-- correr aunque algunas ya existan (usa IF EXISTS / OR REPLACE).
-- =====================================================================

DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS orders CASCADE;

CREATE TABLE orders (
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
CREATE INDEX orders_client_phone_idx ON orders(client_phone);
CREATE INDEX orders_created_at_idx ON orders(created_at DESC);

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

  v_id := 'SR' || to_char(now(), 'YYMMDDHH24MISS') || lpad(floor(random()*100)::text, 2, '0');

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF (v_item ? 'grams') AND (v_item->>'grams') IS NOT NULL AND (v_item->>'grams') NOT IN ('null','false','0','') THEN
      CONTINUE;
    END IF;

    UPDATE products
    SET stock = stock - (v_item->>'qty')::int
    WHERE id = (v_item->>'id')::bigint
      AND stock >= (v_item->>'qty')::int;

    GET DIAGNOSTICS v_ok = ROW_COUNT;
    IF v_ok = 0 OR NOT FOUND THEN
      RAISE EXCEPTION 'sin_stock:%', COALESCE(v_item->>'name', v_item->>'id');
    END IF;
  END LOOP;

  INSERT INTO orders (id, client_phone, customer_name, customer_address, items, discount_pct, discount_amount, total, payment_method)
  VALUES (v_id, p_phone, p_name, p_address, p_items, p_discount_pct, p_discount_amount, p_total, p_payment_method)
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION get_my_orders(p_phone text)
RETURNS SETOF orders
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM orders WHERE client_phone = p_phone ORDER BY created_at DESC LIMIT 100;
$$;

CREATE OR REPLACE FUNCTION get_chat_messages(p_phone text)
RETURNS SETOF chat_messages
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM chat_messages WHERE client_phone = p_phone ORDER BY created_at ASC LIMIT 150;
$$;

CREATE OR REPLACE FUNCTION mark_chat_read_by_client(p_phone text)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  UPDATE chat_messages SET read = true WHERE client_phone = p_phone AND sender = 'admin' AND read = false;
$$;

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

DROP POLICY IF EXISTS "Public read products" ON products;
CREATE POLICY "Public read products" ON products FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admin write products" ON products;
CREATE POLICY "Admin write products" ON products FOR ALL USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS "Public read categories" ON categories;
CREATE POLICY "Public read categories" ON categories FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admin write categories" ON categories;
CREATE POLICY "Admin write categories" ON categories FOR ALL USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS "Admin full access clients" ON clients;
CREATE POLICY "Admin full access clients" ON clients FOR ALL USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS "Admin full access orders" ON orders;
CREATE POLICY "Admin full access orders" ON orders FOR ALL USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS "Admin full access chat" ON chat_messages;
CREATE POLICY "Admin full access chat" ON chat_messages FOR ALL USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS "Public read app settings" ON app_settings;
CREATE POLICY "Public read app settings" ON app_settings
  FOR SELECT USING (setting_key NOT IN ('sub_admins', 'orders_list'));
DROP POLICY IF EXISTS "Admin write app settings" ON app_settings;
CREATE POLICY "Admin write app settings" ON app_settings FOR ALL USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS "Admins view admin_users" ON admin_users;
CREATE POLICY "Admins view admin_users" ON admin_users FOR SELECT USING (is_admin());
DROP POLICY IF EXISTS "Super admin manages admin_users" ON admin_users;
CREATE POLICY "Super admin manages admin_users" ON admin_users FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- Verificación rápida: deberían aparecer 10 funciones
SELECT routine_name FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_type = 'FUNCTION'
ORDER BY routine_name;
