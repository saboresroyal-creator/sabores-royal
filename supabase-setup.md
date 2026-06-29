# Supabase Setup for Sabores Royal

Esta guía te lleva paso a paso para crear un proyecto en Supabase, configurar la base de datos, crear tablas y conectar tu app.

## 1) Crear el proyecto en Supabase

1. Abre el navegador en: `https://app.supabase.com`
2. Inicia sesión o crea cuenta.
3. Haz clic en `New project`.
4. Completa:
   - `Project name`: sabores-royal
   - `Organization`: tu organización o usuario
   - `Database password`: elige una contraseña segura
   - `Region`: la que te quede más cercana
5. Haz clic en `Create new project`.

> Espera algunos minutos hasta que el proyecto se inicialice.

## 2) Obtener URL y keys

1. En el dashboard del proyecto, ve a `Settings > API`.
2. Copia:
   - `URL` (supabaseUrl)
   - `anon public` key si vas a usar la app cliente
   - `service_role` key solo para scripts de administración

## 3) Crear las tablas

Usa el editor SQL de Supabase (`SQL Editor > New query`) o la tabla `Table Editor`.

Copia y pega el contenido de `supabase-schema.sql` y ejecútalo.

## 4) Configurar políticas de RLS (Row Level Security)

Para una app pública debes habilitar RLS en cada tabla y crear políticas de lectura/escritura.

Ejemplo para la tabla `products`:

```sql
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read products" ON products
  FOR SELECT USING (true);
```

Para `orders` y `clients` usa políticas más restrictivas según el usuario.

## 5) Conectar tu proyecto con `supabase-js`

Instala la librería si tu app usa JavaScript/Node:

```bash
npm install @supabase/supabase-js
```

Crea un archivo `supabase-client.js` con la conexión base.

## 6) Variables de entorno

Crea un archivo `.env` en tu proyecto (pero no lo subas al repositorio público):

```env
SUPABASE_URL=https://TU_PROYECTO.supabase.co
SUPABASE_ANON_KEY=tu_anon_key_aqui
SUPABASE_SERVICE_ROLE_KEY=tu_service_role_key_aqui
```

## 7) Flujo recomendado

- Usa `anon key` en el frontend.
- Usa `service_role` solo en scripts seguros o funciones de servidor.
- No publiques `service_role` en el navegador.

## 8) Comandos opcionales

Si instalas Supabase CLI, puedes ejecutar:

```bash
npm install -g supabase
supabase login
supabase projects list
supabase db push
```

## 9) Tablas y datos

Las tablas sugeridas cubren:
- `products`
- `categories`
- `clients`
- `orders`
- `order_items`

El archivo `supabase-schema.sql` tiene el esquema completo.

## 10) Próximos pasos

1. Crea el proyecto Supabase.
2. Ejecuta el SQL en `supabase-schema.sql`.
3. Copia tus keys a `.env`.
4. Prueba la conexión con `supabase-client.js`.

Si quieres, puedo darte también un ejemplo de frontend para listar productos, agregar al carrito y crear pedidos con Supabase.
