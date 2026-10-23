
$baseUrl = "https://aas-sonar-pr.azure-paas.com"
$projectName = "aa-belgium-internal-Adhesions"
$token = $env:SONARQUBE_TOKEN

$b64 = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${token}:")
)

$headers = @{
    Authorization = "Basic $b64"
    Accept = "application/json"
}

$encodedName = [Uri]::EscapeDataString($projectName)

$response = Invoke-RestMethod `
    -Uri "$baseUrl/api/projects/search?projects=$encodedName" `
    -Method GET `
    -Headers $headers

$response.components |
    Select-Object name, key, qualifier |
    Format-Table -AutoSize
