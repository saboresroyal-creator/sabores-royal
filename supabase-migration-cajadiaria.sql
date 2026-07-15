-- =====================================================================
-- Caja Diaria (archivo HTML suelto, ahora alojado en /caja-diaria.html)
-- =====================================================================
-- Versión sin login: se descartó el gate de administrador porque en una
-- de las computadoras el endpoint de auth (/auth/v1/token) no resolvía
-- por DNS de forma consistente (se probó y descartó: extensiones,
-- Service Worker, archivo hosts, antivirus, protección de red, NRPT —
-- ver conversación). El resto del dominio de Supabase sí respondía bien
-- ahí, así que se optó por usar la clave anon directo, sin login, igual
-- que el resto del contenido no sensible de la app.
--
-- Esto hace que 'caja_diaria_data' sea de lectura Y escritura pública
-- (cualquiera con el link puede ver/editar los datos de caja). Es un
-- trade-off consciente pedido explícitamente por el dueño para priorizar
-- que funcione en todas las computadoras.
--
-- Seguro de correr más de una vez.
-- =====================================================================

DROP POLICY IF EXISTS "Public read app settings" ON app_settings;
CREATE POLICY "Public read app settings" ON app_settings
  FOR SELECT USING (setting_key NOT IN ('sub_admins', 'orders_list', 'rent_ledger'));

DROP POLICY IF EXISTS "Public write caja diaria" ON app_settings;
CREATE POLICY "Public write caja diaria" ON app_settings
  FOR ALL USING (setting_key = 'caja_diaria_data') WITH CHECK (setting_key = 'caja_diaria_data');
