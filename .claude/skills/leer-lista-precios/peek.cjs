// Uso: node peek.js "ruta/al/archivo.xls" [filas]
// Muestra encabezados y primeras filas de cada hoja de un xls/xlsx/csv.
const path = require('path');
const fs = require('fs');
const XLSX = require(path.join(__dirname, '..', '..', '..', 'node_modules', 'xlsx'));

const file = process.argv[2];
const nRows = parseInt(process.argv[3] || '8', 10);
if (!file) { console.error('Uso: node peek.js <archivo> [filas]'); process.exit(1); }

const buf = fs.readFileSync(file);
const wb = XLSX.read(buf, { type: 'buffer' });
wb.SheetNames.forEach(name => {
  const ws = wb.Sheets[name];
  const data = XLSX.utils.sheet_to_json(ws, { header: 1, defval: '' });
  console.log(`\n=== Hoja: ${name} (${data.length} filas) ===`);
  data.slice(0, nRows).forEach((row, i) => console.log(i, JSON.stringify(row)));
});
