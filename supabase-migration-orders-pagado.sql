-- =====================================================================
-- Sabores Royal — Pedidos: marcar pagado
-- =====================================================================
-- Guarda cuándo se cobró cada pedido. La forma de pago ya tiene su
-- columna (payment_method). Solo agrega; seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE orders ADD COLUMN IF NOT EXISTS paid_at timestamptz;
