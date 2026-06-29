-- Enable Row-Level Security on tables
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;

-- Public read access for products and categories only
CREATE POLICY "Public read products" ON products
  FOR SELECT USING (true);

CREATE POLICY "Public read categories" ON categories
  FOR SELECT USING (true);

-- Deny all public access for sensitive tables
CREATE POLICY "No public access clients" ON clients
  FOR ALL USING (false);

CREATE POLICY "No public access orders" ON orders
  FOR ALL USING (false);

CREATE POLICY "No public access order_items" ON order_items
  FOR ALL USING (false);

-- Notes:
-- The backend uses the Supabase service_role key, which bypasses RLS.
-- That means your server can insert into clients, orders, and order_items securely,
-- while the frontend only reads products and categories.
