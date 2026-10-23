
[CmdletBinding()]
param(
    [string]$SonarTokenOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# 1. CONFIGURATION
# ============================================================

$SonarBaseUrl = "https://aas-sonar-pr.azure-paas.com".TrimEnd("/")
$PageSize = 500

$ReportDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReportDirectory)) {
    $ReportDirectory = (Get-Location).Path
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$NoBindingReportPath = Join-Path `
    $ReportDirectory `
    "SonarProjects_WithoutBinding_$Timestamp.csv"

$ErrorReportPath = Join-Path `
    $ReportDirectory `
    "SonarProjects_BindingCheckErrors_$Timestamp.csv"

# ============================================================
# 2. AUTHENTICATION
# ============================================================

$SonarToken = $SonarTokenOverride

if ([string]::IsNullOrWhiteSpace($SonarToken)) {
    $SonarToken = $env:SONARQUBE_TOKEN
}

if ([string]::IsNullOrWhiteSpace($SonarToken)) {
    throw "SONARQUBE_TOKEN is not defined. Set it or use -SonarTokenOverride."
}

$EncodedAuth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${SonarToken}:")
)

$Headers = @{
    Authorization = "Basic $EncodedAuth"
    Accept        = "application/json"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    if ([System.Net.WebRequest]::DefaultWebProxy) {
        [System.Net.WebRequest]::DefaultWebProxy.Credentials =
            [System.Net.CredentialCache]::DefaultCredentials
    }
}
catch {
    # Ignore proxy configuration errors.
}

# ============================================================
# 3. HELPER FUNCTIONS
# ============================================================

function Get-HttpStatusCode {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $null

    try {
        $response = $ErrorRecord.Exception.Response
    }
    catch {
        $response = $null
    }

    if ($null -ne $response) {
        try {
            if ($null -ne $response.StatusCode) {
                return [int]$response.StatusCode
            }
        }
        catch {
            # Try alternative representations.
        }

        try {
            if ($null -ne $response.StatusCode.value__) {
                return [int]$response.StatusCode.value__
            }
        }
        catch {
            # Continue.
        }
    }

    try {
        $statusCode = $ErrorRecord.Exception.StatusCode
        if ($null -ne $statusCode) {
            return [int]$statusCode
        }
    }
    catch {
        # Continue.
    }

    try {
        $innerResponse = $ErrorRecord.Exception.InnerException.Response
        if ($null -ne $innerResponse.StatusCode) {
            return [int]$innerResponse.StatusCode
        }
    }
    catch {
        # No response available.
    }

    return $null
}

function Get-ErrorDescription {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $statusCode = Get-HttpStatusCode -ErrorRecord $ErrorRecord
    $message = $ErrorRecord.Exception.Message

    if ($ErrorRecord.ErrorDetails -and
        -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        $message += " | " + $ErrorRecord.ErrorDetails.Message
    }

    if ($null -ne $statusCode) {
        return "HTTP $statusCode : $message"
    }

    return "HTTP status unavailable: $message"
}

function Add-ErrorRow {
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$ProjectKey,
        [Parameter(Mandatory)][string]$Reason
    )

    $script:Errors.Add([PSCustomObject]@{
        ProjectName = $ProjectName
        ProjectKey  = $ProjectKey
        Reason      = $Reason
    }) | Out-Null
}

# ============================================================
# 4. CONNECT TO SONARQUBE
# ============================================================

Write-Host "`nChecking SonarQube connectivity..." -ForegroundColor Cyan

try {
    $Version = Invoke-RestMethod `
        -Uri "${SonarBaseUrl}/api/server/version" `
        -Method GET `
        -Headers $Headers `
        -ErrorAction Stop

    Write-Host "SonarQube version: $Version" -ForegroundColor Green
}
catch {
    throw "Cannot connect to SonarQube: $(Get-ErrorDescription -ErrorRecord $_)"
}

# ============================================================
# 5. RETRIEVE ALL PROJECTS
# ============================================================

Write-Host "`nRetrieving SonarQube projects..." -ForegroundColor Cyan

$Projects = [System.Collections.Generic.List[object]]::new()
$Page = 1
$Total = 0

do {
    $Uri = "${SonarBaseUrl}/api/projects/search?qualifiers=TRK&ps=${PageSize}&p=${Page}"

    try {
        $Response = Invoke-RestMethod `
            -Uri $Uri `
            -Method GET `
            -Headers $Headers `
            -ErrorAction Stop
    }
    catch {
        throw "Failed to retrieve projects, page ${Page}: $(Get-ErrorDescription -ErrorRecord $_)"
    }

    foreach ($Component in $Response.components) {
        $Projects.Add($Component) | Out-Null
    }

    $Total = [int]$Response.paging.total

    Write-Host "Retrieved $($Projects.Count) of $Total projects..."

    $Page++
}
while ($Projects.Count -lt $Total)

Write-Host "`nTotal projects retrieved: $($Projects.Count)" -ForegroundColor Green

# ============================================================
# 6. CHECK BINDINGS
# ============================================================

$NoBinding = [System.Collections.Generic.List[object]]::new()
$Errors = [System.Collections.Generic.List[object]]::new()

$Counter = 0
$BoundCount = 0
$UnboundCount = 0
$ErrorCount = 0

foreach ($Project in $Projects) {
    $Counter++

    $ProjectName = [string]$Project.name
    $ProjectKey = [string]$Project.key

    Write-Host "[$Counter/$($Projects.Count)] Checking $ProjectName" -ForegroundColor Cyan

    $EncodedKey = [uri]::EscapeDataString($ProjectKey)
    $BindingUri = "${SonarBaseUrl}/api/alm_settings/get_binding?project=${EncodedKey}"

    try {
        $Binding = Invoke-RestMethod `
            -Uri $BindingUri `
            -Method GET `
            -Headers $Headers `
            -ErrorAction Stop

        # Successful GET means a binding exists.
        $BoundCount++

        Write-Host "  BOUND" -ForegroundColor Green
    }
    catch {
        $StatusCode = Get-HttpStatusCode -ErrorRecord $_
        $Reason = Get-ErrorDescription -ErrorRecord $_

        if ($StatusCode -eq 404) {
            # SonarQube returns 404 when the project has no binding.
            $UnboundCount++

            $NoBinding.Add([PSCustomObject]@{
                ProjectName = $ProjectName
                ProjectKey  = $ProjectKey
                Qualifier   = [string]$Project.qualifier
                LastAnalysisDate = [string]$Project.lastAnalysisDate
                Visibility  = [string]$Project.visibility
                Status      = "NO_BINDING"
                Reason      = "SonarQube returned HTTP 404 for get_binding."
            }) | Out-Null

            Write-Host "  NO BINDING (HTTP 404)" -ForegroundColor Yellow
        }
        else {
            # Do not misclassify authentication/network errors as unbound.
            $ErrorCount++

            Add-ErrorRow `
                -ProjectName $ProjectName `
                -ProjectKey $ProjectKey `
                -Reason $Reason

            Write-Host "  CHECK ERROR: $Reason" -ForegroundColor Red
        }
    }
}

# ============================================================
# 7. EXPORT CSV REPORTS
# ============================================================

$NoBinding |
    Export-Csv `
        -Path $NoBindingReportPath `
        -NoTypeInformation `
        -Encoding UTF8

$Errors |
    Export-Csv `
        -Path $ErrorReportPath `
        -NoTypeInformation `
        -Encoding UTF8

# ============================================================
# 8. SUMMARY
# ============================================================

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "SONARQUBE BINDING AUDIT SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Write-Host "SonarQube version:       $Version"
Write-Host "Total projects:          $($Projects.Count)"
Write-Host "Projects with binding:   $BoundCount"
Write-Host "Projects without binding:$UnboundCount"
Write-Host "Binding check errors:    $ErrorCount"

Write-Host "`nProjects without binding CSV:" -ForegroundColor Yellow
Write-Host $NoBindingReportPath

Write-Host "`nBinding check errors CSV:" -ForegroundColor Yellow
Write-Host $ErrorReportPath

Write-Host "`nAudit completed. No SonarQube configuration was modified." -ForegroundColor Green
