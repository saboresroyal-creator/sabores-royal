-- Sample data for Sabores Royal

-- Categories
INSERT INTO categories (name, slug) VALUES
  ('Frutos Secos', 'frutos-secos'),
  ('Golosinas', 'golosinas'),
  ('Market', 'market');

-- Products
INSERT INTO products (name, category_id, description, price, stock, photo_url) VALUES
  ('Almendras Tostadas Premium', 1, 'Almendras tostadas sin sal. 250g.', 5400, 25, 'https://images.unsplash.com/photo-1528825871115-3581a5387919'),
  ('Mix Frutas Deshidratadas', 1, 'Mango, ananá y banana deshidratados. 200g.', 4100, 12, 'https://images.unsplash.com/photo-1567306226416-28f0efdc88ce'),
  ('Caramelos Ácidos Surtidos', 2, 'Mix de caramelos ácidos de frutas. Bolsa 200g.', 1800, 4, 'https://images.unsplash.com/photo-1505751172876-fa1923c5c528'),
  ('Gaseosa Cola 2.25L', 3, 'Botella retornable 2.25 litros.', 2300, 30, 'https://images.unsplash.com/photo-1551024735-4b7f00f0f11e'),
  ('Aceite de Girasol 1.5L', 3, 'Aceite de girasol puro, botella 1.5L.', 2900, 2, 'https://images.unsplash.com/photo-1509042239860-f550ce710b93');

-- App settings demo
INSERT INTO app_settings (setting_key, setting_value) VALUES
  ('store_name', 'Sabores Royal'),
  ('support_phone', '+5493413017991');
