-- =====================================================================
-- Sabores Royal — Datos fiscales de cliente (Razón Social, CUIT,
-- condición ante el IVA) + número de identificación por cliente
-- =====================================================================
-- Fase 5 de caja-venta.html: para poder facturar bien más adelante
-- (cuando esté la impresora fiscal) hace falta saber la condición
-- fiscal del cliente, no solo su nombre/teléfono. También se agrega un
-- número de identificación propio (client_number), autoincremental, y
-- se suma CUIT/Razón Social a la búsqueda de clientes.
--
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE clients ADD COLUMN IF NOT EXISTS cuit text;
ALTER TABLE clients ADD COLUMN IF NOT EXISTS razon_social text;
ALTER TABLE clients ADD COLUMN IF NOT EXISTS condicion_iva text;

-- Número de identificación autoincremental por cliente. Se usa una
-- secuencia en vez de GENERATED ALWAYS AS IDENTITY para poder
-- backfillear los clientes que ya existen sin romper nada.
CREATE SEQUENCE IF NOT EXISTS clients_client_number_seq;
ALTER TABLE clients ADD COLUMN IF NOT EXISTS client_number integer;
UPDATE clients SET client_number = nextval('clients_client_number_seq') WHERE client_number IS NULL;
ALTER TABLE clients ALTER COLUMN client_number SET DEFAULT nextval('clients_client_number_seq');
ALTER SEQUENCE clients_client_number_seq OWNED BY clients.client_number;
CREATE UNIQUE INDEX IF NOT EXISTS clients_client_number_idx ON clients(client_number);

-- find_or_create_client(): se agregan los 3 campos nuevos al final, todos
-- DEFAULT NULL, para que las llamadas existentes (create_order() en
-- index.html, con 4 argumentos posicionales) sigan funcionando igual.
CREATE OR REPLACE FUNCTION find_or_create_client(
  p_phone         text,
  p_name          text DEFAULT NULL,
  p_address       text DEFAULT NULL,
  p_email         text DEFAULT NULL,
  p_cuit          text DEFAULT NULL,
  p_razon_social  text DEFAULT NULL,
  p_condicion_iva text DEFAULT NULL
) RETURNS clients
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_client clients;
BEGIN
  SELECT * INTO v_client FROM clients WHERE phone = p_phone;
  IF FOUND THEN
    IF COALESCE(p_name,'') <> '' OR COALESCE(p_address,'') <> '' OR COALESCE(p_email,'') <> ''
       OR COALESCE(p_cuit,'') <> '' OR COALESCE(p_razon_social,'') <> '' OR COALESCE(p_condicion_iva,'') <> '' THEN
      UPDATE clients
      SET full_name     = COALESCE(NULLIF(p_name,''), full_name),
          address       = COALESCE(NULLIF(p_address,''), address),
          email         = COALESCE(NULLIF(p_email,''), email),
          cuit          = COALESCE(NULLIF(p_cuit,''), cuit),
          razon_social  = COALESCE(NULLIF(p_razon_social,''), razon_social),
          condicion_iva = COALESCE(NULLIF(p_condicion_iva,''), condicion_iva)
      WHERE phone = p_phone
      RETURNING * INTO v_client;
    END IF;
    RETURN v_client;
  END IF;

  INSERT INTO clients (full_name, phone, address, email, cuit, razon_social, condicion_iva)
  VALUES (
    COALESCE(NULLIF(p_name,''), 'Cliente'), p_phone,
    NULLIF(p_address,''), NULLIF(p_email,''),
    NULLIF(p_cuit,''), NULLIF(p_razon_social,''), NULLIF(p_condicion_iva,'')
  )
  RETURNING * INTO v_client;
  RETURN v_client;
END;
$$;

-- search_clients(): suma CUIT y Razón Social a la búsqueda existente.
CREATE OR REPLACE FUNCTION search_clients(p_query text)
RETURNS SETOF clients
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM clients
  WHERE phone ILIKE '%'||p_query||'%'
     OR full_name ILIKE '%'||p_query||'%'
     OR cuit ILIKE '%'||p_query||'%'
     OR razon_social ILIKE '%'||p_query||'%'
  ORDER BY full_name
  LIMIT 20;
$$;
