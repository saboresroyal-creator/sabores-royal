-- =====================================================================
-- Sabores Royal — Parte A (extra): faltaban dos cosas para que el
-- código nuevo funcione:
--  1) admin_users necesita guardar el email (para mostrarlo en la lista
--     de administradores sin tener que leer auth.users cada vez).
--  2) Una función de "buscar cliente por teléfono" que NO cree el
--     cliente si no existe (find_or_create_client siempre crea uno,
--     lo cual está mal para el login — queremos poder distinguir
--     "cliente nuevo, mandalo a registrarse" de "cliente existente").
-- Aditivo, seguro de correr aunque ya hayas corrido la Parte A antes.
-- =====================================================================

ALTER TABLE admin_users ADD COLUMN IF NOT EXISTS email text;

UPDATE admin_users a
SET email = u.email
FROM auth.users u
WHERE a.user_id = u.id AND a.email IS NULL;

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

  INSERT INTO admin_users (user_id, name, email, is_super, perms)
  VALUES (v_uid, p_name, p_email, p_is_super, p_perms)
  ON CONFLICT (user_id) DO UPDATE
    SET name = EXCLUDED.name, email = EXCLUDED.email, is_super = EXCLUDED.is_super, perms = EXCLUDED.perms
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION get_client_by_phone(p_phone text)
RETURNS SETOF clients
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM clients WHERE phone = p_phone LIMIT 1;
$$;
