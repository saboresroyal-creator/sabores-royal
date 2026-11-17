-- =====================================================================
-- Sabores Royal — Caja Diaria: usuarios con PIN propio y sesiones
-- =====================================================================
-- Antes: un solo PIN de 4 números, guardado en texto plano y sin límite
-- de intentos (se podían probar las 10.000 combinaciones en minutos), y
-- además escrito en un archivo del repositorio, que es público.
--
-- Ahora:
--   * Cada persona tiene su usuario y su PIN (mínimo 6 números). Los PIN
--     se guardan cifrados (bcrypt): ni leyendo la base se pueden ver.
--   * Al entrar con el PIN se recibe una sesión (token al azar, 12 horas).
--     Los datos de la caja solo se leen/guardan con una sesión válida:
--     el PIN ya no se puede probar contra get_caja_diaria.
--   * Límite de intentos: 8 PIN incorrectos desde una misma conexión en
--     15 minutos la bloquean; 40 incorrectos en total en 15 minutos
--     bloquean la entrada para todos durante ese rato.
--   * Registro de actividad: entradas, PIN incorrectos, cambios de PIN,
--     altas y bajas de usuarios y guardados.
--   * El PIN viejo (7419) pasa a ser el del usuario "Dueño" y la app
--     obliga a cambiarlo en la primera entrada. Se borra el texto plano.
--
-- Seguro de correr más de una vez.
-- =====================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS caja_usuarios (
  id             serial PRIMARY KEY,
  nombre         text NOT NULL,
  pin_hash       text NOT NULL,
  pin_debil      boolean NOT NULL DEFAULT false,
  rol            text NOT NULL DEFAULT 'usuario' CHECK (rol IN ('dueno','usuario')),
  activo         boolean NOT NULL DEFAULT true,
  creado         timestamptz NOT NULL DEFAULT now(),
  ultimo_ingreso timestamptz
);
CREATE TABLE IF NOT EXISTS caja_sesiones (
  token_hash  text PRIMARY KEY,
  usuario_id  int NOT NULL REFERENCES caja_usuarios(id) ON DELETE CASCADE,
  creado      timestamptz NOT NULL DEFAULT now(),
  expira      timestamptz NOT NULL,
  ultimo_uso  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS caja_intentos (
  id   bigserial PRIMARY KEY,
  ip   text,
  ok   boolean NOT NULL,
  ts   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS caja_intentos_ts ON caja_intentos (ts);
CREATE TABLE IF NOT EXISTS caja_auditoria (
  id         bigserial PRIMARY KEY,
  usuario_id int,
  nombre     text,
  accion     text NOT NULL,
  detalle    text,
  ip         text,
  ts         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS caja_auditoria_ts ON caja_auditoria (ts DESC);

-- Nadie las lee directo: solo a través de las funciones de abajo.
ALTER TABLE caja_usuarios  ENABLE ROW LEVEL SECURITY;
ALTER TABLE caja_sesiones  ENABLE ROW LEVEL SECURITY;
ALTER TABLE caja_intentos  ENABLE ROW LEVEL SECURITY;
ALTER TABLE caja_auditoria ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON caja_usuarios, caja_sesiones, caja_intentos, caja_auditoria FROM anon, authenticated;

SET LOCAL search_path = public, extensions;

-- El PIN actual pasa al usuario "Dueño" (cifrado) y se borra el texto plano.
DO $$
DECLARE v_pin text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM caja_usuarios WHERE rol = 'dueno') THEN
    SELECT trim(both '"' from setting_value) INTO v_pin FROM app_settings WHERE setting_key = 'caja_diaria_pin';
    v_pin := coalesce(nullif(v_pin, ''), '7419');
    INSERT INTO caja_usuarios (nombre, pin_hash, pin_debil, rol)
    VALUES ('Dueño', crypt(v_pin, gen_salt('bf', 8)), true, 'dueno');
  END IF;
  DELETE FROM app_settings WHERE setting_key = 'caja_diaria_pin';
END $$;

-- ---------------------------------------------------------------- helpers
CREATE OR REPLACE FUNCTION _caja_ip() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(trim(split_part(
    coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', ''), ',', 1)), ''), '?');
$$;

CREATE OR REPLACE FUNCTION _caja_pin_ok(p text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p IS NULL OR p !~ '^[0-9]{6,12}$' THEN RETURN 'El PIN tiene que tener entre 6 y 12 números.'; END IF;
  IF p ~ '^(.)\1+$' OR p IN ('123456','1234567','12345678','123456789','654321','987654','123123','112233','121212','159753')
    OR position(p in '01234567890123') > 0 OR position(p in '98765432109876') > 0 THEN
    RETURN 'Ese PIN es muy fácil de adivinar. Elegí otro.';
  END IF;
  RETURN NULL;
END $$;

-- Devuelve el usuario dueño de una sesión válida, o corta con error.
CREATE OR REPLACE FUNCTION _caja_sesion(p_token text) RETURNS caja_usuarios
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u caja_usuarios; v_hash text;
BEGIN
  IF p_token IS NULL OR length(p_token) < 40 THEN RAISE EXCEPTION 'Sesión vencida'; END IF;
  v_hash := encode(digest(p_token, 'sha256'), 'hex');
  SELECT cu.* INTO u FROM caja_sesiones s JOIN caja_usuarios cu ON cu.id = s.usuario_id
   WHERE s.token_hash = v_hash AND s.expira > now() AND cu.activo;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Sesión vencida'; END IF;
  UPDATE caja_sesiones SET ultimo_uso = now() WHERE token_hash = v_hash AND ultimo_uso < now() - interval '1 minute';
  RETURN u;
END $$;

CREATE OR REPLACE FUNCTION _caja_dueno(p_token text) RETURNS caja_usuarios
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u caja_usuarios;
BEGIN
  u := _caja_sesion(p_token);
  IF u.rol <> 'dueno' THEN RAISE EXCEPTION 'Solo el dueño puede hacer esto'; END IF;
  RETURN u;
END $$;

-- ¿Ese PIN ya lo usa otro usuario activo? (se entra solo con el PIN, así
-- que no puede haber dos iguales)
CREATE OR REPLACE FUNCTION _caja_pin_en_uso(p_pin text, p_excepto int) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM caja_usuarios WHERE activo AND id <> coalesce(p_excepto, 0) AND pin_hash = crypt(p_pin, pin_hash));
$$;

-- ---------------------------------------------------------------- entrar / salir
-- No corta con error (así queda registrado el intento fallido): devuelve
-- {ok:false, error} o {ok:true, token, nombre, rol, debil}.
CREATE OR REPLACE FUNCTION caja_login(p_pin text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u caja_usuarios; v_ip text := _caja_ip(); v_token text;
BEGIN
  DELETE FROM caja_intentos WHERE ts < now() - interval '7 days';
  DELETE FROM caja_sesiones WHERE expira < now();
  IF (SELECT count(*) FROM caja_intentos WHERE NOT ok AND ip = v_ip AND ts > now() - interval '15 minutes') >= 8 THEN
    RETURN json_build_object('ok', false, 'error', 'Demasiados PIN incorrectos. Esperá 15 minutos y probá de nuevo.');
  END IF;
  IF (SELECT count(*) FROM caja_intentos WHERE NOT ok AND ts > now() - interval '15 minutes') >= 40 THEN
    RETURN json_build_object('ok', false, 'error', 'La entrada está bloqueada unos minutos por muchos intentos fallidos. Esperá 15 minutos.');
  END IF;
  IF p_pin IS NOT NULL AND length(p_pin) BETWEEN 4 AND 12 THEN
    SELECT * INTO u FROM caja_usuarios WHERE activo AND pin_hash = crypt(p_pin, pin_hash) LIMIT 1;
  END IF;
  INSERT INTO caja_intentos (ip, ok) VALUES (v_ip, u.id IS NOT NULL);
  IF u.id IS NULL THEN
    INSERT INTO caja_auditoria (accion, detalle, ip) VALUES ('PIN incorrecto', NULL, v_ip);
    RETURN json_build_object('ok', false, 'error', 'PIN incorrecto, probá de nuevo');
  END IF;
  v_token := encode(gen_random_bytes(32), 'hex');
  INSERT INTO caja_sesiones (token_hash, usuario_id, expira) VALUES (encode(digest(v_token, 'sha256'), 'hex'), u.id, now() + interval '12 hours');
  UPDATE caja_usuarios SET ultimo_ingreso = now() WHERE id = u.id;
  INSERT INTO caja_auditoria (usuario_id, nombre, accion, ip) VALUES (u.id, u.nombre, 'Entró', v_ip);
  RETURN json_build_object('ok', true, 'token', v_token, 'nombre', u.nombre, 'rol', u.rol, 'debil', u.pin_debil);
END $$;

CREATE OR REPLACE FUNCTION caja_quien(p_token text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u caja_usuarios;
BEGIN
  u := _caja_sesion(p_token);
  RETURN json_build_object('nombre', u.nombre, 'rol', u.rol, 'debil', u.pin_debil);
END $$;

CREATE OR REPLACE FUNCTION caja_logout(p_token text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  DELETE FROM caja_sesiones WHERE token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
END $$;

-- ---------------------------------------------------------------- datos de la caja
-- Mismo nombre y parámetro que antes (api/factura-foto.js también lo usa),
-- pero ahora p_pin es el token de la sesión, no el PIN.
DROP FUNCTION IF EXISTS get_caja_diaria(text);
CREATE FUNCTION get_caja_diaria(p_pin text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u caja_usuarios; v_data text;
BEGIN
  u := _caja_sesion(p_pin);
  SELECT setting_value INTO v_data FROM app_settings WHERE setting_key = 'caja_diaria_data';
  RETURN v_data;
END $$;

DROP FUNCTION IF EXISTS save_caja_diaria(text, text);
CREATE FUNCTION save_caja_diaria(p_pin text, p_data text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u caja_usuarios;
BEGIN
  u := _caja_sesion(p_pin);
  INSERT INTO app_settings (setting_key, setting_value) VALUES ('caja_diaria_data', p_data)
  ON CONFLICT (setting_key) DO UPDATE SET setting_value = EXCLUDED.setting_value;
  -- Un renglón cada 10 minutos por persona, para no llenar el registro.
  IF NOT EXISTS (SELECT 1 FROM caja_auditoria WHERE usuario_id = u.id AND accion = 'Guardó cambios' AND ts > now() - interval '10 minutes') THEN
    INSERT INTO caja_auditoria (usuario_id, nombre, accion, ip) VALUES (u.id, u.nombre, 'Guardó cambios', _caja_ip());
  END IF;
END $$;

-- ---------------------------------------------------------------- PIN propio
CREATE OR REPLACE FUNCTION caja_cambiar_pin(p_token text, p_actual text, p_nuevo text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u caja_usuarios; v_err text;
BEGIN
  u := _caja_sesion(p_token);
  IF u.pin_hash <> crypt(coalesce(p_actual, ''), u.pin_hash) THEN RETURN json_build_object('ok', false, 'error', 'El PIN actual no es correcto.'); END IF;
  v_err := _caja_pin_ok(p_nuevo);
  IF v_err IS NOT NULL THEN RETURN json_build_object('ok', false, 'error', v_err); END IF;
  IF _caja_pin_en_uso(p_nuevo, u.id) THEN RETURN json_build_object('ok', false, 'error', 'Ese PIN no se puede usar. Elegí otro.'); END IF;
  UPDATE caja_usuarios SET pin_hash = crypt(p_nuevo, gen_salt('bf', 8)), pin_debil = false WHERE id = u.id;
  INSERT INTO caja_auditoria (usuario_id, nombre, accion, ip) VALUES (u.id, u.nombre, 'Cambió su PIN', _caja_ip());
  RETURN json_build_object('ok', true);
END $$;

-- ---------------------------------------------------------------- usuarios (solo dueño)
CREATE OR REPLACE FUNCTION caja_usuarios_listar(p_token text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u caja_usuarios;
BEGIN
  u := _caja_dueno(p_token);
  RETURN json_build_object(
    'yo', u.id,
    'usuarios', coalesce((SELECT json_agg(json_build_object('id', id, 'nombre', nombre, 'rol', rol, 'activo', activo, 'creado', creado, 'ultimo_ingreso', ultimo_ingreso) ORDER BY activo DESC, nombre) FROM caja_usuarios), '[]'::json),
    'actividad', coalesce((SELECT json_agg(x ORDER BY x.ts DESC) FROM (SELECT nombre, accion, detalle, ip, ts FROM caja_auditoria ORDER BY ts DESC LIMIT 150) x), '[]'::json)
  );
END $$;

-- p_id null = alta. p_pin vacío al editar = no cambia el PIN.
CREATE OR REPLACE FUNCTION caja_usuario_guardar(p_token text, p_id int, p_nombre text, p_pin text, p_rol text, p_activo boolean) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u caja_usuarios; v_err text; v_nombre text := trim(coalesce(p_nombre, '')); v_id int; v_det text;
BEGIN
  u := _caja_dueno(p_token);
  IF v_nombre = '' THEN RETURN json_build_object('ok', false, 'error', 'Poné el nombre.'); END IF;
  IF p_rol NOT IN ('dueno','usuario') THEN RETURN json_build_object('ok', false, 'error', 'Rol inválido.'); END IF;
  IF p_id IS NULL OR coalesce(p_pin, '') <> '' THEN
    v_err := _caja_pin_ok(p_pin);
    IF v_err IS NOT NULL THEN RETURN json_build_object('ok', false, 'error', v_err); END IF;
    IF _caja_pin_en_uso(p_pin, p_id) THEN RETURN json_build_object('ok', false, 'error', 'Ese PIN no se puede usar. Elegí otro.'); END IF;
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO caja_usuarios (nombre, pin_hash, rol) VALUES (v_nombre, crypt(p_pin, gen_salt('bf', 8)), p_rol) RETURNING id INTO v_id;
    v_det := 'Alta de ' || v_nombre || (CASE WHEN p_rol = 'dueno' THEN ' (dueño)' ELSE '' END);
  ELSE
    IF p_id = u.id AND (NOT p_activo OR p_rol <> 'dueno') THEN
      RETURN json_build_object('ok', false, 'error', 'No podés darte de baja ni sacarte el rol de dueño a vos mismo.');
    END IF;
    UPDATE caja_usuarios SET nombre = v_nombre, rol = p_rol, activo = p_activo,
      pin_hash = CASE WHEN coalesce(p_pin, '') <> '' THEN crypt(p_pin, gen_salt('bf', 8)) ELSE pin_hash END,
      pin_debil = CASE WHEN coalesce(p_pin, '') <> '' THEN false ELSE pin_debil END
    WHERE id = p_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RETURN json_build_object('ok', false, 'error', 'No existe ese usuario.'); END IF;
    -- Al dar de baja o cambiarle el PIN, se le cierran las sesiones abiertas.
    IF NOT p_activo OR coalesce(p_pin, '') <> '' THEN DELETE FROM caja_sesiones WHERE usuario_id = p_id; END IF;
    v_det := (CASE WHEN NOT p_activo THEN 'Baja de ' ELSE 'Cambios en ' END) || v_nombre || (CASE WHEN coalesce(p_pin, '') <> '' THEN ' (PIN nuevo)' ELSE '' END);
  END IF;
  INSERT INTO caja_auditoria (usuario_id, nombre, accion, detalle, ip) VALUES (u.id, u.nombre, 'Usuarios', v_det, _caja_ip());
  RETURN json_build_object('ok', true, 'id', v_id);
END $$;

-- ---------------------------------------------------------------- permisos
REVOKE ALL ON FUNCTION _caja_ip(), _caja_pin_ok(text), _caja_sesion(text), _caja_dueno(text), _caja_pin_en_uso(text, int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION caja_login(text), caja_quien(text), caja_logout(text), get_caja_diaria(text), save_caja_diaria(text, text),
  caja_cambiar_pin(text, text, text), caja_usuarios_listar(text), caja_usuario_guardar(text, int, text, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION caja_login(text), caja_quien(text), caja_logout(text), get_caja_diaria(text), save_caja_diaria(text, text),
  caja_cambiar_pin(text, text, text), caja_usuarios_listar(text), caja_usuario_guardar(text, int, text, text, text, boolean) TO anon, authenticated;

COMMIT;
