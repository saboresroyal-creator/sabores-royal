---
name: leer-lista-precios
description: Lee el contenido real (encabezados y primeras filas) de un archivo .xls/.xlsx/.csv de lista de precios de un proveedor, para diagnosticar por qué el importador del comparador no lo reconoce, o para revisar los datos antes de importar. Usar cuando el usuario mencione un archivo de precios, "no reconozco las columnas", o pida revisar/ver un Excel/CSV de proveedor.
---

# Leer lista de precios (xls/xlsx/csv)

El importador de precios (pestaña "Importar" del Comparador en
`public/index.html`) lee el archivo en el navegador como grilla y adivina
qué columna es producto / precio / uds por bulto / código (`cmpGuessMap`);
el usuario lo confirma y queda guardado en el proveedor (`mapping.cols`).
Cuando la detección elige mal una columna o no sale ningún producto, este
script muestra el contenido crudo del archivo para diagnosticar el problema.

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

1. **Encabezado real**: `cmpGridHeader` busca en las primeras 40 filas la
   que tiene más palabras típicas (producto, descripción, precio, neto, final,
   código, UxB, bulto…). Si el archivo no trae encabezado, el nombre sale de la
   columna con más texto y el precio de la columna con más números.
2. **Varias columnas de precio**: se prefiere "final" > "neto" > "precio" >
   "lista"; si hay por unidad y por bulto, decide la tilde "precio por unidad"
   del proveedor.
3. **Formato de precio**: separador de miles/decimales (`1.250,50` vs
   `1250.50`), texto pegado como "$ 1250" o "1250 c/IVA" (`cmpParsePrice`).

## Salidas típicas al usuario

- Casi siempre alcanza con corregir la columna en los desplegables del paso
  "Columnas": se guarda para el proveedor y la próxima lista entra sola.
- Si la heurística falla seguido con un formato real, ajustar `cmpGuessMap`
  en `public/index.html`.
- PDFs con columnas desalineadas: botón "Que lo lea la IA" (procesa por partes,
  tiene costo).

Requiere el devDependency `xlsx` del proyecto (ya instalado en
`package.json`). Si falta, correr `npm install` en la raíz del repo.
