
#requires -Version 5.1

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
$BaseUrl   = "https://aas-sonar-pr.azure-paas.com"
$ProjectKey = "SIAX-SIAX"
$Token = $env:SONARQUBE_TOKEN

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "SONARQUBE_TOKEN environment variable is not set."
}

$BaseUrl = $BaseUrl.TrimEnd("/")

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputDir = Join-Path (Get-Location).Path `
    "SonarQube_SIAX_Audit_$Timestamp"

New-Item -ItemType Directory -Path $OutputDir -Force |
    Out-Null

# Existing authentication convention: Basic token:
$AuthBytes = [System.Text.Encoding]::UTF8.GetBytes(
    ($Token + ":")
)
$AuthValue = [Convert]::ToBase64String($AuthBytes)

$Headers = @{
    Authorization = "Basic $AuthValue"
    Accept        = "application/json"
}

# Metrics useful for LOC and exclusion analysis.
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

    $Query = (
        $Parameters.GetEnumerator() |
        ForEach-Object {
            "{0}={1}" -f `
                [Uri]::EscapeDataString([string]$_.Key), `
                [Uri]::EscapeDataString([string]$_.Value)
        }
    ) -join "&"

    $Uri = "$BaseUrl$Endpoint`?$Query"

    try {
        Invoke-RestMethod `
            -Uri $Uri `
            -Method Get `
            -Headers $Headers `
            -ErrorAction Stop
    }
    catch {
        throw "SonarQube API request failed: $Endpoint. $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 1. Project-level metrics
# ------------------------------------------------------------
Write-Host "Retrieving project metrics..."

$ProjectResponse = Invoke-SonarGet `
    -Endpoint "/api/measures/component" `
    -Parameters @{
        component  = $ProjectKey
        metricKeys = $MetricKeys
    }

$ProjectResponse |
    ConvertTo-Json -Depth 20 |
    Set-Content (Join-Path $OutputDir "project_metrics.json") `
        -Encoding UTF8

# ------------------------------------------------------------
# 2. Retrieve all files and directories, page by page
# ------------------------------------------------------------
Write-Host "Retrieving complete component inventory..."

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
        Write-Host "Components reported by API: $Total"
    }

    foreach ($Component in $Response.components) {
        $AllComponents.Add($Component)
    }

    Write-Host (
        "Page {0}: retrieved {1}/{2}" -f `
            $Page, $AllComponents.Count, $Total
    )

    $Page++
}
while ($AllComponents.Count -lt $Total)

# ------------------------------------------------------------
# 3. Normalize all component metrics
# ------------------------------------------------------------
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
        Name                    = $Component.name
        Path                    = $Path
        Key                     = $Component.key
        Qualifier               = $Component.qualifier
        Extension               = $Extension
        Ncloc                   = $Measures["ncloc"]
        Lines                   = $Measures["lines"]
        DuplicatedLines         = $Measures["duplicated_lines"]
        DuplicatedLinesDensity  = $Measures["duplicated_lines_density"]
        Complexity              = $Measures["complexity"]
        CommentLines            = $Measures["comment_lines"]
        CommentLinesDensity     = $Measures["comment_lines_density"]
        Functions               = $Measures["functions"]
        Statements              = $Measures["statements"]
        Bugs                    = $Measures["bugs"]
        Vulnerabilities         = $Measures["vulnerabilities"]
        CodeSmells              = $Measures["code_smells"]
    }
}

# ------------------------------------------------------------
# 4. Export complete inventory
# ------------------------------------------------------------
$Inventory |
    Export-Csv `
        (Join-Path $OutputDir "all_components.csv") `
        -NoTypeInformation -Encoding UTF8

$Inventory |
    Where-Object { $_.Qualifier -eq "FIL" } |
    Export-Csv `
        (Join-Path $OutputDir "files.csv") `
        -NoTypeInformation -Encoding UTF8

$Inventory |
    Where-Object { $_.Qualifier -eq "DIR" } |
    Export-Csv `
        (Join-Path $OutputDir "directories.csv") `
        -NoTypeInformation -Encoding UTF8

# ------------------------------------------------------------
# 5. Summary by file extension
# ------------------------------------------------------------
$Inventory |
    Where-Object { $_.Qualifier -eq "FIL" } |
    Group-Object Extension |
    ForEach-Object {

        $Files = @($_.Group)

        $NclocValues = @(
            $Files | Where-Object {
                $_.Ncloc -match '^\d+(\.\d+)?$'
            }
        )

        $TotalNcloc = (
            $NclocValues |
            Measure-Object {
                [double]$_.Ncloc
            } -Sum
        ).Sum

        [PSCustomObject]@{
            Extension    = $_.Name
            FileCount    = $Files.Count
            FilesWithNcloc = $NclocValues.Count
            TotalNcloc   = $TotalNcloc
        }
    } |
    Sort-Object TotalNcloc -Descending |
    Export-Csv `
        (Join-Path $OutputDir "summary_by_extension.csv") `
        -NoTypeInformation -Encoding UTF8

# ------------------------------------------------------------
# 6. Largest files by reported LOC
# ------------------------------------------------------------
$Inventory |
    Where-Object {
        $_.Qualifier -eq "FIL" -and
        $_.Ncloc -match '^\d+(\.\d+)?$'
    } |
    Sort-Object { [double]$_.Ncloc } -Descending |
    Select-Object -First 500 |
    Export-Csv `
        (Join-Path $OutputDir "top_500_files_by_ncloc.csv") `
        -NoTypeInformation -Encoding UTF8

# ------------------------------------------------------------
# 7. Full raw response for independent inspection
# ------------------------------------------------------------
$AllComponents |
    ConvertTo-Json -Depth 30 |
    Set-Content `
        (Join-Path $OutputDir "raw_components.json") `
        -Encoding UTF8

$Metadata = [PSCustomObject]@{
    ProjectKey       = $ProjectKey
    ServerUrl        = $BaseUrl
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
    ConvertTo-Json -Depth 10 |
    Set-Content `
        (Join-Path $OutputDir "export_metadata.json") `
        -Encoding UTF8

Write-Host ""
Write-Host "Export completed successfully."
Write-Host "Output directory: $OutputDir"
Write-Host "Files: files.csv"
Write-Host "Directories: directories.csv"
Write-Host "Extensions: summary_by_extension.csv"
Write-Host "Largest files: top_500_files_by_ncloc.csv"
Write-Host "Raw inventory: raw_components.json"
