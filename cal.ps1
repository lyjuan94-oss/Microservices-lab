
$baseUrl = "https://aas-sonar-pr.azure-paas.com"
$projectKey = "aa-belgium-internal-Adhesions"
$token = $env:SONARQUBE_TOKEN

$b64 = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${token}:")
)

$headers = @{
    Authorization = "Basic $b64"
    Accept = "application/json"
}

$encodedKey = [Uri]::EscapeDataString($projectKey)
$uri = "$baseUrl/api/alm_settings/get_binding?project=$encodedKey"

try {
    $response = Invoke-RestMethod `
        -Uri $uri `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop

    $response | ConvertTo-Json -Depth 10
}
catch {
    Write-Host "HTTP/error: $($_.Exception.Message)" -ForegroundColor Yellow

    if ($_.ErrorDetails.Message) {
        Write-Host $_.ErrorDetails.Message
    }
}
