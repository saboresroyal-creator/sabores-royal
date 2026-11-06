-- Stock de los productos por peso: en kilos, con gramos como decimales.
-- products.stock pasa de entero a numérico con 3 decimales (2,5 kg = 2.500).
-- Los productos por unidad no cambian: la app los sigue guardando enteros.
-- Los productos por peso que estaban en gramos se dividen por 1000; los que
-- ya tenían un número chico no se tocan. Se puede correr dos veces sin dañar
-- nada, porque después de dividir ya no quedan valores de 1000 o más.

BEGIN;

ALTER TABLE products ALTER COLUMN stock TYPE numeric(12,3);

UPDATE products
SET stock = stock / 1000
WHERE sell_by_weight = true AND stock >= 1000;

COMMIT;

-- Verificación: deberían quedar 67 productos con 5 kg y 46 con 3 kg.
SELECT stock AS kilos, count(*) AS productos
FROM products
WHERE sell_by_weight = true
GROUP BY stock
ORDER BY stock DESC;
