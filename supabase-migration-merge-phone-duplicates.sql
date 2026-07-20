-- =====================================================================
-- Sabores Royal — Unificar clientes duplicados por el "9" faltante
-- =====================================================================
-- normalizePhone() en la app no agregaba el "9" que necesitan los
-- celulares argentinos en formato internacional (+549341... en vez de
-- +54341...). Según cómo se haya tipeado el número las distintas
-- veces, el mismo cliente real podía terminar como dos filas
-- distintas en `clients` (una con el 9, otra sin él).
--
-- Este script, en dos pasos:
--  1) A los que NO tienen un duplicado con 9: les agrega el 9 en su
--     fila existente (no hay conflicto, es solo corregir el formato).
--  2) A los que SÍ tienen un duplicado con 9: completa los datos que
--     falten en la fila "buena" (con 9) tomándolos de la fila vieja
--     (sin 9) — nombre, dirección, email — y borra la fila vieja.
--
-- No toca `orders` ni `vouchers` (guardan el teléfono directo en cada
-- pedido/comprobante, son un registro histórico, no hace falta
-- tocarlos). Si algún cliente tenía un descuento especial o estaba
-- marcado mayorista guardado bajo el número SIN el 9 (en
-- app_settings.client_discounts / wholesale_clients), revisalo a mano
-- después de correr esto — son pocos casos como para automatizarlo
-- con confianza acá.
--
-- Seguro de correr más de una vez (si no hay nada para unificar, no
-- hace nada).
-- =====================================================================

-- Todo en una sola transacción: si algo falla a mitad de camino, no
-- queda nada a medio aplicar.
BEGIN;

-- Paso 1: renombrar los que no tienen conflicto.
UPDATE clients c
SET phone = '+549' || substring(c.phone from 4)
WHERE c.phone LIKE '+54%' AND c.phone NOT LIKE '+549%'
  AND NOT EXISTS (
    SELECT 1 FROM clients c2 WHERE c2.phone = '+549' || substring(c.phone from 4)
  );

-- Paso 2: completar datos faltantes en la fila "buena" (con 9) desde la vieja.
UPDATE clients target
SET full_name = COALESCE(NULLIF(target.full_name,''), NULLIF(target.full_name,'Cliente'), old.full_name, target.full_name),
    address   = COALESCE(NULLIF(target.address,''), old.address, target.address),
    email     = COALESCE(NULLIF(target.email,''), old.email, target.email)
FROM clients old
WHERE old.phone LIKE '+54%' AND old.phone NOT LIKE '+549%'
  AND target.phone = '+549' || substring(old.phone from 4);

-- Paso 3: borrar las filas viejas ya fusionadas.
DELETE FROM clients c
WHERE c.phone LIKE '+54%' AND c.phone NOT LIKE '+549%'
  AND EXISTS (
    SELECT 1 FROM clients c2 WHERE c2.phone = '+549' || substring(c.phone from 4)
  );

COMMIT;

-- Verificación: no debería quedar ningún +54 sin el 9.
SELECT count(*) AS clientes_sin_9_restantes
FROM clients WHERE phone LIKE '+54%' AND phone NOT LIKE '+549%';
