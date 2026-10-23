
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# Configuration
# ============================================================

$baseUrl = "https://aas-sonar-pr.azure-paas.com".TrimEnd("/")
$projectKey = "aa-belgium-internal-Adhesions"

# Authentication: SonarQube token
$token = $env:SONARQUBE_TOKEN

if ([string]::IsNullOrWhiteSpace($token)) {
    throw "SONARQUBE_TOKEN no está definido en las variables de entorno."
}

$basicAuth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${token}:")
)

$headers = @{
    Authorization = "Basic $basicAuth"
    Accept        = "application/json"
}

# TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================
# Helper: display HTTP and connection errors
# ============================================================

function Show-RequestError {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-Host "`n--- Error details ---" -ForegroundColor Red
    Write-Host "Message: $($ErrorRecord.Exception.Message)"

    $response = $ErrorRecord.Exception.Response

    if ($null -ne $response) {
        try {
            $statusCode = [int]$response.StatusCode
            Write-Host "HTTP status: $statusCode"

            if ($response.ReasonPhrase) {
                Write-Host "Reason: $($response.ReasonPhrase)"
            }
        }
        catch {
            Write-Host "No se pudo leer el código HTTP."
        }

        # Read response body when available (.NET response types vary)
        try {
            if ($response -is [System.Net.Http.HttpResponseMessage]) {
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if (-not [string]::IsNullOrWhiteSpace($body)) {
                    Write-Host "Response body:"
                    Write-Host $body
                }
            }
            elseif ($response -is [System.Net.HttpWebResponse]) {
                $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
                try {
                    $body = $reader.ReadToEnd()
                    if (-not [string]::IsNullOrWhiteSpace($body)) {
                        Write-Host "Response body:"
                        Write-Host $body
                    }
                }
                finally {
                    $reader.Dispose()
                }
            }
        }
        catch {
            Write-Host "No se pudo leer el cuerpo de la respuesta."
        }
    }
    else {
        Write-Host "HTTP status: unavailable (no HTTP response received)"
    }

    if ($ErrorRecord.ErrorDetails -and
        -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        Write-Host "PowerShell error details:"
        Write-Host $ErrorRecord.ErrorDetails.Message
    }

    Write-Host "Category: $($ErrorRecord.CategoryInfo.Category)"
    Write-Host "FullyQualifiedErrorId: $($ErrorRecord.FullyQualifiedErrorId)"
}

# ============================================================
# 1. Check SonarQube server version
# ============================================================

Write-Host "`n[1/3] Checking SonarQube server..." -ForegroundColor Cyan

try {
    $version = Invoke-RestMethod `
        -Uri "$baseUrl/api/server/version" `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop

    Write-Host "SonarQube version: $version" -ForegroundColor Green
}
catch {
    Show-RequestError -ErrorRecord $_
    Write-Host "No se puede continuar sin confirmar la conexión."
    return
}

# ============================================================
# 2. Confirm the project exists
# ============================================================

Write-Host "`n[2/3] Checking SonarQube project..." -ForegroundColor Cyan

$encodedProjectKey = [uri]::EscapeDataString($projectKey)
$projectUri = "$baseUrl/api/projects/search?projects=$encodedProjectKey"

try {
    $projectResult = Invoke-RestMethod `
        -Uri $projectUri `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop

    $project = $projectResult.components |
        Where-Object { $_.key -eq $projectKey } |
        Select-Object -First 1

    if ($null -eq $project) {
        Write-Host "Project not found: $projectKey" -ForegroundColor Red
        Write-Host "No se realizarán cambios."
        return
    }

    Write-Host "Project found." -ForegroundColor Green
    Write-Host "Name: $($project.name)"
    Write-Host "Key:  $($project.key)"
}
catch {
    Show-RequestError -ErrorRecord $_
    Write-Host "No se pudo comprobar el proyecto. No se realizarán cambios."
    return
}

# ============================================================
# 3. Diagnose the existing Azure DevOps binding
# ============================================================

Write-Host "`n[3/3] Checking Azure DevOps binding..." -ForegroundColor Cyan

$bindingUri = "$baseUrl/api/alm_settings/get_binding?project=$encodedProjectKey"

try {
    $binding = Invoke-RestMethod `
        -Uri $bindingUri `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop

    Write-Host "`nThe project already has a binding:" -ForegroundColor Green
    $binding | ConvertTo-Json -Depth 10

    Write-Host "`nDiagnostic finished. No changes were made."
}
catch {
    $response = $_.Exception.Response
    $statusCode = $null

    if ($null -ne $response) {
        try {
            $statusCode = [int]$response.StatusCode
        }
        catch {
            $statusCode = $null
        }
    }

    if ($statusCode -eq 404) {
        Write-Host "`nSonarQube returned HTTP 404 for the binding." -ForegroundColor Yellow
        Write-Host "The project may not have an Azure DevOps binding."
        Write-Host "No POST request was sent."
    }
    else {
        Show-RequestError -ErrorRecord $_
        Write-Host "`nThe binding status could not be confirmed."
        Write-Host "No POST request was sent."
    }
}

Write-Host "`nDiagnostic complete. This script did not modify any bindings." -ForegroundColor Cyan
