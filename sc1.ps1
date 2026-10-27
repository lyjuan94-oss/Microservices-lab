
# ============================================================
# SonarQube Project Key Search in Azure DevOps YAML Files
#
# Scope:
#   All projects and Git repositories in the AASolutions
#   organization.
#
# Search method:
#   1. Load SonarQube project keys from the input CSV.
#   2. Enumerate Azure DevOps projects and Git repositories.
#   3. List repository files recursively.
#   4. Download only .yml and .yaml files.
#   5. Search YAML content for SonarQube project keys.
#
# READ-ONLY:
#   No pipelines are executed.
#   No SonarQube bindings are created or modified.
#
# Required environment variables:
#   AZDO_PAT or SYSTEM_ACCESSTOKEN
#
# Input:
#   Sonar_Projects_Without_Binding.csv
#
# Output:
#   Sonar_AzDO_File_Search_Results.csv
#   Sonar_AzDO_File_Search_Errors.csv
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

# Only these extensions will be downloaded and searched.
$SearchExtensions = @(".yml", ".yaml")

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

function ConvertTo-EncodedSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [Uri]::EscapeDataString($Value)
}

function Get-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object[$Name]
    }

    $Property = $Object.PSObject.Properties[$Name]

    if ($null -ne $Property) {
        return $Property.Value
    }

    return $null
}

function Invoke-AzureGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [switch]$RawResponse
    )

    if ($RequestDelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $RequestDelayMilliseconds
    }

    try {
        if ($RawResponse) {
            return Invoke-WebRequest `
                -Uri $Url `
                -Headers $AzureHeaders `
                -Method Get `
                -UseBasicParsing
        }

        return Invoke-RestMethod `
            -Uri $Url `
            -Headers $AzureHeaders `
            -Method Get
    }
    catch {
        throw "Azure DevOps request failed. URL: $Url. Error: $($_.Exception.Message)"
    }
}

function Import-ProjectsCsv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Rows = @(Import-Csv -LiteralPath $Path)

    if ($Rows.Count -eq 0) {
        throw "The input CSV contains no project keys."
    }

    $FirstRow = $Rows[0]

    if (
        $null -eq $FirstRow.PSObject.Properties["ProjectKey"] -or
        $null -eq $FirstRow.PSObject.Properties["ProjectName"]
    ) {
        throw "The input CSV must contain ProjectKey and ProjectName columns."
    }

    $Projects = @(
        foreach ($Row in $Rows) {
            $Key = ([string]$Row.ProjectKey).Trim()

            if (-not [string]::IsNullOrWhiteSpace($Key)) {
                [PSCustomObject]@{
                    ProjectKey  = $Key
                    ProjectName = ([string]$Row.ProjectName).Trim()
                }
            }
        }
    )

    if ($Projects.Count -eq 0) {
        throw "No valid ProjectKey values were found in the input CSV."
    }

    return $Projects
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

    $Content = Get-ObjectProperty -Object $Response -Name "content"

    if ($null -ne $Content) {
        return [string]$Content
    }

    throw "The Azure DevOps response did not contain file content."
}

# ------------------------------------------------------------
# Load SonarQube project keys
# ------------------------------------------------------------

Write-Host ""
Write-Host "Loading SonarQube project keys..." -ForegroundColor Cyan

$SonarProjects = @(Import-ProjectsCsv -Path $InputCsv)

Write-Host "SonarQube projects to search: $($SonarProjects.Count)"

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

        # Keep only YAML files; ignore folders and other file types.
        $YamlFiles = @(
            foreach ($File in $Files) {
                $FilePath = [string]$File.path
                $IsFolder = [bool](Get-ObjectProperty -Object $File -Name "isFolder")

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

            # Search every SonarQube key in this YAML file.
            foreach ($SonarProject in $SonarProjects) {
                $Key = [string]$SonarProject.ProjectKey

                if ($Content.IndexOf(
                    $Key,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -ge 0) {
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
# Add explicit NoMatch rows for keys not found
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
            Notes            = "Key was not found in the YAML files that were successfully scanned. Check the error CSV before concluding that no match exists."
        })
    }
}

# ------------------------------------------------------------
# Export results
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
Write-Host "This script did not create or modify any SonarQube bindings."
