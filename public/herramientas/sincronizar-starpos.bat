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
  $vbs = Join-Path $DIR 'sincronizar-oculto.vbs'
  Set-Content -Path $vbs -Encoding ASCII -Value 'CreateObject("WScript.Shell").Run """C:\SaboresRoyal\sincronizar-starpos.bat"" auto", 0, False'
  & schtasks.exe /Create /F /SC MINUTE /MO 15 /TN 'SaboresRoyal Sincronizar StarPOS' /TR 'wscript.exe C:\SaboresRoyal\sincronizar-oculto.vbs' | Out-Null
  if($LASTEXITCODE -ne 0){ Write-Host 'Aviso: no se pudo programar la sincronizacion automatica (Programador de tareas).' }
  try{
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Sincronizar StarPOS.lnk'))
    $lnk.TargetPath = $DEST; $lnk.WorkingDirectory = $DIR; $lnk.Save()
  }catch{}
  Escribir 'Instalado. Se sincroniza solo cada 15 minutos; el icono "Sincronizar StarPOS" del escritorio lo hace al momento.'
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

try{
  # ---------- 1) Leer StarPOS ----------
  $psql = 'C:\PostgreSQL\8.4\bin\psql.exe'
  if(-not (Test-Path $psql)){
    $alt = Get-ChildItem -Path 'C:\PostgreSQL','C:\Program Files\PostgreSQL','C:\Program Files (x86)\PostgreSQL' -Filter psql.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $alt){ throw 'No encuentro psql.exe de PostgreSQL en esta PC (tiene que ser la PC donde esta la base de StarPOS).' }
    $psql = $alt.FullName
  }
  $consulta = @'
COPY (
SELECT p.id, p.reference AS ref, p.code, p.type AS tipo, p.name AS nombre, c.name AS cat, b.name AS marca,
  coalesce(tx.rate, 0.21) AS iva,
  round((pr.n1 * (1 + coalesce(tx.rate, 0.21)))::numeric, 2) AS precio,
  round((pr.n2 * (1 + coalesce(tx.rate, 0.21)))::numeric, 2) AS precio2,
  q.qmin, pc.codigos, v.uv
FROM products p
LEFT JOIN categories c ON c.id = p.category
LEFT JOIN brands b ON b.id = p.brand
LEFT JOIN (SELECT pt.product, max(t.rate) AS rate FROM products_taxes pt JOIN taxes t ON t.id = pt.taxid GROUP BY pt.product) tx ON tx.product = p.id
LEFT JOIN (SELECT product, max(CASE WHEN pricelist = '1' THEN pricesell END) AS n1, max(CASE WHEN pricelist = '2' THEN pricesell END) AS n2
             FROM products_prices GROUP BY product) pr ON pr.product = p.id
LEFT JOIN (SELECT product_id, min(quantity) AS qmin FROM products_sales_by_qty GROUP BY product_id) q ON q.product_id = p.id
LEFT JOIN (SELECT product, array_to_string(array_agg(code || ':' || quantity), '|') AS codigos FROM products_codes GROUP BY product) pc ON pc.product = p.id
LEFT JOIN (SELECT tl.product, to_char(max(r.datenew), 'YYYY-MM-DD') AS uv FROM receipts r JOIN ticketlines tl ON tl.ticket = r.id
            WHERE r.datenew > now() - interval '3 days' GROUP BY tl.product) v ON v.product = p.id
WHERE p.active
) TO STDOUT WITH CSV HEADER;
'@
  $sqlFile = Join-Path $DIR 'consulta.sql'
  [IO.File]::WriteAllText($sqlFile, $consulta, (New-Object Text.UTF8Encoding($false)))

  if(-not $auto){ Write-Host 'Leyendo productos de StarPOS ...' }
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

  $filas = @(($salida -split "`r?`n") | Where-Object { $_ -ne '' } | ConvertFrom-Csv)
  if($filas.Count -lt 100){ throw ('StarPOS devolvio solo ' + $filas.Count + ' productos; no se sincroniza por las dudas.') }
  if(-not $auto){ Write-Host ($filas.Count.ToString() + ' productos activos en StarPOS. Mandando a la app ...') }

  # ---------- 2) Mandar a la app de a lotes ----------
  $tot = @{ recibidos = 0; nuevos = 0; precios = 0; vinculados = 0 }
  $cambios = New-Object System.Collections.ArrayList
  for($i = 0; $i -lt $filas.Count; $i += $LOTE){
    $fin  = [Math]::Min($i + $LOTE, $filas.Count) - 1
    $lote = @($filas[$i..$fin])
    $r = Rpc 'starpos_sync_lote' @{ p_token = $TOKEN; p_rows = $lote }
    foreach($k in @('recibidos','nuevos','precios','vinculados')){ $tot[$k] += [int]$r.$k }
    foreach($c in @($r.cambios)){ if($c -and $cambios.Count -lt 60){ [void]$cambios.Add($c) } }
    if(-not $auto){ Write-Host ('  ' + ($fin + 1) + ' de ' + $filas.Count) }
  }
  $resumen = @{ recibidos = $tot.recibidos; nuevos = $tot.nuevos; precios = $tot.precios; vinculados = $tot.vinculados; cambios = @($cambios) }
  Registrar $true $resumen $null
  Escribir ('Listo: ' + $tot.nuevos + ' productos nuevos, ' + $tot.precios + ' precios cambiados, ' + $tot.vinculados + ' que ya estaban en la tienda.')
  if(-not $auto -and $cambios.Count){
    Write-Host ''; Write-Host 'Precios que cambiaron:'
    foreach($c in $cambios){ Write-Host ('  ' + $c.nombre + ':  $' + ('{0:N2}' -f [double]$c.antes) + '  ->  $' + ('{0:N2}' -f [double]$c.ahora)) }
  }
  Terminar 0
}catch{
  $msg = $_.Exception.Message
  if($_.ErrorDetails -and $_.ErrorDetails.Message){ $msg = $msg + ' ' + $_.ErrorDetails.Message }
  Escribir ('ERROR: ' + $msg)
  Registrar $false $null $msg
  Terminar 1
}
