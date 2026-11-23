@echo off
rem Sabores Royal - Sincroniza productos y precios de StarPOS con la app.
rem Se baja desde Admin > Catalogo del local. Doble clic: se instala en
rem C:\SaboresRoyal, queda corriendo solo cada 15 minutos y sincroniza ahora.
set "SR_SELF=%~f0"
set "SR_MODO=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:SR_SELF,[Text.Encoding]::UTF8); $i=$s.IndexOf('#__PS'+'__#'); Invoke-Expression $s.Substring($i)"
exit /b %errorlevel%
#__PS__#
$ErrorActionPreference = 'Stop'
$TOKEN = '__TOKEN__'
$SUPA  = 'https://topgunweqeztedhhthbl.supabase.co'
$ANON  = '__ANON__'
$DIR   = 'C:\SaboresRoyal'
$DEST  = Join-Path $DIR 'sincronizar-starpos.bat'
$LOG   = Join-Path $DIR 'sincronizar.log'
$auto  = ($env:SR_MODO -eq 'auto')
$LOTE  = 300

function Escribir($msg){
  $linea = (Get-Date -Format 'dd/MM/yyyy HH:mm:ss') + '  ' + $msg
  if(-not $auto){ Write-Host $msg }
  try{
    if((Test-Path $LOG) -and (Get-Item $LOG).Length -gt 1MB){ Move-Item $LOG ($LOG + '.viejo') -Force }
    Add-Content -Path $LOG -Value $linea -Encoding UTF8
  }catch{}
}
function Terminar($codigo){
  # Se suelta el candado antes de esperar el Enter: una ventana abierta no frena las pasadas siguientes.
  if($script:mutex){ try{ $script:mutex.ReleaseMutex() }catch{} }
  if(-not $auto){ Write-Host ''; Read-Host 'Toca Enter para cerrar' | Out-Null }
  exit $codigo
}

# Que no corran dos a la vez (si una pasada tarda, la siguiente se saltea).
$mutex = New-Object Threading.Mutex($false, 'SaboresRoyalSincronizarStarPOS')
if(-not $mutex.WaitOne(0)){ if(-not $auto){ Write-Host 'Ya se esta sincronizando, espera un momento.' }; Terminar 0 }

# ---------- Instalacion (la primera vez, o al bajar una version nueva) ----------
if($env:SR_SELF -ne $DEST){
  if(-not $auto){ Write-Host 'Instalando en C:\SaboresRoyal ...' }
  New-Item -ItemType Directory -Force -Path $DIR | Out-Null
  Copy-Item -Path $env:SR_SELF -Destination $DEST -Force
  # Quita la marca "bajado de internet": si no, Windows pregunta antes de cada pasada automática.
  try{ Unblock-File -Path $DEST }catch{}
  $vbs = Join-Path $DIR 'sincronizar-oculto.vbs'
  Set-Content -Path $vbs -Encoding ASCII -Value 'CreateObject("WScript.Shell").Run """C:\SaboresRoyal\sincronizar-starpos.bat"" auto", 0, False'
  & schtasks.exe /Create /F /SC MINUTE /MO 5 /TN 'SaboresRoyal Sincronizar StarPOS' /TR 'wscript.exe C:\SaboresRoyal\sincronizar-oculto.vbs' | Out-Null
  if($LASTEXITCODE -ne 0){ Write-Host 'Aviso: no se pudo programar la sincronizacion automatica (Programador de tareas).' }
  try{
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Sincronizar StarPOS.lnk'))
    $lnk.TargetPath = $DEST; $lnk.WorkingDirectory = $DIR; $lnk.Save()
  }catch{}
  Escribir 'Instalado. Las ventas se mandan cada 5 minutos y los productos cada 15; el icono "Sincronizar StarPOS" del escritorio lo hace al momento.'
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ 'apikey' = $ANON; 'Authorization' = 'Bearer ' + $ANON }
function Rpc($fn, $body){
  $json  = ConvertTo-Json -InputObject $body -Depth 5 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  return Invoke-RestMethod -Method Post -Uri ($SUPA + '/rest/v1/rpc/' + $fn) -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 120
}
function Registrar($ok, $resumen, $err){
  try{ Rpc 'starpos_sync_registrar' @{ p_token = $TOKEN; p_ok = $ok; p_resumen = $resumen; p_error = $err } | Out-Null }catch{}
}

# ---------- Leer de StarPOS ----------
$psql = 'C:\PostgreSQL\8.4\bin\psql.exe'
if(-not (Test-Path $psql)){
  $alt = Get-ChildItem -Path 'C:\PostgreSQL','C:\Program Files\PostgreSQL','C:\Program Files (x86)\PostgreSQL' -Filter psql.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if($alt){ $psql = $alt.FullName } else { $psql = $null }
}
function Consultar($sql){
  if(-not $psql){ throw 'No encuentro psql.exe de PostgreSQL en esta PC (tiene que ser la PC donde esta la base de StarPOS).' }
  $sqlFile = Join-Path $DIR 'consulta.sql'
  [IO.File]::WriteAllText($sqlFile, 'COPY (' + $sql + ') TO STDOUT WITH CSV HEADER;', (New-Object Text.UTF8Encoding($false)))
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $psql
  $psi.Arguments = '-h 127.0.0.1 -U admin -d starpos -X -q -f "' + $sqlFile + '"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.EnvironmentVariables['PGPASSWORD'] = '__PGPASS__'
  $psi.EnvironmentVariables['PGCLIENTENCODING'] = 'UTF8'
  $proc = [Diagnostics.Process]::Start($psi)
  $errTask = $proc.StandardError.ReadToEndAsync()
  $salida = $proc.StandardOutput.ReadToEnd()
  $proc.WaitForExit()
  if($proc.ExitCode -ne 0){ throw ('StarPOS no respondio: ' + $errTask.Result) }
  return @(($salida -split "`r?`n") | Where-Object { $_ -ne '' } | ConvertFrom-Csv)
}

# Estado (qué se mandó y cuándo), para mandar solo lo nuevo.
$ESTADO = Join-Path $DIR 'estado.json'
$est = $null
try{ if(Test-Path $ESTADO){ $est = (Get-Content $ESTADO | Out-String) | ConvertFrom-Json } }catch{}
function EstadoValor($k){ if($est -and $est.$k){ return [string]$est.$k }; return '' }
$estNuevo = @{ inicial = (EstadoValor 'inicial'); productos = (EstadoValor 'productos'); stock = (EstadoValor 'stock') }
function GuardarEstado(){ try{ ConvertTo-Json -InputObject $estNuevo | Set-Content -Path $ESTADO -Encoding UTF8 }catch{} }
function HaceMinutos($iso){
  if(-not $iso){ return 99999 }
  try{ return ((Get-Date) - [datetime]::ParseExact($iso, 'yyyy-MM-dd HH:mm:ss', $null)).TotalMinutes }catch{ return 99999 }
}
$ahoraTxt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

$TX = '(SELECT pt.product, max(t.rate) AS rate FROM products_taxes pt JOIN taxes t ON t.id = pt.taxid GROUP BY pt.product)'

# ---------- 1) Productos y precios (cada 15 minutos, o siempre a mano) ----------
function SincronizarProductos(){
  $consulta = @'
SELECT p.id, p.reference AS ref, p.code, p.type AS tipo, p.name AS nombre, c.name AS cat, b.name AS marca,
  coalesce(tx.rate, 0.21) AS iva,
  round((pr.n1 * (1 + coalesce(tx.rate, 0.21)))::numeric, 2) AS precio,
  round((pr.n2 * (1 + coalesce(tx.rate, 0.21)))::numeric, 2) AS precio2,
  q.qmin, pc.codigos, v.uv
FROM products p
LEFT JOIN categories c ON c.id = p.category
LEFT JOIN brands b ON b.id = p.brand
LEFT JOIN __TX__ tx ON tx.product = p.id
LEFT JOIN (SELECT product, max(CASE WHEN pricelist = '1' THEN pricesell END) AS n1, max(CASE WHEN pricelist = '2' THEN pricesell END) AS n2
             FROM products_prices GROUP BY product) pr ON pr.product = p.id
LEFT JOIN (SELECT product_id, min(quantity) AS qmin FROM products_sales_by_qty GROUP BY product_id) q ON q.product_id = p.id
LEFT JOIN (SELECT product, array_to_string(array_agg(code || ':' || quantity), '|') AS codigos FROM products_codes GROUP BY product) pc ON pc.product = p.id
LEFT JOIN (SELECT tl.product, to_char(max(r.datenew), 'YYYY-MM-DD') AS uv FROM receipts r JOIN ticketlines tl ON tl.ticket = r.id
            WHERE r.datenew > now() - interval '3 days' GROUP BY tl.product) v ON v.product = p.id
WHERE p.active
'@
  if(-not $auto){ Write-Host 'Leyendo productos de StarPOS ...' }
  $filas = Consultar ($consulta.Replace('__TX__', $TX))
  if($filas.Count -lt 100){ throw ('StarPOS devolvio solo ' + $filas.Count + ' productos; no se sincroniza por las dudas.') }
  if(-not $auto){ Write-Host ($filas.Count.ToString() + ' productos activos en StarPOS. Mandando a la app ...') }
  $tot = @{ recibidos = 0; nuevos = 0; precios = 0; vinculados = 0 }
  $cambios = New-Object System.Collections.ArrayList
  for($i = 0; $i -lt $filas.Count; $i += $LOTE){
    $fin  = [Math]::Min($i + $LOTE, $filas.Count) - 1
    # (no se llama $lote: PowerShell no distingue mayúsculas y pisaría a $LOTE)
    $paquete = @($filas[$i..$fin])
    $r = Rpc 'starpos_sync_lote' @{ p_token = $TOKEN; p_rows = $paquete }
    foreach($k in @('recibidos','nuevos','precios','vinculados')){ $tot[$k] += [int]$r.$k }
    foreach($c in @($r.cambios)){ if($c -and $cambios.Count -lt 60){ [void]$cambios.Add($c) } }
    if(-not $auto){ Write-Host ('  ' + ($fin + 1) + ' de ' + $filas.Count) }
  }
  $resumen = @{ recibidos = $tot.recibidos; nuevos = $tot.nuevos; precios = $tot.precios; vinculados = $tot.vinculados; cambios = @($cambios) }
  Registrar $true $resumen $null
  Escribir ('Productos: ' + $tot.nuevos + ' nuevos, ' + $tot.precios + ' precios cambiados, ' + $tot.vinculados + ' que ya estaban en la tienda.')
  if(-not $auto -and $cambios.Count){
    Write-Host ''; Write-Host 'Precios que cambiaron:'
    foreach($c in $cambios){ Write-Host ('  ' + $c.nombre + ':  $' + ('{0:N2}' -f [double]$c.antes) + '  ->  $' + ('{0:N2}' -f [double]$c.ahora)) }
  }
}

# ---------- 2) Ventas, turnos, anulaciones, retiros y stock (cada 5 minutos) ----------
function MandarDatos($tipo, $filas){
  $n = 400
  for($i = 0; $i -lt $filas.Count; $i += $n){
    $fin = [Math]::Min($i + $n, $filas.Count) - 1
    $paquete = @($filas[$i..$fin])
    Rpc 'starpos_sync_datos' @{ p_token = $TOKEN; p_tipo = $tipo; p_rows = $paquete } | Out-Null
  }
  if(-not $auto){ Write-Host ('  ' + $tipo + ': ' + $filas.Count) }
}
function SincronizarDatos(){
  $completo = -not $estNuevo.inicial
  if($completo){
    if(-not $auto){ Write-Host 'Primera vez: mandando todo el historial de ventas (puede tardar unos minutos) ...' }
    $cutTurnos = "'2000-01-01'"; $cutProd = 'current_date - 90'; $cutTickets = 'current_date - 15'; $cutOtros = "'2000-01-01'"; $cutDias = "'2000-01-01'"
  }else{
    if(-not $auto){ Write-Host 'Mandando ventas nuevas ...' }
    $cutTurnos = "now() - interval '2 days'"; $cutProd = 'current_date - 1'; $cutTickets = 'current_date - 1'; $cutOtros = 'current_date - 7'; $cutDias = 'current_date - 1'
  }
  $turnosDe = '(SELECT money FROM closedcash WHERE datestart >= ' + $cutTurnos + ')'
  $F = "'YYYY-MM-DD HH24:MI:SS'"

  MandarDatos 'turnos' (Consultar ("SELECT c.money, c.host AS caja, c.hostsequence AS numero, to_char(c.datestart, $F) AS inicio, to_char(c.dateend, $F) AS fin, " +
    "tk.cajeros, coalesce(tk.tickets, 0) AS tickets, round(coalesce(pg.total, 0)::numeric, 2) AS total, round(coalesce(pg.retiros, 0)::numeric, 2) AS retiros, coalesce(vo.anulados, 0) AS anulados " +
    "FROM closedcash c " +
    "LEFT JOIN (SELECT r.money, count(*) AS tickets, array_to_string(array_agg(DISTINCT pe.name), ', ') AS cajeros FROM receipts r JOIN tickets t ON t.id = r.id LEFT JOIN people pe ON pe.id = t.person " +
    "  WHERE r.money IN $turnosDe AND t.tickettype = 0 GROUP BY r.money) tk ON tk.money = c.money " +
    "LEFT JOIN (SELECT r.money, sum(CASE WHEN p.payment NOT IN ('cashout','cashin') THEN p.total ELSE 0 END) AS total, sum(CASE WHEN p.payment = 'cashout' THEN -p.total ELSE 0 END) AS retiros " +
    "  FROM receipts r JOIN payments p ON p.receipt = r.id WHERE r.money IN $turnosDe GROUP BY r.money) pg ON pg.money = c.money " +
    "LEFT JOIN (SELECT r.money, count(*) AS anulados FROM receipts r JOIN void_tickets v ON v.id = r.id WHERE r.money IN $turnosDe GROUP BY r.money) vo ON vo.money = c.money " +
    "WHERE c.money IN $turnosDe"))

  MandarDatos 'medios' (Consultar ("SELECT r.money, coalesce(pm.name, p.payment) AS medio, round(sum(p.total)::numeric, 2) AS total, count(DISTINCT r.id) AS cant " +
    "FROM receipts r JOIN payments p ON p.receipt = r.id LEFT JOIN paymentmethods pm ON pm.id = p.paymentmethod " +
    "WHERE r.money IN $turnosDe AND p.payment NOT IN ('cashout','cashin') GROUP BY r.money, coalesce(pm.name, p.payment)"))

  # Ventas por día (fecha del ticket, no del turno: hay turnos que pasan de un día al otro).
  MandarDatos 'vhoras' (Consultar ("SELECT to_char(r.datenew, 'YYYY-MM-DD') AS fecha, extract(hour from r.datenew)::int AS hora, coalesce(c.host, '') AS caja, " +
    "round(sum(p.total)::numeric, 2) AS total, count(DISTINCT r.id) AS tickets " +
    "FROM receipts r JOIN payments p ON p.receipt = r.id LEFT JOIN closedcash c ON c.money = r.money " +
    "WHERE r.datenew >= $cutDias AND p.payment NOT IN ('cashout','cashin') " +
    "GROUP BY to_char(r.datenew, 'YYYY-MM-DD'), extract(hour from r.datenew)::int, coalesce(c.host, '')"))

  MandarDatos 'vmedios' (Consultar ("SELECT to_char(r.datenew, 'YYYY-MM-DD') AS fecha, coalesce(c.host, '') AS caja, coalesce(pm.name, p.payment) AS medio, " +
    "round(sum(p.total)::numeric, 2) AS total, count(DISTINCT r.id) AS cant " +
    "FROM receipts r JOIN payments p ON p.receipt = r.id LEFT JOIN closedcash c ON c.money = r.money LEFT JOIN paymentmethods pm ON pm.id = p.paymentmethod " +
    "WHERE r.datenew >= $cutDias AND p.payment NOT IN ('cashout','cashin') " +
    "GROUP BY to_char(r.datenew, 'YYYY-MM-DD'), coalesce(c.host, ''), coalesce(pm.name, p.payment)"))

  MandarDatos 'prod' (Consultar ("SELECT to_char(r.datenew, 'YYYY-MM-DD') AS fecha, tl.product AS id, max(coalesce(pr.name, tl.description)) AS nombre, " +
    "round(sum(tl.units)::numeric, 3) AS unidades, round(sum(tl.units * tl.price * (1 + coalesce(tx.rate, 0.21)))::numeric, 2) AS total " +
    "FROM receipts r JOIN ticketlines tl ON tl.ticket = r.id LEFT JOIN products pr ON pr.id = tl.product LEFT JOIN $TX tx ON tx.product = tl.product " +
    "WHERE r.datenew >= $cutProd AND tl.product IS NOT NULL GROUP BY to_char(r.datenew, 'YYYY-MM-DD'), tl.product"))

  MandarDatos 'tickets' (Consultar ("SELECT r.id, to_char(r.datenew, $F) AS fecha, r.money, c.host AS caja, pe.name AS cajero, t.ticketid AS numero, t.tickettype AS tipo, " +
    "round(coalesce(pa.total, 0)::numeric, 2) AS total, pa.medios " +
    "FROM receipts r JOIN tickets t ON t.id = r.id LEFT JOIN closedcash c ON c.money = r.money LEFT JOIN people pe ON pe.id = t.person " +
    "LEFT JOIN (SELECT p.receipt, sum(p.total) AS total, array_to_string(array_agg(coalesce(pm.name, p.payment) || ':' || round(p.total::numeric, 2)), '|') AS medios " +
    "  FROM payments p JOIN receipts r2 ON r2.id = p.receipt LEFT JOIN paymentmethods pm ON pm.id = p.paymentmethod WHERE r2.datenew >= $cutTickets GROUP BY p.receipt) pa ON pa.receipt = r.id " +
    "WHERE r.datenew >= $cutTickets"))

  MandarDatos 'lineas' (Consultar ("SELECT tl.ticket, tl.line AS linea, coalesce(pr.name, tl.description) AS descripcion, round(tl.units::numeric, 3) AS unidades, " +
    "round((tl.units * tl.price * (1 + coalesce(tx.rate, 0.21)))::numeric, 2) AS total " +
    "FROM receipts r JOIN ticketlines tl ON tl.ticket = r.id LEFT JOIN products pr ON pr.id = tl.product LEFT JOIN $TX tx ON tx.product = tl.product " +
    "WHERE r.datenew >= $cutTickets"))

  MandarDatos 'anulaciones' (Consultar ("SELECT v.id, to_char(r.datenew, $F) AS fecha, c.host AS caja, pe.name AS cajero, v.ticketid AS numero, " +
    "round(coalesce(sum(vl.units * vl.price * (1 + coalesce(tx.rate, 0.21))), 0)::numeric, 2) AS total, count(vl.line) AS items, " +
    "array_to_string(array_agg(vl.description || ' x' || rtrim(rtrim(round(vl.units::numeric, 3)::text, '0'), '.')), ' | ') AS detalle " +
    "FROM void_tickets v JOIN receipts r ON r.id = v.id LEFT JOIN closedcash c ON c.money = r.money LEFT JOIN people pe ON pe.id = v.person " +
    "LEFT JOIN void_ticketlines vl ON vl.ticket = v.id LEFT JOIN $TX tx ON tx.product = vl.product " +
    "WHERE r.datenew >= $cutOtros GROUP BY v.id, r.datenew, c.host, pe.name, v.ticketid"))

  MandarDatos 'retiros' (Consultar ("SELECT r.id, to_char(r.datenew, $F) AS fecha, c.host AS caja, pe.name AS cajero, max(cm.cashmovementtype) AS tipo, " +
    "round(coalesce(-sum(p.total), 0)::numeric, 2) AS monto, max(cm.description) AS descripcion " +
    "FROM cashmovement cm JOIN receipts r ON r.id = cm.receipt LEFT JOIN closedcash c ON c.money = r.money LEFT JOIN people pe ON pe.id = cm.person " +
    "LEFT JOIN payments p ON p.receipt = r.id WHERE r.datenew >= $cutOtros GROUP BY r.id, r.datenew, c.host, pe.name"))

  if($completo -or -not $auto -or (HaceMinutos $estNuevo.stock) -ge 55){
    MandarDatos 'stock' (Consultar ("SELECT s.product AS id, p.name AS nombre, round(sum(s.units)::numeric, 3) AS unidades " +
      "FROM stockcurrent s JOIN products p ON p.id = s.product WHERE p.active GROUP BY s.product, p.name"))
    $estNuevo.stock = $ahoraTxt
  }
  if($completo){ $estNuevo.inicial = $ahoraTxt }
  GuardarEstado
  Escribir 'Ventas, turnos, anulaciones y retiros: al dia.'
}

try{
  if(-not $auto -or (HaceMinutos $estNuevo.productos) -ge 14){
    SincronizarProductos
    $estNuevo.productos = $ahoraTxt
    GuardarEstado
  }
  try{
    SincronizarDatos
  }catch{
    $m = $_.Exception.Message
    if($_.ErrorDetails -and $_.ErrorDetails.Message){ $m = $m + ' ' + $_.ErrorDetails.Message }
    # Si todavía no se corrió supabase-migration-starpos-datos.sql, los productos siguen andando igual.
    if($m -match 'starpos_sync_datos'){ Escribir 'Aviso: falta correr supabase-migration-starpos-datos.sql en Supabase (ventas).' }
    else { throw }
  }
  Terminar 0
}catch{
  $msg = $_.Exception.Message
  if($_.ErrorDetails -and $_.ErrorDetails.Message){ $msg = $msg + ' ' + $_.ErrorDetails.Message }
  Escribir ('ERROR: ' + $msg)
  Registrar $false $null $msg
  Terminar 1
}
