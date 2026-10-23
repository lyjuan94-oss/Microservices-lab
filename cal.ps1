$ErrorActionPreference = "Stop"

$SonarQubeUrl = "https://aas-sonar-pr.azure-paas.com".TrimEnd("/")
$Token = $env:SONARQUBE_TOKEN

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "Define primero la variable SONARQUBE_TOKEN."
}

$basicAuth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${Token}:")
)

$headers = @{
    Authorization = "Basic $basicAuth"
    Accept        = "application/json"
}

$uri = "$SonarQubeUrl/api/alm_settings/list_definitions"

try {
    $response = Invoke-RestMethod `
        -Uri $uri `
        -Method Get `
        -Headers $headers `
        -TimeoutSec 60

    $response | ConvertTo-Json -Depth 10

} catch {
    Write-Host "Error consultando SonarQube:" -ForegroundColor Red
    Write-Host $_.Exception.Message

    if ($_.Exception.Response) {
        Write-Host "HTTP Status: $([int]$_.Exception.Response.StatusCode)"
    }

    if ($_.ErrorDetails.Message) {
        Write-Host "Response body:"
        Write-Host $_.ErrorDetails.Message
    }
}
