
# ============================================================
# SonarQube Project Key Search Across Azure DevOps
#
# Scope:
#   All projects and Git repositories in the AASolutions
#   organization.
#
# Search method:
#   1. Load SonarQube project keys from CSV.
#   2. Enumerate Azure DevOps projects and Git repositories.
#   3. List repository files recursively.
#   4. Retrieve candidate text/configuration files.
#   5. Search file contents for SonarQube project keys.
#
# READ-ONLY:
#   No pipelines are executed.
#   No SonarQube bindings are created or modified.
#
# Required environment variables:
#   SONARQUBE_TOKEN
#   AZDO_PAT or SYSTEM_ACCESSTOKEN
#
# Input:
#   Sonar_Projects_Without_Binding.csv
#
# Output:
#   Sonar_AzDO_File_Search_Results.csv
# ============================================================

[CmdletBinding()]
param(
    [string]$InputCsv = (Join-Path $PSScriptRoot "Sonar_Projects_Without_Binding.csv"),

    [string]$OutputCsv = (Join-Path $PSScriptRoot "Sonar_AzDO_File_Search_Results.csv"),

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

# Search common pipeline, source-code and configuration file types.
# This avoids downloading obvious binary files and unrelated assets.
$SearchExtensions = @(
    ".yml",
    ".yaml",
    ".json",
    ".tf",
    ".tfvars",
    ".ps1",
    ".psm1",
    ".sh",
    ".bash",
    ".properties",
    ".xml",
    ".config",
    ".toml",
    ".ini",
    ".py",
    ".js",
    ".ts",
    ".cs",
    ".gradle",
    ".groovy",
    ".txt",
    ".md",
    ".sql",
    ".env",
    ".dockerfile"
)

# ------------------------------------------------------------
# Utility functions
# ------------------------------------------------------------

function ConvertTo-EncodedSegment {
    param([Parameter(Mandatory)][string]$Value)

    return [Uri]::EscapeDataString($Value)
}

function Get-ObjectProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Invoke-AzureGet {
    param([Parameter(Mandatory)][string]$Uri)

    if ($RequestDelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $RequestDelayMilliseconds
    }

    return Invoke-RestMethod `
        -Method Get `
        -Uri $Uri `
        -Headers $AzureHeaders `
        -ErrorAction Stop
}

function Import-ProjectsCsv {
    param([Parameter(Mandatory)][string]$Path)

    foreach ($delimiter in @(",", ";", "`t")) {
        try {
            $rows = @(Import-Csv -LiteralPath $Path -Delimiter $delimiter -ErrorAction Stop)

            if ($rows.Count -eq 0) {
                continue
            }

            $headers = @($rows[0].PSObject.Properties.Name)

            $nameHeader = $headers |
                Where-Object {
                    $_.Trim().TrimStart([char]0xFEFF) -ieq "ProjectName"
                } |
                Select-Object -First 1

            $keyHeader = $headers |
                Where-Object {
                    $_.Trim().TrimStart([char]0xFEFF) -ieq "ProjectKey"
                } |
                Select-Object -First 1

            if (-not $keyHeader) {
                continue
            }

            $projects = foreach ($row in $rows) {
                $key = ([string](
                    Get-ObjectProperty -Object $row -Name $keyHeader
                )).Trim()

                $name = ""

                if ($nameHeader) {
                    $name = ([string](
                        Get-ObjectProperty -Object $row -Name $nameHeader
                    )).Trim()
                }

                if (-not [string]::IsNullOrWhiteSpace($key)) {
                    [PSCustomObject]@{
                        ProjectName = $name
                        ProjectKey  = $key
                    }
                }
            }

            return @($projects)
        }
        catch {
            # Try the next delimiter.
        }
    }

    throw "Could not read the CSV. A ProjectKey column is required."
}

# ------------------------------------------------------------
# Azure DevOps API functions
# ------------------------------------------------------------

function Get-AzureProjects {
    $uri = "$AzureBaseUrl/_apis/projects?`$top=1000&api-version=7.1"

    $response = Invoke-AzureGet -Uri $uri

    return @($response.value)
}

function Get-AzureRepositories {
    param([Parameter(Mandatory)][string]$ProjectName)

    $encodedProject = ConvertTo-EncodedSegment -Value $ProjectName

    $uri = "$AzureBaseUrl/$encodedProject/_apis/git/repositories?api-version=7.1"

    $response = Invoke-AzureGet -Uri $uri

    return @($response.value)
}

function Get-RepositoryFiles {
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RepositoryId
    )

    $encodedProject = ConvertTo-EncodedSegment -Value $ProjectName
    $encodedRepository = ConvertTo-EncodedSegment -Value $RepositoryId

    $uri = "$AzureBaseUrl/$encodedProject/_apis/git/repositories/$encodedRepository/items?recursionLevel=Full&includeContentMetadata=true&api-version=7.1"

    $response = Invoke-AzureGet -Uri $uri

    return @($response.value)
}

function Get-RepositoryFileContent {
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$FilePath
    )

    $encodedProject = ConvertTo-EncodedSegment -Value $ProjectName
    $encodedRepository = ConvertTo-EncodedSegment -Value $RepositoryId
    $encodedPath = ConvertTo-EncodedSegment -Value $FilePath

    $uri = "$AzureBaseUrl/$encodedProject/_apis/git/repositories/$encodedRepository/items?path=$encodedPath&includeContent=true&api-version=7.1"

    return Invoke-AzureGet -Uri $uri
}

# ------------------------------------------------------------
# Load SonarQube project keys
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================================"
Write-Host "Azure DevOps Repository File Search"
Write-Host "============================================================"
Write-Host ""

$SonarProjects = @(Import-ProjectsCsv -Path $InputCsv)

if ($SonarProjects.Count -eq 0) {
    throw "No SonarQube project keys were found in the input CSV."
}

# Remove duplicate keys while preserving the first occurrence.
$UniqueProjects = @(
    $SonarProjects |
        Group-Object -Property ProjectKey |
        ForEach-Object { $_.Group[0] }
)

$SonarProjects = $UniqueProjects

Write-Host "Input CSV: $InputCsv"
Write-Host "Unique SonarQube project keys: $($SonarProjects.Count)"
Write-Host "Azure DevOps organization: $Organization"
Write-Host "Search extensions: $($SearchExtensions -join ', ')"

# ------------------------------------------------------------
# Retrieve organization projects
# ------------------------------------------------------------

Write-Host ""
Write-Host "Retrieving Azure DevOps projects..."

$AzureProjects = @(Get-AzureProjects)

Write-Host "Projects found: $($AzureProjects.Count)"

# ------------------------------------------------------------
# Search repositories
# ------------------------------------------------------------

$Results = [System.Collections.Generic.List[object]]::new()
$SearchErrors = [System.Collections.Generic.List[object]]::new()

$RepositoryCount = 0
$FilesListedCount = 0
$FilesScannedCount = 0
$FilesMatchedCount = 0

foreach ($azureProject in $AzureProjects) {
    $azureProjectName = [string](
        Get-ObjectProperty -Object $azureProject -Name "name"
    )

    if ([string]::IsNullOrWhiteSpace($azureProjectName)) {
        continue
    }

    Write-Host ""
    Write-Host "Scanning project: $azureProjectName"

    try {
        $repositories = @(Get-AzureRepositories -ProjectName $azureProjectName)
    }
    catch {
        $SearchErrors.Add([PSCustomObject]@{
            ProjectName    = $azureProjectName
            RepositoryName = ""
            FilePath       = ""
            Stage          = "ListRepositories"
            Error          = $_.Exception.Message
        })

        Write-Warning "Could not list repositories in '$azureProjectName': $($_.Exception.Message)"
        continue
    }

    foreach ($repository in $repositories) {
        $repositoryId = [string](
            Get-ObjectProperty -Object $repository -Name "id"
        )

        $repositoryName = [string](
            Get-ObjectProperty -Object $repository -Name "name"
        )

        if ([string]::IsNullOrWhiteSpace($repositoryId)) {
            continue
        }

        $RepositoryCount++

        Write-Host "  Repository: $repositoryName"

        try {
            $items = @(Get-RepositoryFiles `
                -ProjectName $azureProjectName `
                -RepositoryId $repositoryId)

            $FilesListedCount += $items.Count
        }
        catch {
            $SearchErrors.Add([PSCustomObject]@{
                ProjectName    = $azureProjectName
                RepositoryName = $repositoryName
                FilePath       = ""
                Stage          = "ListFiles"
                Error          = $_.Exception.Message
            })

            Write-Warning "Could not list files in '$azureProjectName / $repositoryName': $($_.Exception.Message)"
            continue
        }

        # Keep only file objects with supported text extensions.
        $candidateFiles = @(
            $items | Where-Object {
                $item = $_

                $isFolder = Get-ObjectProperty -Object $item -Name "isFolder"
                $path = [string](Get-ObjectProperty -Object $item -Name "path")
                $objectType = [string](Get-ObjectProperty -Object $item -Name "gitObjectType")

                if ($isFolder -eq $true -or $objectType -eq "tree") {
                    return $false
                }

                if ([string]::IsNullOrWhiteSpace($path)) {
                    return $false
                }

                $fileName = [System.IO.Path]::GetFileName($path)
                $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()

                if ($SearchExtensions -contains $extension) {
                    return $true
                }

                # Handle extensionless environment and Docker files.
                if ($fileName -ieq "Dockerfile" -or $fileName -ieq ".env") {
                    return $true
                }

                return $false
            }
        )

        Write-Host "    Candidate text files: $($candidateFiles.Count)"

        foreach ($file in $candidateFiles) {
            $filePath = [string](
                Get-ObjectProperty -Object $file -Name "path"
            )

            $contentMetadata = Get-ObjectProperty -Object $file -Name "contentMetadata"
            $isBinary = Get-ObjectProperty -Object $contentMetadata -Name "isBinary"

            if ($isBinary -eq $true) {
                continue
            }

            try {
                $fileResponse = Get-RepositoryFileContent `
                    -ProjectName $azureProjectName `
                    -RepositoryId $repositoryId `
                    -FilePath $filePath

                $content = [string](
                    Get-ObjectProperty -Object $fileResponse -Name "content"
                )

                $FilesScannedCount++

                if ([string]::IsNullOrEmpty($content)) {
                    continue
                }

                # Search every key against this file's content.
                foreach ($sonarProject in $SonarProjects) {
                    $key = $sonarProject.ProjectKey

                    if (
                        $content.IndexOf(
                            $key,
                            [System.StringComparison]::OrdinalIgnoreCase
                        ) -ge 0
                    ) {
                        $FilesMatchedCount++

                        $Results.Add([PSCustomObject]@{
                            ProjectKey      = $key
                            SonarProjectName = $sonarProject.ProjectName
                            AzureProjectName = $azureProjectName
                            AzureProjectId   = [string](
                                Get-ObjectProperty -Object $azureProject -Name "id"
                            )
                            RepositoryName   = $repositoryName
                            RepositoryId     = $repositoryId
                            FilePath         = $filePath
                            MatchStatus      = "MatchFound"
                            Approved         = "NO"
                            Notes            = "The key was found in the retrieved file content. Verify the repository before creating a binding."
                        })
                    }
                }
            }
            catch {
                $SearchErrors.Add([PSCustomObject]@{
                    ProjectName    = $azureProjectName
                    RepositoryName = $repositoryName
                    FilePath       = $filePath
                    Stage          = "ReadFile"
                    Error          = $_.Exception.Message
                })

                Write-Warning "Could not read file '$azureProjectName / $repositoryName / $filePath': $($_.Exception.Message)"
            }
        }
    }
}

# ------------------------------------------------------------
# Add a result for keys with no match
# ------------------------------------------------------------

$MatchedKeys = @(
    $Results |
        Select-Object -ExpandProperty ProjectKey -Unique
)

foreach ($sonarProject in $SonarProjects) {
    if ($MatchedKeys -notcontains $sonarProject.ProjectKey) {
        $Results.Add([PSCustomObject]@{
            ProjectKey       = $sonarProject.ProjectKey
            SonarProjectName = $sonarProject.ProjectName
            AzureProjectName = ""
            AzureProjectId   = ""
            RepositoryName   = ""
            RepositoryId     = ""
            FilePath         = ""
            MatchStatus      = "NoMatch"
            Approved         = "NO"
            Notes            = "No match was found in the supported file types that were successfully scanned. Review search errors before concluding that the key is absent."
        })
    }
}

# ------------------------------------------------------------
# Export search results
# ------------------------------------------------------------

$Results |
    Sort-Object ProjectKey, AzureProjectName, RepositoryName, FilePath |
    Export-Csv `
        -LiteralPath $OutputCsv `
        -NoTypeInformation `
        -Encoding UTF8

# Export errors separately for troubleshooting.
$ErrorCsv = [System.IO.Path]::Combine(
    [System.IO.Path]::GetDirectoryName($OutputCsv),
    "Sonar_AzDO_File_Search_Errors.csv"
)

$SearchErrors |
    Export-Csv `
        -LiteralPath $ErrorCsv `
        -NoTypeInformation `
        -Encoding UTF8

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

$MatchedKeyCount = @(
    $Results |
        Where-Object { $_.MatchStatus -eq "MatchFound" } |
        Select-Object -ExpandProperty ProjectKey -Unique
).Count

$UnmatchedKeyCount = @(
    $Results |
        Where-Object { $_.MatchStatus -eq "NoMatch" }
).Count

Write-Host ""
Write-Host "============================================================"
Write-Host "Search completed"
Write-Host "============================================================"
Write-Host "Azure DevOps projects processed: $($AzureProjects.Count)"
Write-Host "Repositories processed: $RepositoryCount"
Write-Host "Repository items listed: $FilesListedCount"
Write-Host "Files scanned: $FilesScannedCount"
Write-Host "Matching file/key pairs: $FilesMatchedCount"
Write-Host "SonarQube keys with matches: $MatchedKeyCount"
Write-Host "SonarQube keys without matches: $UnmatchedKeyCount"
Write-Host "Search errors: $($SearchErrors.Count)"
Write-Host ""
Write-Host "Search results: $OutputCsv"
Write-Host "Search errors: $ErrorCsv"
Write-Host ""
Write-Host "No SonarQube bindings were created or modified."
