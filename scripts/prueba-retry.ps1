param(
    [int]$MaxIntentos = 4,
    [int]$Pedidos = 10,
    [string]$BaseUrl = "http://localhost:5050",
    [string]$ApiKey = "dev-key-12345"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Net.Http
# Sin esto, Windows PowerShell 5.1 solo manda 2 conexiones a la vez
[System.Net.ServicePointManager]::DefaultConnectionLimit = 50

function ObtenerStock {
    $resultado = 'SELECT "Stock" FROM "Productos" WHERE "Id" = ''prod-001'';' |
        docker compose exec -T db psql -U postgres -d maquetaapi -t -A
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo consultar el stock directamente en PostgreSQL."
    }
    $stock = $resultado | Where-Object { $_.Trim() -match '^\d+$' } | Select-Object -Last 1
    if ($null -eq $stock) {
        throw "No se encontró el stock de prod-001 en PostgreSQL."
    }
    return [int]$stock
}

function ContarReintentos {
    $logs = docker compose logs api1 api2
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudieron consultar los logs de las réplicas."
    }
    return @($logs | Select-String "Reintento \d+/\d+").Count
}

# 1. Configurar los intentos en la configuracion externa (sin reiniciar nada)
"UPDATE config.parametros SET ""Valor"" = '$MaxIntentos' WHERE ""Clave"" = 'reintentos.maxIntentos';" |
    docker compose exec -T db psql -U postgres -d maquetaapi | Out-Null

$stockAntes = ObtenerStock
$reintentosAntes = ContarReintentos

# 2. Mandar N pedidos del mismo producto al mismo tiempo
$json = '{"clienteId":"cliente-test-001","items":[{"productoId":"prod-001","cantidad":1}]}'
$cliente = [System.Net.Http.HttpClient]::new()
$cliente.DefaultRequestHeaders.Add("X-API-Key", $ApiKey)
$tareas = @(1..$Pedidos | ForEach-Object {
    $contenido = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json")
    $cliente.PostAsync("$BaseUrl/api/pedidos", $contenido)
})
[System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tareas)
$codigos = $tareas | ForEach-Object { [int]$_.Result.StatusCode }

# 3. Resultados
$exitosos = @($codigos | Where-Object { $_ -eq 200 }).Count
$stockDespues = ObtenerStock
$bajo = $stockAntes - $stockDespues
$reintentos = (ContarReintentos) - $reintentosAntes

Write-Host ""
Write-Host "MaxIntentos configurado : $MaxIntentos"
Write-Host "Pedidos enviados        : $Pedidos"
$codigos | Group-Object | ForEach-Object { Write-Host "  HTTP $($_.Name): $($_.Count)" }
$tareas | Where-Object { [int]$_.Result.StatusCode -ne 200 } |
    ForEach-Object { $_.Result.Content.ReadAsStringAsync().Result } |
    Group-Object | ForEach-Object { Write-Host "  [$($_.Count)x] $($_.Name)" }
Write-Host "Reintentos registrados  : $reintentos"
Write-Host "Stock antes / despues   : $stockAntes / $stockDespues (bajo $bajo)"
if ($bajo -eq $exitosos) {
    Write-Host "OK: el stock bajo exactamente lo que suman los pedidos exitosos" -ForegroundColor Green
} else {
    throw "El stock bajo $bajo unidades, pero hubo $exitosos pedidos exitosos."
}
if ($reintentos -le 0) {
    throw "No se observó ningún reintento; la prueba no demostró el patrón Retry."
}
Write-Host "OK: se observaron $reintentos reintentos." -ForegroundColor Green