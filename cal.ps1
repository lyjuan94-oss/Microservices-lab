$baseUrl = "https://aas-sonar-pr.azure-paas.com"
$token = $env:SONARQUBE_TOKEN

$b64 = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${token}:")
)

$headers = @{
    Authorization = "Basic $b64"
    Accept = "application/json"
}

try {
    $response = Invoke-RestMethod `
        -Uri "$baseUrl/api/system/info" `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop

    Write-Host "Version: $($response.System.Version)"
    Write-Host "Edition: $($response.System.Edition)"
    $response | ConvertTo-Json -Depth 5
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) {
        Write-Host $_.ErrorDetails.Message
    }
}
