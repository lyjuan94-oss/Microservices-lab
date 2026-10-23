
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

try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor
        [Net.SecurityProtocolType]::Tls12
}
catch {
    Write-Host "Warning: Could not configure TLS 1.2."
}

try {
    [System.Net.WebRequest]::DefaultWebProxy.Credentials =
        [System.Net.CredentialCache]::DefaultNetworkCredentials
}
catch {
    # Proxy configuration is optional.
}

# ------------------------------------------------------------
# 3. Diagnostic function
# ------------------------------------------------------------

function Test-SonarEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $uri = "$script:BaseUrl$Path"

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor DarkGray
    Write-Host "Endpoint: $Path" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor DarkGray

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
            return
        }

        Write-Host ""
        Write-Host "----- FULL RESPONSE BODY -----" -ForegroundColor Yellow

        try {
            $json = $content | ConvertFrom-Json -ErrorAction Stop
            $formattedJson = $json | ConvertTo-Json -Depth 30
            Write-Output $formattedJson
        }
        catch {
            # Print the raw body if it is not valid JSON.
            Write-Output $content
        }

        Write-Host ""
        Write-Host "----- END RESPONSE BODY -----" -ForegroundColor Yellow
    }
    catch {
        Write-Host "Request failed." -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red

        if ($_.Exception.Response) {
            try {
                $httpResponse = $_.Exception.Response
                Write-Host "HTTP status: $([int]$httpResponse.StatusCode)" `
                    -ForegroundColor Yellow

                $stream = $httpResponse.GetResponseStream()

                if ($null -ne $stream) {
                    $reader = [System.IO.StreamReader]::new($stream)

                    try {
                        $body = $reader.ReadToEnd()

                        if (-not [string]::IsNullOrWhiteSpace($body)) {
                            Write-Host "----- ERROR RESPONSE BODY -----" `
                                -ForegroundColor Yellow
                            Write-Output $body
                            Write-Host "----- END ERROR BODY -----" `
                                -ForegroundColor Yellow
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
            Write-Output $_.ErrorDetails.Message
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
Write-Host "Read-only mode: No changes will be made."

Test-SonarEndpoint -Path "/api/server/version"

Test-SonarEndpoint -Path "/api/projects/search?ps=1&p=1"

Test-SonarEndpoint -Path "/api/alm_settings/list_definitions"

Write-Host ""
Write-Host "Diagnostic completed." -ForegroundColor Cyan
