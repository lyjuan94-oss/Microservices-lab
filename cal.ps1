
param(
    [string]$SonarQubeUrl = "https://aas-sonar-pr.azure-paas.com",
    [string]$TokenOverride = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# 1. Configuration
# ------------------------------------------------------------

$script:BaseUrl = ([string]$SonarQubeUrl).Trim().TrimEnd("/")

# ------------------------------------------------------------
# 2. Authentication
# Same pattern as create-sonar-applications.ps1
# ------------------------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($TokenOverride)) {
    $env:SONARQUBE_TOKEN = $TokenOverride.Trim()
}
elseif ([string]::IsNullOrWhiteSpace($env:SONARQUBE_TOKEN)) {
    Write-Host "Missing token. Set SONARQUBE_TOKEN or use -TokenOverride." `
        -ForegroundColor Red
    exit 1
}

$token = $env:SONARQUBE_TOKEN.Trim()

$b64 = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${token}:")
)

$headers = @{
    Authorization = "Basic $b64"
    Accept        = "application/json"
}

# Preserve the TLS configuration used by your existing scripts.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor
        [Net.SecurityProtocolType]::Tls12
}
catch {
    Write-Host "Warning: Could not explicitly configure TLS 1.2."
}

try {
    [System.Net.WebRequest]::DefaultWebProxy.Credentials =
        [System.Net.CredentialCache]::DefaultNetworkCredentials
}
catch {
    # No action required.
}

# ------------------------------------------------------------
# 3. Diagnostic helper
# ------------------------------------------------------------

function Test-SonarEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $uri = "$script:BaseUrl$Path"

    Write-Host ""
    Write-Host "========================================" -ForegroundColor DarkGray
    Write-Host "Endpoint: $Path" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor DarkGray

    try {
        $response = Invoke-WebRequest `
            -Uri $uri `
            -Method GET `
            -Headers $headers `
            -TimeoutSec 30 `
            -UseBasicParsing `
            -ErrorAction Stop

        $status = [int]$response.StatusCode
        $content = [string]$response.Content

        Write-Host "HTTP status: $status" -ForegroundColor Green
        Write-Host "Content length: $($content.Length)"

        if ([string]::IsNullOrWhiteSpace($content)) {
            Write-Host "Response body is empty." -ForegroundColor Yellow
        }
        else {
            try {
                $json = $content | ConvertFrom-Json -ErrorAction Stop
                Write-Host "Response body (JSON):"
                $json | ConvertTo-Json -Depth 15
            }
            catch {
                Write-Host "Response body (text):"
                Write-Host $content
            }
        }
    }
    catch {
        Write-Host "Request failed." -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red

        if ($_.Exception.Response) {
            try {
                Write-Host (
                    "HTTP status: {0}" -f
                    [int]$_.Exception.Response.StatusCode
                ) -ForegroundColor Yellow

                $stream = $_.Exception.Response.GetResponseStream()

                if ($null -ne $stream) {
                    $reader = [System.IO.StreamReader]::new($stream)

                    try {
                        $body = $reader.ReadToEnd()

                        if (-not [string]::IsNullOrWhiteSpace($body)) {
                            Write-Host "Server response body:"
                            Write-Host $body
                        }
                    }
                    finally {
                        $reader.Dispose()
                    }
                }
            }
            catch {
                Write-Host "Could not read the HTTP error response."
            }
        }

        if ($_.ErrorDetails -and
            -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
            Write-Host "Additional details:"
            Write-Host $_.ErrorDetails.Message
        }
    }
}

# ------------------------------------------------------------
# 4. Execute read-only tests
# ------------------------------------------------------------

Write-Host ""
Write-Host "SonarQube API diagnostic" -ForegroundColor Cyan
Write-Host "Base URL: $script:BaseUrl"
Write-Host "Token configured: Yes"
Write-Host "No configuration or binding changes will be made."

# Known endpoint from your working script.
Test-SonarEndpoint -Path "/api/server/version"

# Known working API pattern for comparison.
Test-SonarEndpoint -Path "/api/projects/search?ps=1&p=1"

# ALM configuration endpoint under investigation.
Test-SonarEndpoint -Path "/api/alm_settings/list_definitions"

Write-Host ""
Write-Host "Diagnostic completed." -ForegroundColor Cyan
