-- =====================================================================
-- Sabores Royal — Súper Oferta por producto
-- =====================================================================
-- Marca por producto, independiente de las campañas de oferta por
-- categoría o de todo el catálogo: precio fijo cargado a mano, sin
-- vencimiento, que no se pisa ni se borra cuando se aplica/quita una
-- oferta general. Reusa promo_price/promo_until para mostrarse en el
-- catálogo y en la sección "Ofertas", pero queda excluido de las
-- herramientas de oferta masiva (ver applyCategoryPromo/applyGlobalPromo
-- en public/index.html).
--
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE products ADD COLUMN IF NOT EXISTS super_offer boolean DEFAULT false;
