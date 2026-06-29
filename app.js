const productsContainer = document.getElementById('products');
const cartItemsContainer = document.getElementById('cart-items');
const cartTotalEl = document.getElementById('cart-total');
const checkoutButton = document.getElementById('checkout-button');
const messageEl = document.getElementById('message');

let products = [];
let cart = [];

async function fetchProducts() {
  try {
    const res = await fetch('/api/products');
    products = await res.json();
    renderProducts();
  } catch (error) {
    messageEl.textContent = 'No se pudo cargar el catálogo. Intenta más tarde.';
  }
}

function renderProducts() {
  productsContainer.innerHTML = '';
  products.forEach((product) => {
    const card = document.createElement('div');
    card.className = 'product-card';
    card.innerHTML = `
      <img src="${product.photo_url || 'https://via.placeholder.com/180'}" alt="${product.name}" />
      <div class="product-info">
        <h3>${product.name}</h3>
        <p>${product.description || ''}</p>
        <p class="price">$${Number(product.price).toLocaleString('es-AR')}</p>
        <p>Stock: ${product.stock}</p>
      </div>
      <button data-id="${product.id}">Agregar</button>
    `;
    const button = card.querySelector('button');
    button.addEventListener('click', () => addToCart(product.id));
    productsContainer.appendChild(card);
  });
}

function addToCart(productId) {
  const product = products.find((p) => p.id === productId);
  if (!product) return;
  const item = cart.find((entry) => entry.product_id === product.id);
  if (item) {
    item.quantity += 1;
  } else {
    cart.push({
      product_id: product.id,
      name: product.name,
      quantity: 1,
      unit_price: Number(product.price),
    });
  }
  renderCart();
}

function renderCart() {
  cartItemsContainer.innerHTML = '';
  if (cart.length === 0) {
    cartItemsContainer.innerHTML = '<p>El carrito está vacío.</p>';
    cartTotalEl.textContent = '$0';
    return;
  }

  cart.forEach((item) => {
    const row = document.createElement('div');
    row.className = 'cart-item';
    row.innerHTML = `
      <span>${item.quantity} x ${item.name}</span>
      <div>
        <span>$${(item.quantity * item.unit_price).toLocaleString('es-AR')}</span>
        <button data-id="${item.product_id}">Eliminar</button>
      </div>
    `;
    row.querySelector('button').addEventListener('click', () => removeFromCart(item.product_id));
    cartItemsContainer.appendChild(row);
  });

  cartTotalEl.textContent = `$${cartTotal().toLocaleString('es-AR')}`;
}

function removeFromCart(productId) {
  cart = cart.filter((item) => item.product_id !== productId);
  renderCart();
}

function cartTotal() {
  return cart.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);
}

async function submitOrder() {
  const full_name = document.getElementById('full_name').value.trim();
  const phone = document.getElementById('phone').value.trim();
  const email = document.getElementById('email').value.trim();
  const address = document.getElementById('address').value.trim();

  if (!full_name || !phone || cart.length === 0) {
    messageEl.textContent = 'Completa tu nombre, teléfono y agrega productos al carrito.';
    return;
  }

  const orderPayload = {
    client: { full_name, phone, email, address },
    items: cart.map((item) => ({
      product_id: item.product_id,
      quantity: item.quantity,
      unit_price: item.unit_price,
    })),
    total: cartTotal(),
  };

  try {
    const response = await fetch('/api/order', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(orderPayload),
    });
    const data = await response.json();

    if (!response.ok) {
      messageEl.textContent = data.error || 'No se pudo procesar el pedido.';
      return;
    }

    cart = [];
    renderCart();
    messageEl.textContent = `Pedido creado con éxito (ID: ${data.orderId}).`;
  } catch (error) {
    messageEl.textContent = 'Error al enviar el pedido. Intenta nuevamente.';
  }
}

checkoutButton.addEventListener('click', submitOrder);
fetchProducts();
