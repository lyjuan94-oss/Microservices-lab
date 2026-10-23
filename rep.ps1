
[CmdletBinding()]
param(
    [string]$SonarTokenOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Configuration
$BaseUrl = "https://aas-sonar-pr.azure-paas.com".TrimEnd("/")
$PageSize = 500
$OutputDirectory = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = (Get-Location).Path
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$NoBindingCsv = Join-Path $OutputDirectory "Sonar_Projects_Without_Binding_$Timestamp.csv"
$ErrorsCsv = Join-Path $OutputDirectory "Sonar_Binding_Check_Errors_$Timestamp.csv"

# Authentication
$Token = $SonarTokenOverride
if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = $env:SONARQUBE_TOKEN
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "SONARQUBE_TOKEN is not defined."
}

$EncodedAuth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${Token}:")
)

$Headers = @{
    Authorization = "Basic $EncodedAuth"
    Accept        = "application/json"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Get HTTP status safely across PowerShell/.NET versions.
function Get-HttpStatusCode {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response) {
            try {
                return [int]$response.StatusCode
            }
            catch {
                try {
                    return [int]$response.StatusCode.value__
                }
                catch {}
            }
        }
    }
    catch {}

    try {
        if ($null -ne $ErrorRecord.Exception.StatusCode) {
            return [int]$ErrorRecord.Exception.StatusCode
        }
    }
    catch {}

    return $null
}

function Get-ErrorText {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $status = Get-HttpStatusCode -ErrorRecord $ErrorRecord
    $message = $ErrorRecord.Exception.Message

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $message += " | " + $ErrorRecord.ErrorDetails.Message
    }

    if ($null -ne $status) {
        return "HTTP $status : $message"
    }

    return $message
}

# Verify connectivity
Write-Host "Checking SonarQube..." -ForegroundColor Cyan

$version = Invoke-RestMethod `
    -Uri "${BaseUrl}/api/server/version" `
    -Method GET `
    -Headers $Headers `
    -ErrorAction Stop

Write-Host "SonarQube version: $version" -ForegroundColor Green

# Retrieve projects
$Projects = [System.Collections.Generic.List[object]]::new()
$Page = 1
$Total = 0

do {
    $uri = "${BaseUrl}/api/projects/search?qualifiers=TRK&ps=${PageSize}&p=${Page}"

    $response = Invoke-RestMethod `
        -Uri $uri `
        -Method GET `
        -Headers $Headers `
        -ErrorAction Stop

    foreach ($project in $response.components) {
        $Projects.Add($project) | Out-Null
    }

    $Total = [int]$response.paging.total
    Write-Host "Retrieved $($Projects.Count) of $Total projects..."
    $Page++
}
while ($Projects.Count -lt $Total)

# Check binding only
$NoBinding = [System.Collections.Generic.List[object]]::new()
$Errors = [System.Collections.Generic.List[object]]::new()

$BoundCount = 0
$UnboundCount = 0
$ErrorCount = 0
$Counter = 0

foreach ($project in $Projects) {
    $Counter++

    $name = [string]$project.name
    $key = [string]$project.key
    $encodedKey = [uri]::EscapeDataString($key)
    $bindingUri = "${BaseUrl}/api/alm_settings/get_binding?project=${encodedKey}"

    Write-Host "[$Counter/$($Projects.Count)] $name" -ForegroundColor Cyan

    try {
        # Successful GET = binding exists.
        $null = Invoke-RestMethod `
            -Uri $bindingUri `
            -Method GET `
            -Headers $Headers `
            -ErrorAction Stop

        $BoundCount++
        Write-Host "  BOUND" -ForegroundColor Green
    }
    catch {
        $status = Get-HttpStatusCode -ErrorRecord $_

        if ($status -eq 404) {
            $UnboundCount++

            $NoBinding.Add([PSCustomObject]@{
                ProjectName = $name
                ProjectKey  = $key
            }) | Out-Null

            Write-Host "  NO BINDING" -ForegroundColor Yellow
        }
        else {
            $ErrorCount++

            $Errors.Add([PSCustomObject]@{
                ProjectName = $name
                ProjectKey  = $key
                Error       = Get-ErrorText -ErrorRecord $_
            }) | Out-Null

            Write-Host "  CHECK ERROR: $(Get-ErrorText -ErrorRecord $_)" -ForegroundColor Red
        }
    }
}

# Export only the required project list plus a separate errors report.
$NoBinding | Export-Csv -Path $NoBindingCsv -NoTypeInformation -Encoding UTF8
$Errors | Export-Csv -Path $ErrorsCsv -NoTypeInformation -Encoding UTF8

Write-Host "`n========== SUMMARY ==========" -ForegroundColor Cyan
Write-Host "Total projects:      $($Projects.Count)"
Write-Host "With binding:        $BoundCount"
Write-Host "Without binding:     $UnboundCount"
Write-Host "Check errors:        $ErrorCount"
Write-Host "`nProjects without binding:"
Write-Host $NoBindingCsv
Write-Host "`nCheck errors:"
Write-Host $ErrorsCsv
Write-Host "`nRead-only audit complete. No bindings were changed." -ForegroundColor Green
