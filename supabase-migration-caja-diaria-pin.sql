-- =====================================================================
-- Sabores Royal — Proteger Caja Diaria con PIN
-- =====================================================================
-- caja-diaria.html se armó a propósito sin login (para que el personal
-- de caja no tenga que loguearse como admin), usando la clave anon
-- directo contra app_settings.caja_diaria_data. La política RLS que
-- permitía eso ("Public write caja diaria") dejaba esos datos
-- (movimientos de caja con plata real) abiertos a cualquiera que
-- encontrara la URL, sin login y sin ningún rastro de quién escribió.
--
-- Esto reemplaza el acceso directo por dos funciones RPC que piden un
-- PIN y lo validan del lado del servidor (no alcanza con "saltearse" el
-- cartel de PIN en el navegador, como pasaría con un PIN chequeado solo
-- en JavaScript) — y saca el acceso público directo a esa clave.
--
-- Seguro de correr más de una vez.
-- =====================================================================

BEGIN;

-- PIN inicial: 7419. Para cambiarlo más adelante, corré:
--   UPDATE app_settings SET setting_value = '"NUEVO_PIN"' WHERE setting_key = 'caja_diaria_pin';
INSERT INTO app_settings (setting_key, setting_value)
VALUES ('caja_diaria_pin', '"7419"')
ON CONFLICT (setting_key) DO NOTHING;

-- Sacar el acceso público directo de escritura a caja_diaria_data.
DROP POLICY IF EXISTS "Public write caja diaria" ON app_settings;

-- La política "Public read app settings" ya excluye sub_admins de la
-- lectura pública — ahora también excluye el PIN y los datos de caja,
-- para que no se puedan leer directo de la tabla sin pasar por el RPC.
DROP POLICY IF EXISTS "Public read app settings" ON app_settings;
CREATE POLICY "Public read app settings" ON app_settings
  FOR SELECT USING (setting_key <> ALL (ARRAY['sub_admins','caja_diaria_pin','caja_diaria_data']::text[]));

-- Leer la caja diaria: valida el PIN antes de devolver los datos.
CREATE OR REPLACE FUNCTION get_caja_diaria(p_pin text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_pin text;
  v_data text;
BEGIN
  SELECT setting_value INTO v_pin FROM app_settings WHERE setting_key = 'caja_diaria_pin';
  IF v_pin IS NULL OR trim(both '"' from v_pin) <> p_pin THEN
    RAISE EXCEPTION 'PIN incorrecto';
  END IF;
  SELECT setting_value INTO v_data FROM app_settings WHERE setting_key = 'caja_diaria_data';
  RETURN v_data;
END;
$$;

-- Guardar la caja diaria: valida el PIN antes de escribir.
CREATE OR REPLACE FUNCTION save_caja_diaria(p_pin text, p_data text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_pin text;
BEGIN
  SELECT setting_value INTO v_pin FROM app_settings WHERE setting_key = 'caja_diaria_pin';
  IF v_pin IS NULL OR trim(both '"' from v_pin) <> p_pin THEN
    RAISE EXCEPTION 'PIN incorrecto';
  END IF;
  INSERT INTO app_settings (setting_key, setting_value)
  VALUES ('caja_diaria_data', p_data)
  ON CONFLICT (setting_key) DO UPDATE SET setting_value = EXCLUDED.setting_value;
END;
$$;

GRANT EXECUTE ON FUNCTION get_caja_diaria(text) TO anon;
GRANT EXECUTE ON FUNCTION save_caja_diaria(text, text) TO anon;

COMMIT;
