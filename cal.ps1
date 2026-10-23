
param(
    [string]$SonarQubeUrl = "https://aas-sonar-pr.azure-paas.com"
)

$ErrorActionPreference = "Stop"
$baseUrl = $SonarQubeUrl.TrimEnd("/")
$token = $env:SONARQUBE_TOKEN

if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Missing SONARQUBE_TOKEN."
}

$b64 = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${token}:")
)

$headers = @{
    Authorization = "Basic $b64"
    Accept = "application/json"
}

$uri = "$baseUrl/api/alm_settings/list_definitions"

try {
    $response = Invoke-RestMethod `
        -Uri $uri `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop

    Write-Host "`nALM configurations:" -ForegroundColor Cyan

    $response | ConvertTo-Json -Depth 20

    if ($response.azure) {
        Write-Host "`nAzure DevOps configuration keys:" -ForegroundColor Green

        foreach ($configuration in $response.azure) {
            Write-Host "Key: $($configuration.key)"
            Write-Host "URL: $($configuration.url)"
        }
    }
    else {
        Write-Host "No Azure DevOps configuration found in response." `
            -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red

    if ($_.ErrorDetails.Message) {
        Write-Host $_.ErrorDetails.Message
    }
}
