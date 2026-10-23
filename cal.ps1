
$ErrorActionPreference = "Stop"

$baseUrl = "https://aas-sonar-pr.azure-paas.com"
$token = $env:SONARQUBE_TOKEN

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "ERROR: SONARQUBE_TOKEN no está definida." -ForegroundColor Red
    return
}

$encoded = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${token}:")
)

$headers = @{
    Authorization = "Basic $encoded"
    Accept = "application/json"
}

$endpoints = @(
    "/api/server/version",
    "/api/alm_settings/list_definitions"
)

foreach ($endpoint in $endpoints) {
    $uri = "$baseUrl$endpoint"

    Write-Host "`nConsultando: $endpoint" -ForegroundColor Cyan

    try {
        $response = Invoke-WebRequest `
            -Uri $uri `
            -Method Get `
            -Headers $headers `
            -TimeoutSec 30

        Write-Host "HTTP: $([int]$response.StatusCode)"
        Write-Host "Longitud del contenido: $($response.Content.Length)"

        if ([string]::IsNullOrWhiteSpace($response.Content)) {
            Write-Host "El servidor devolvió un cuerpo vacío." -ForegroundColor Yellow
        }
        else {
            Write-Host $response.Content
        }
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red

        if ($_.Exception.Response) {
            Write-Host "HTTP: $([int]$_.Exception.Response.StatusCode)"
        }

        if ($_.ErrorDetails.Message) {
            Write-Host "Detalle: $($_.ErrorDetails.Message)"
        }
    }
}
