-- =====================================================================
-- Sabores Royal — Colores / variantes de producto
-- =====================================================================
-- Agrega la columna `variants` a products: para productos iguales que
-- solo cambian de color (o talle, sabor), se carga UN producto con la
-- lista de opciones en vez de uno por color, y el cliente elige al
-- comprar. Formato:
--   {"label": "Color", "options": [{"name": "Rojo", "out": false}, ...]}
-- "out" = esa opción está agotada.
--
-- El pedido guarda la opción elegida dentro de cada ítem (orders.items),
-- así que create_order no necesita cambios. El stock sigue siendo el del
-- producto, compartido entre todas sus opciones.
--
-- Seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE products ADD COLUMN IF NOT EXISTS variants JSONB;
