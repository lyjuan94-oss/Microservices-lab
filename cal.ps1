
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# SonarQube configuration
$baseUrl = "https://aas-sonar-pr.azure-paas.com".TrimEnd("/")
$projectKey = "aa-belgium-internal-Adhesions"

# Azure DevOps configuration
$almSetting = "Azure DevOps"
$azureProject = "aa-belgium-internal"
$repositoryName = "Adhesions"
$monorepo = "false"

# Authentication
$token = $env:SONARQUBE_TOKEN

if ([string]::IsNullOrWhiteSpace($token)) {
    throw "SONARQUBE_TOKEN no está definido."
}

$basicAuth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${token}:")
)

$headers = @{
    Authorization = "Basic $basicAuth"
    Accept        = "application/json"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$encodedProjectKey = [uri]::EscapeDataString($projectKey)
$bindingUri = "$baseUrl/api/alm_settings/get_binding?project=$encodedProjectKey"
$postUri = "$baseUrl/api/alm_settings/set_azure_binding"

# 1. Check whether a binding already exists
Write-Host "Checking existing binding..." -ForegroundColor Cyan

try {
    $existingBinding = Invoke-RestMethod `
        -Uri $bindingUri `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop

    Write-Host "The project already has a binding. No changes made." `
        -ForegroundColor Yellow

    $existingBinding | ConvertTo-Json -Depth 10
    return
}
catch {
    $statusCode = $null

    if ($null -ne $_.Exception.Response) {
        try {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        catch {
            $statusCode = $null
        }
    }

    if ($statusCode -ne 404) {
        Write-Host "Could not confirm binding status." -ForegroundColor Red
        Write-Host $_.Exception.Message
        if ($_.ErrorDetails.Message) {
            Write-Host $_.ErrorDetails.Message
        }
        throw "Aborting: POST will not be sent."
    }

    Write-Host "No existing binding found (HTTP 404)." -ForegroundColor Yellow
}

# 2. Create the binding
$body = @{
    almSetting     = $almSetting
    project        = $projectKey
    projectName    = $azureProject
    repositoryName = $repositoryName
    monorepo       = $monorepo
}

Write-Host "`nCreating binding..." -ForegroundColor Cyan
Write-Host "SonarQube project: $projectKey"
Write-Host "Azure DevOps project: $azureProject"
Write-Host "Azure DevOps repository: $repositoryName"

try {
    $result = Invoke-RestMethod `
        -Uri $postUri `
        -Method POST `
        -Headers $headers `
        -Body $body `
        -ErrorAction Stop

    Write-Host "POST completed." -ForegroundColor Green

    if ($null -ne $result) {
        $result | ConvertTo-Json -Depth 10
    }
}
catch {
    Write-Host "Binding creation failed." -ForegroundColor Red
    Write-Host $_.Exception.Message

    if ($_.ErrorDetails.Message) {
        Write-Host "Server response:"
        Write-Host $_.ErrorDetails.Message
    }

    throw
}

# 3. Verify the binding
Write-Host "`nVerifying binding..." -ForegroundColor Cyan

try {
    $verified = Invoke-RestMethod `
        -Uri $bindingUri `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop

    $verified | ConvertTo-Json -Depth 10
    Write-Host "`nBinding verified successfully." -ForegroundColor Green
}
catch {
    Write-Host "The POST completed, but verification failed." `
        -ForegroundColor Yellow
    Write-Host $_.Exception.Message

    if ($_.ErrorDetails.Message) {
        Write-Host $_.ErrorDetails.Message
    }
}
