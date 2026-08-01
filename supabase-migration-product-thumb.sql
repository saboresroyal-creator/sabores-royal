-- =====================================================================
-- Sabores Royal — Miniatura aparte para tarjetas de catálogo/carrito
-- =====================================================================
-- Hasta ahora se usaba la misma foto (hasta 900px) tanto en las tarjetas
-- chiquitas del catálogo/carrito/listas como en el detalle del producto.
-- Esta columna guarda una versión aparte, mucho más liviana (300px), para
-- esos usos en miniatura — la foto completa queda reservada para cuando
-- el cliente entra a ver el detalle del producto.
--
-- No hace nada retroactivo con productos ya cargados — para esos hay que
-- correr "Optimizar fotos de productos ya cargadas" en Config una vez
-- (ahora también genera la miniatura de paso).
--
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE products ADD COLUMN IF NOT EXISTS photo_thumb_url text;
