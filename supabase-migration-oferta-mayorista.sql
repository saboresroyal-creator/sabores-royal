-- Oferta para mayoristas cargada a mano en cada producto: precio por unidad
-- (o por kilo si es pesable) y fecha de vencimiento opcional. La app la
-- muestra solo a los mayoristas; si está vacía, el mayorista ve la oferta
-- común únicamente cuando es más barata que su precio mayorista.

ALTER TABLE products ADD COLUMN IF NOT EXISTS wholesale_promo_price numeric(12,2);
ALTER TABLE products ADD COLUMN IF NOT EXISTS wholesale_promo_until date;
