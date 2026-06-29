import { createClient } from '@supabase/supabase-js';

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseAnonKey = process.env.SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error('Missing Supabase environment variables.');
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey);

export async function getProducts() {
  const { data, error } = await supabase
    .from('products')
    .select('id, name, description, price, stock, photo_url, category_id');

  if (error) {
    throw error;
  }
  return data;
}

export async function createOrder(order) {
  const { data, error } = await supabase
    .from('orders')
    .insert([order])
    .select();

  if (error) {
    throw error;
  }
  return data;
}
