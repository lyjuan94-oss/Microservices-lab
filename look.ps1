
param(
    [string]$SonarQubeUrl = "https://aas-sonar-pr.azure-paas.com",
    [string]$TokenOverride = "",
    [string]$ProjectKey = "SIAX-SIAX"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Configuration and authentication
# ------------------------------------------------------------

$script:BaseUrl = $SonarQubeUrl.Trim().TrimEnd('/')

if (-not [string]::IsNullOrWhiteSpace($TokenOverride)) {
    $env:SONARQUBE_TOKEN = $TokenOverride.Trim()
}
elseif ([string]::IsNullOrWhiteSpace($env:SONARQUBE_TOKEN)) {
    Write-Host "Missing token. Set SONARQUBE_TOKEN or pass TokenOverride." `
        -ForegroundColor Red
    exit 1
}

# Match the authentication convention in the existing scripts.
$AuthBytes = [System.Text.Encoding]::ASCII.GetBytes(
    "$($env:SONARQUBE_TOKEN):"
)

$AuthBase64 = [Convert]::ToBase64String($AuthBytes)

$script:Headers = @{
    Authorization = "Basic $AuthBase64"
    Accept        = "application/json"
}

# Enable TLS 1.2 for Windows PowerShell 5.1 environments.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# IMPORTANT: use the current Windows user's credentials for the proxy.
# This addresses HTTP 407 when the corporate proxy supports Windows auth.
try {
    $Proxy = [System.Net.WebRequest]::DefaultWebProxy

    if ($null -ne $Proxy) {
        $Proxy.Credentials =
            [System.Net.CredentialCache]::DefaultNetworkCredentials

        [System.Net.WebRequest]::DefaultWebProxy = $Proxy
    }
}
catch {
    Write-Warning "Could not configure default proxy credentials: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# Output directory
# ------------------------------------------------------------

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputDir = Join-Path (Get-Location).Path `
    "SonarQube_SIAX_Audit_$Timestamp"

New-Item -ItemType Directory -Path $OutputDir -Force |
    Out-Null

Write-Host "SonarQube URL : $script:BaseUrl"
Write-Host "Project key   : $ProjectKey"
Write-Host "Output folder : $OutputDir"

# ------------------------------------------------------------
# API helper
# ------------------------------------------------------------

function Invoke-SonarGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters
    )

    $QueryItems = foreach ($Entry in $Parameters.GetEnumerator()) {
        $EncodedKey = [Uri]::EscapeDataString([string]$Entry.Key)
        $EncodedValue = [Uri]::EscapeDataString([string]$Entry.Value)

        "$EncodedKey=$EncodedValue"
    }

    $QueryString = $QueryItems -join "&"
    $Uri = "$script:BaseUrl$Endpoint`?$QueryString"

    try {
        Invoke-RestMethod `
            -Uri $Uri `
            -Method Get `
            -Headers $script:Headers `
            -TimeoutSec 120 `
            -ErrorAction Stop
    }
    catch {
        $StatusCode = $null

        if ($_.Exception.Response) {
            try {
                $StatusCode = [int]$_.Exception.Response.StatusCode
            }
            catch {}
        }

        if ($StatusCode -eq 407) {
            throw "HTTP 407: the proxy requires authentication. Verify Windows proxy credentials or consult your network team."
        }

        if ($StatusCode -eq 401 -or $StatusCode -eq 403) {
            throw "HTTP $StatusCode: SonarQube rejected the request. Check the token and project permissions."
        }

        throw "API request failed: $Endpoint. $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 1. Validate authentication
# ------------------------------------------------------------

Write-Host "`nValidating SonarQube authentication..." `
    -ForegroundColor Cyan

$AuthResponse = Invoke-SonarGet `
    -Endpoint "/api/authentication/validate" `
    -Parameters @{}

if (-not $AuthResponse.valid) {
    throw "SonarQube authentication validation returned valid=false."
}

Write-Host "Authentication validated." -ForegroundColor Green

# ------------------------------------------------------------
# 2. Retrieve project metrics
# ------------------------------------------------------------

$MetricKeys = @(
    "ncloc",
    "lines",
    "duplicated_lines",
    "duplicated_lines_density",
    "complexity",
    "comment_lines",
    "comment_lines_density",
    "functions",
    "statements",
    "bugs",
    "vulnerabilities",
    "code_smells"
) -join ","

Write-Host "`nRetrieving project metrics..." -ForegroundColor Cyan

$ProjectResponse = Invoke-SonarGet `
    -Endpoint "/api/measures/component" `
    -Parameters @{
        component  = $ProjectKey
        metricKeys = $MetricKeys
    }

$ProjectResponse |
    ConvertTo-Json -Depth 30 |
    Set-Content `
        -Path (Join-Path $OutputDir "project_metrics.json") `
        -Encoding UTF8

# ------------------------------------------------------------
# 3. Retrieve all files and directories with pagination
# ------------------------------------------------------------

Write-Host "`nRetrieving component tree..." -ForegroundColor Cyan

$AllComponents = [System.Collections.Generic.List[object]]::new()
$Page = 1
$PageSize = 500
$Total = $null

do {
    $Response = Invoke-SonarGet `
        -Endpoint "/api/measures/component_tree" `
        -Parameters @{
            component  = $ProjectKey
            metricKeys = $MetricKeys
            qualifiers = "FIL,DIR"
            strategy   = "all"
            ps         = $PageSize
            p          = $Page
        }

    if ($null -eq $Total) {
        $Total = [int]$Response.paging.total
        Write-Host "Total components reported: $Total"
    }

    foreach ($Component in $Response.components) {
        $AllComponents.Add($Component)
    }

    Write-Host (
        "Page {0}: retrieved {1} of {2}" -f
        $Page, $AllComponents.Count, $Total
    )

    $Page++
}
while ($AllComponents.Count -lt $Total)

# ------------------------------------------------------------
# 4. Normalize component metrics
# ------------------------------------------------------------

Write-Host "`nBuilding inventory..." -ForegroundColor Cyan

$Inventory = foreach ($Component in $AllComponents) {
    $Measures = @{}

    foreach ($Measure in $Component.measures) {
        $Measures[$Measure.metric] = $Measure.value
    }

    $Path = $Component.path

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Prefix = "${ProjectKey}:"

        if ($Component.key.StartsWith($Prefix)) {
            $Path = $Component.key.Substring($Prefix.Length)
        }
        else {
            $Path = $Component.key
        }
    }

    $Extension = [IO.Path]::GetExtension($Path)

    if ([string]::IsNullOrWhiteSpace($Extension)) {
        $Extension = "[no extension]"
    }
    else {
        $Extension = $Extension.ToLowerInvariant()
    }

    [PSCustomObject]@{
        Name                   = $Component.name
        Path                   = $Path
        Key                    = $Component.key
        Qualifier              = $Component.qualifier
        Extension              = $Extension
        Ncloc                  = $Measures["ncloc"]
        Lines                  = $Measures["lines"]
        DuplicatedLines        = $Measures["duplicated_lines"]
        DuplicatedLinesDensity = $Measures["duplicated_lines_density"]
        Complexity             = $Measures["complexity"]
        CommentLines           = $Measures["comment_lines"]
        CommentLinesDensity    = $Measures["comment_lines_density"]
        Functions              = $Measures["functions"]
        Statements             = $Measures["statements"]
        Bugs                   = $Measures["bugs"]
        Vulnerabilities        = $Measures["vulnerabilities"]
        CodeSmells             = $Measures["code_smells"]
    }
}

# ------------------------------------------------------------
# 5. Export complete inventory
# ------------------------------------------------------------

$Inventory |
    Export-Csv `
        -Path (Join-Path $OutputDir "all_components.csv") `
        -NoTypeInformation -Encoding UTF8

$Inventory |
    Where-Object { $_.Qualifier -eq "FIL" } |
    Export-Csv `
        -Path (Join-Path $OutputDir "files.csv") `
        -NoTypeInformation -Encoding UTF8

$Inventory |
    Where-Object { $_.Qualifier -eq "DIR" } |
    Export-Csv `
        -Path (Join-Path $OutputDir "directories.csv") `
        -NoTypeInformation -Encoding UTF8

# ------------------------------------------------------------
# 6. Summary by extension
# ------------------------------------------------------------

$FileInventory = @(
    $Inventory | Where-Object { $_.Qualifier -eq "FIL" }
)

$ExtensionSummary = foreach ($Group in (
    $FileInventory | Group-Object Extension
)) {
    $WithNcloc = @(
        $Group.Group | Where-Object {
            $_.Ncloc -match '^\d+(\.\d+)?$'
        }
    )

    $TotalNcloc = 0.0

    foreach ($File in $WithNcloc) {
        $TotalNcloc += [double]$File.Ncloc
    }

    [PSCustomObject]@{
        Extension      = $Group.Name
        FileCount      = $Group.Count
        FilesWithNcloc = $WithNcloc.Count
        TotalNcloc     = $TotalNcloc
    }
}

$ExtensionSummary |
    Sort-Object TotalNcloc -Descending |
    Export-Csv `
        -Path (Join-Path $OutputDir "summary_by_extension.csv") `
        -NoTypeInformation -Encoding UTF8

# ------------------------------------------------------------
# 7. Top 500 files by LOC
# ------------------------------------------------------------

$FileInventory |
    Where-Object {
        $_.Ncloc -match '^\d+(\.\d+)?$'
    } |
    Sort-Object { [double]$_.Ncloc } -Descending |
    Select-Object -First 500 |
    Export-Csv `
        -Path (Join-Path $OutputDir "top_500_files_by_ncloc.csv") `
        -NoTypeInformation -Encoding UTF8

# ------------------------------------------------------------
# 8. Preserve raw API components and export metadata
# ------------------------------------------------------------

$AllComponents |
    ConvertTo-Json -Depth 50 |
    Set-Content `
        -Path (Join-Path $OutputDir "raw_components.json") `
        -Encoding UTF8

$Metadata = [PSCustomObject]@{
    ProjectKey       = $ProjectKey
    ServerUrl        = $script:BaseUrl
    ExportDate       = (Get-Date).ToString("o")
    ComponentsTotal  = $AllComponents.Count
    FilesTotal       = @(
        $AllComponents | Where-Object {
            $_.qualifier -eq "FIL"
        }
    ).Count
    DirectoriesTotal = @(
        $AllComponents | Where-Object {
            $_.qualifier -eq "DIR"
        }
    ).Count
    RequestedMetrics = $MetricKeys
}

$Metadata |
    ConvertTo-Json -Depth 20 |
    Set-Content `
        -Path (Join-Path $OutputDir "export_metadata.json") `
        -Encoding UTF8

Write-Host "`nExport completed successfully." -ForegroundColor Green
Write-Host "Output directory: $OutputDir"
Write-Host "Review these files first:"
Write-Host "  top_500_files_by_ncloc.csv"
Write-Host "  summary_by_extension.csv"
Write-Host "  directories.csv"
Write-Host "  project_metrics.json"
