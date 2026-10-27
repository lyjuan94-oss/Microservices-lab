
# ============================================================
# SonarQube Project Key Search in Azure DevOps YAML Files
#
# Input:
#   Sonar_Projects_Without_Binding.csv
#
# Output:
#   Sonar_AzDO_File_Search_Results.csv
#   Sonar_AzDO_File_Search_Errors.csv
#
# Search scope:
#   All Azure DevOps projects and Git repositories.
#   Only .yml and .yaml files are searched.
#
# READ-ONLY:
#   No pipelines are executed.
#   No SonarQube bindings are created or modified.
# ============================================================

[CmdletBinding()]
param(
    [string]$InputCsv = (Join-Path $PSScriptRoot "Sonar_Projects_Without_Binding.csv"),
    [string]$OutputCsv = (Join-Path $PSScriptRoot "Sonar_AzDO_File_Search_Results.csv"),
    [string]$ErrorsCsv = (Join-Path $PSScriptRoot "Sonar_AzDO_File_Search_Errors.csv"),
    [string]$Organization = "AASolutions",
    [int]$RequestDelayMilliseconds = 0
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Authentication
# ------------------------------------------------------------

$AzureToken = $env:AZDO_PAT

if ([string]::IsNullOrWhiteSpace($AzureToken)) {
    $AzureToken = $env:SYSTEM_ACCESSTOKEN
}

if ([string]::IsNullOrWhiteSpace($AzureToken)) {
    throw "AZDO_PAT or SYSTEM_ACCESSTOKEN environment variable is not set."
}

if (-not (Test-Path -LiteralPath $InputCsv)) {
    throw "Input CSV file was not found: $InputCsv"
}

$AzureBaseUrl = "https://dev.azure.com/$Organization"

$AzureEncodedToken = [Convert]::ToBase64String(
    [System.Text.Encoding]::ASCII.GetBytes(":${AzureToken}")
)

$AzureHeaders = @{
    Authorization = "Basic $AzureEncodedToken"
    Accept        = "application/json"
}

# Only YAML files are searched.
$SearchExtensions = @(".yml", ".yaml")

# ------------------------------------------------------------
# CSV IMPORT
# Preserves the previously corrected CSV-reading behavior:
# - Detect comma, semicolon, or tab delimiters.
# - Handle UTF-8 BOM.
# - Trim whitespace and BOM characters from headers.
# - Normalize ProjectName and ProjectKey.
# - Fall back to the first two columns if necessary.
# ------------------------------------------------------------

function Import-ProjectsCsv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $FirstLine = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($FirstLine)) {
        throw "The input CSV is empty or has no header row: $Path"
    }

    # Detect the delimiter used by the CSV header.
    $DelimiterCandidates = @(
        [PSCustomObject]@{
            Character = ','
            Count = ([regex]::Matches($FirstLine, ',')).Count
        },
        [PSCustomObject]@{
            Character = ';'
            Count = ([regex]::Matches($FirstLine, ';')).Count
        },
        [PSCustomObject]@{
            Character = "`t"
            Count = ([regex]::Matches($FirstLine, "`t")).Count
        }
    )

    $Delimiter = (
        $DelimiterCandidates |
        Sort-Object Count -Descending |
        Select-Object -First 1
    ).Character

    if (
        ($DelimiterCandidates | Measure-Object -Property Count -Sum).Sum -eq 0
    ) {
        throw "Could not detect the CSV delimiter. Expected comma, semicolon, or tab."
    }

    Write-Host "CSV delimiter detected: $(
        if ($Delimiter -eq "`t") { 'TAB' } else { $Delimiter }
    )"

    # Import the CSV using the detected delimiter.
    $ImportedRows = @(
        Import-Csv -LiteralPath $Path -Delimiter $Delimiter -Encoding UTF8
    )

    if ($ImportedRows.Count -eq 0) {
        throw "The input CSV contains no data rows."
    }

    # Normalize headers to remove BOM and surrounding whitespace.
    $HeaderMap = @{}

    foreach ($Property in $ImportedRows[0].PSObject.Properties) {
        $NormalizedHeader = ([string]$Property.Name).Trim()
        $NormalizedHeader = $NormalizedHeader.Trim([char]0xFEFF)
        $NormalizedHeader = $NormalizedHeader.Trim()

        $HeaderMap[$NormalizedHeader.ToLowerInvariant()] = $Property.Name
    }

    $NameHeader = $HeaderMap["projectname"]
    $KeyHeader = $HeaderMap["projectkey"]

    # The known input format has ProjectName first and ProjectKey second.
    # Use positional fallback if the header names are not recognized.
    if (
        [string]::IsNullOrWhiteSpace($NameHeader) -or
        [string]::IsNullOrWhiteSpace($KeyHeader)
    ) {
        $FirstProperty = $ImportedRows[0].PSObject.Properties[0]
        $SecondProperty = $ImportedRows[0].PSObject.Properties[1]

        if ($null -eq $FirstProperty -or $null -eq $SecondProperty) {
            throw "The input CSV must contain at least two columns."
        }

        Write-Warning "CSV headers were not recognized by name. Using the first column as ProjectName and the second as ProjectKey."

        $NameHeader = $FirstProperty.Name
        $KeyHeader = $SecondProperty.Name
    }

    $NormalizedRows = @(
        foreach ($Row in $ImportedRows) {
            $ProjectName = ([string]$Row.PSObject.Properties[$NameHeader].Value).Trim()
            $ProjectKey = ([string]$Row.PSObject.Properties[$KeyHeader].Value).Trim()

            if (
                -not [string]::IsNullOrWhiteSpace($ProjectKey)
            ) {
                [PSCustomObject]@{
                    ProjectName = $ProjectName
                    ProjectKey  = $ProjectKey
                }
            }
        }
    )

    if ($NormalizedRows.Count -eq 0) {
        throw "No valid ProjectKey values were found in the input CSV."
    }

    return $NormalizedRows
}

# ------------------------------------------------------------
# Azure DevOps API helpers
# ------------------------------------------------------------

function ConvertTo-EncodedSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [Uri]::EscapeDataString($Value)
}

function Invoke-AzureGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    if ($RequestDelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $RequestDelayMilliseconds
    }

    try {
        return Invoke-RestMethod `
            -Uri $Url `
            -Headers $AzureHeaders `
            -Method Get
    }
    catch {
        throw "Azure DevOps request failed. URL: $Url. Error: $($_.Exception.Message)"
    }
}

function Get-AzureProjects {
    $Url = "$AzureBaseUrl/_apis/projects?`$top=1000&api-version=7.1"
    $Response = Invoke-AzureGet -Url $Url

    return @($Response.value)
}

function Get-AzureRepositories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectName
    )

    $EncodedProject = ConvertTo-EncodedSegment -Value $ProjectName

    $Url = "$AzureBaseUrl/$EncodedProject/_apis/git/repositories?api-version=7.1"
    $Response = Invoke-AzureGet -Url $Url

    return @($Response.value)
}

function Get-RepositoryFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryId
    )

    $EncodedProject = ConvertTo-EncodedSegment -Value $ProjectName
    $EncodedRepository = ConvertTo-EncodedSegment -Value $RepositoryId

    $Url = "$AzureBaseUrl/$EncodedProject/_apis/git/repositories/$EncodedRepository/items?recursionLevel=Full&includeContentMetadata=true&api-version=7.1"

    $Response = Invoke-AzureGet -Url $Url

    return @($Response.value)
}

function Get-RepositoryFileContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryId,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $EncodedProject = ConvertTo-EncodedSegment -Value $ProjectName
    $EncodedRepository = ConvertTo-EncodedSegment -Value $RepositoryId
    $EncodedPath = ConvertTo-EncodedSegment -Value $FilePath

    $Url = "$AzureBaseUrl/$EncodedProject/_apis/git/repositories/$EncodedRepository/items?path=$EncodedPath&includeContent=true&api-version=7.1"

    $Response = Invoke-AzureGet -Url $Url

    if ($Response -is [string]) {
        return $Response
    }

    if ($null -ne $Response.content) {
        return [string]$Response.content
    }

    throw "The Azure DevOps response did not contain file content."
}

# ------------------------------------------------------------
# Load input keys
# ------------------------------------------------------------

Write-Host ""
Write-Host "Loading SonarQube project keys..." -ForegroundColor Cyan

$SonarProjects = @(Import-ProjectsCsv -Path $InputCsv)

Write-Host "SonarQube project keys loaded: $($SonarProjects.Count)" -ForegroundColor Green

# ------------------------------------------------------------
# Search Azure DevOps YAML files
# ------------------------------------------------------------

$Results = [System.Collections.Generic.List[object]]::new()
$Errors = [System.Collections.Generic.List[object]]::new()

$Projects = @(Get-AzureProjects)

Write-Host "Azure DevOps projects found: $($Projects.Count)" -ForegroundColor Cyan
Write-Host "Searching only .yml and .yaml files." -ForegroundColor Cyan
Write-Host ""

$TotalRepositories = 0
$TotalYamlFiles = 0
$TotalMatches = 0
$CurrentProject = 0

foreach ($AzureProject in $Projects) {
    $CurrentProject++

    $AzureProjectName = [string]$AzureProject.name
    $AzureProjectId = [string]$AzureProject.id

    Write-Host "[$CurrentProject/$($Projects.Count)] Project: $AzureProjectName" -ForegroundColor Yellow

    try {
        $Repositories = @(Get-AzureRepositories -ProjectName $AzureProjectName)
    }
    catch {
        $Errors.Add([PSCustomObject]@{
            AzureProjectName = $AzureProjectName
            RepositoryName   = ""
            FilePath         = ""
            Error            = $_.Exception.Message
        })

        Write-Warning "Could not list repositories for project '$AzureProjectName'."
        continue
    }

    foreach ($Repository in $Repositories) {
        $RepositoryName = [string]$Repository.name
        $RepositoryId = [string]$Repository.id

        $TotalRepositories++

        Write-Host "  Repository: $RepositoryName"

        try {
            $Files = @(Get-RepositoryFiles `
                -ProjectName $AzureProjectName `
                -RepositoryId $RepositoryId)
        }
        catch {
            $Errors.Add([PSCustomObject]@{
                AzureProjectName = $AzureProjectName
                RepositoryName   = $RepositoryName
                FilePath         = ""
                Error            = $_.Exception.Message
            })

            Write-Warning "Could not list files in repository '$RepositoryName'."
            continue
        }

        # Filter to YAML files only.
        $YamlFiles = @(
            foreach ($File in $Files) {
                $FilePath = [string]$File.path
                $IsFolder = [bool]$File.isFolder

                if ($IsFolder -or [string]::IsNullOrWhiteSpace($FilePath)) {
                    continue
                }

                $Extension = [System.IO.Path]::GetExtension($FilePath)

                if ($SearchExtensions -contains $Extension.ToLowerInvariant()) {
                    $File
                }
            }
        )

        foreach ($File in $YamlFiles) {
            $FilePath = [string]$File.path
            $TotalYamlFiles++

            try {
                $Content = Get-RepositoryFileContent `
                    -ProjectName $AzureProjectName `
                    -RepositoryId $RepositoryId `
                    -FilePath $FilePath
            }
            catch {
                $Errors.Add([PSCustomObject]@{
                    AzureProjectName = $AzureProjectName
                    RepositoryName   = $RepositoryName
                    FilePath         = $FilePath
                    Error            = $_.Exception.Message
                })

                continue
            }

            foreach ($SonarProject in $SonarProjects) {
                $Key = [string]$SonarProject.ProjectKey

                if (
                    $Content.IndexOf(
                        $Key,
                        [System.StringComparison]::OrdinalIgnoreCase
                    ) -ge 0
                ) {
                    $TotalMatches++

                    $Results.Add([PSCustomObject]@{
                        ProjectKey       = $Key
                        SonarProjectName = $SonarProject.ProjectName
                        AzureProjectName = $AzureProjectName
                        AzureProjectId   = $AzureProjectId
                        RepositoryName   = $RepositoryName
                        RepositoryId     = $RepositoryId
                        FilePath         = $FilePath
                        MatchStatus      = "Match"
                        Approved         = ""
                        Notes            = "Project key found in YAML file content. Binding not modified."
                    })

                    Write-Host "    MATCH: $Key -> $FilePath" -ForegroundColor Green
                }
            }
        }
    }
}

# ------------------------------------------------------------
# Add NoMatch rows for keys not found
# ------------------------------------------------------------

$MatchedKeys = @{}

foreach ($Result in $Results) {
    $MatchedKeys[$Result.ProjectKey.ToLowerInvariant()] = $true
}

foreach ($SonarProject in $SonarProjects) {
    $Key = [string]$SonarProject.ProjectKey

    if (-not $MatchedKeys.ContainsKey($Key.ToLowerInvariant())) {
        $Results.Add([PSCustomObject]@{
            ProjectKey       = $Key
            SonarProjectName = $SonarProject.ProjectName
            AzureProjectName = ""
            AzureProjectId   = ""
            RepositoryName   = ""
            RepositoryId     = ""
            FilePath         = ""
            MatchStatus      = "NoMatch"
            Approved         = ""
            Notes            = "Key was not found in successfully scanned YAML files. Check the error CSV before concluding that no match exists."
        })
    }
}

# ------------------------------------------------------------
# Export CSV files
# ------------------------------------------------------------

$Results |
    Sort-Object ProjectKey, AzureProjectName, RepositoryName, FilePath |
    Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8

if ($Errors.Count -gt 0) {
    $Errors |
        Export-Csv -LiteralPath $ErrorsCsv -NoTypeInformation -Encoding UTF8
}
else {
    @(
        [PSCustomObject]@{
            AzureProjectName = ""
            RepositoryName   = ""
            FilePath         = ""
            Error            = "No errors were recorded."
        }
    ) | Export-Csv -LiteralPath $ErrorsCsv -NoTypeInformation -Encoding UTF8
}

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

$UniqueMatchedKeys = @(
    $Results |
        Where-Object { $_.MatchStatus -eq "Match" } |
        Select-Object -ExpandProperty ProjectKey -Unique
).Count

$NoMatchCount = @(
    $Results |
        Where-Object { $_.MatchStatus -eq "NoMatch" }
).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "SEARCH COMPLETED" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "SonarQube keys loaded:      $($SonarProjects.Count)"
Write-Host "Azure DevOps projects:      $($Projects.Count)"
Write-Host "Repositories scanned:       $TotalRepositories"
Write-Host "YAML files inspected:       $TotalYamlFiles"
Write-Host "Unique keys matched:        $UniqueMatchedKeys"
Write-Host "Keys without a match:       $NoMatchCount"
Write-Host "Total file matches:         $TotalMatches"
Write-Host "Errors recorded:            $($Errors.Count)"
Write-Host ""
Write-Host "Results CSV: $OutputCsv" -ForegroundColor Green
Write-Host "Errors CSV:  $ErrorsCsv" -ForegroundColor Green
Write-Host ""
Write-Host "No SonarQube bindings were created or modified."
