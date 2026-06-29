import express from 'express';
import cors from 'cors';
import dotenv from 'dotenv';
import { createClient } from '@supabase/supabase-js';

dotenv.config();

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseServiceRole = process.env.SUPABASE_SERVICE_ROLE_KEY;
const port = process.env.PORT || 3000;

if (!supabaseUrl || !supabaseServiceRole) {
  console.error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env');
  process.exit(1);
}

const supabase = createClient(supabaseUrl, supabaseServiceRole);
const app = express();

app.use(cors());
app.use(express.json());
app.use(express.static('public'));

app.get('/api/products', async (req, res) => {
  const { data, error } = await supabase
    .from('products')
    .select('id, name, description, price, stock, photo_url, category_id');

  if (error) {
    return res.status(500).json({ error: error.message });
  }
  res.json(data);
});

app.post('/api/order', async (req, res) => {
  const { client, items, total } = req.body;
  if (!client || !items || !Array.isArray(items) || items.length === 0) {
    return res.status(400).json({ error: 'Client and order items are required.' });
  }

  try {
    const phone = client.phone?.trim();
    if (!phone) {
      return res.status(400).json({ error: 'Client phone is required.' });
    }

    const { data: existingClients, error: clientError } = await supabase
      .from('clients')
      .select('id')
      .eq('phone', phone)
      .limit(1);

    if (clientError) throw clientError;

    let clientId;
    if (existingClients && existingClients.length > 0) {
      clientId = existingClients[0].id;
    } else {
      const { data: newClient, error: newClientError } = await supabase
        .from('clients')
        .insert([{ full_name: client.full_name, phone, email: client.email || null, address: client.address || null }])
        .select('id')
        .single();

      if (newClientError) throw newClientError;
      clientId = newClient.id;
    }

    const { data: newOrder, error: orderError } = await supabase
      .from('orders')
      .insert([{ client_id: clientId, total, status: 'Pendiente', payment_method: client.payment_method || 'Efectivo' }])
      .select('id')
      .single();

    if (orderError) throw orderError;

    const orderItems = items.map((item) => ({
      order_id: newOrder.id,
      product_id: item.product_id,
      quantity: item.quantity,
      unit_price: item.unit_price
    }));

    const { error: orderItemsError } = await supabase.from('order_items').insert(orderItems);
    if (orderItemsError) throw orderItemsError;

    res.json({ orderId: newOrder.id });
  } catch (error) {
    res.status(500).json({ error: error.message || 'Failed to create order' });
  }
});

app.listen(port, () => {
  console.log(`Server running on http://localhost:${port}`);
});
