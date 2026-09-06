---
name: leer-lista-precios
description: Lee el contenido real (encabezados y primeras filas) de un archivo .xls/.xlsx/.csv de lista de precios de un proveedor, para diagnosticar por qué el importador del comparador no lo reconoce, o para revisar los datos antes de importar. Usar cuando el usuario mencione un archivo de precios, "no reconozco las columnas", o pida revisar/ver un Excel/CSV de proveedor.
---

# Leer lista de precios (xls/xlsx/csv)

El importador de precios (`public/comparador-import.html` y la sección
"Comparador" de `public/index.html`) espera columnas con nombres como
"Producto"/"Descripción" y "Precio"/"Costo". Cuando un proveedor manda un
archivo con otros encabezados, el importador tira error. Este script muestra
el contenido crudo del archivo para poder diagnosticar el problema.

## Uso

Los archivos de listas de precios suelen estar en `~/Downloads` (el usuario
los descarga de mail/WhatsApp). Buscalos ahí si el usuario no da una ruta:

```bash
find ~/Downloads -maxdepth 1 \( -iname "*.xls" -o -iname "*.xlsx" -o -iname "*.csv" \) -newermt "-7 days"
```

Para inspeccionar un archivo:

```bash
node .claude/skills/leer-lista-precios/peek.cjs "C:/ruta/al/archivo.xls" [filas]
```

- `filas` es opcional, cuántas filas mostrar por hoja (default 8).
- Imprime cada hoja del libro, con encabezado (fila 0) y las siguientes filas
  tal cual vienen en el archivo.

## Qué mirar con el resultado

1. **Encabezado real**: compará contra lo que reconoce `cmpParseSimpleCsv` en
   `public/index.html` (busca `/producto|nombre|descrip|art[ií]culo|detalle/`
   para el nombre y `/precio|costo|importe|valor|monto/` para el precio,
   sin distinguir mayúsculas). Si el encabezado no contiene ninguna de esas
   palabras, ahí está el problema.
2. **Fila de encabezado corrida**: algunos proveedores meten un título o logo
   en la fila 0 y el encabezado real está en la fila 1 o 2 — se nota porque
   la fila 0 tiene una sola celda con texto y el resto vacías.
3. **Formato de precio**: separador de miles/decimales (`1.250,50` vs
   `1250.50`), texto pegado como "$ 1250" o "1250 c/IVA".

## Salidas típicas al usuario

- Si el encabezado tiene una palabra reconocible pero mal escrita o distinta
  (ej. "Detalle Art." en vez de "Producto"), avisar que igual debería
  funcionar (matchea por substring) — el problema puede ser otra columna.
- Si no hay ninguna palabra reconocible, sugerir renombrar esa columna en el
  archivo antes de subirlo, o usar la opción con IA del comparador (que no
  depende de nombres exactos, pero tiene costo).
- Si la fila de encabezado está corrida, avisar que hay que borrar las filas
  previas en el Excel antes de subirlo.

Requiere el devDependency `xlsx` del proyecto (ya instalado en
`package.json`). Si falta, correr `npm install` en la raíz del repo.
