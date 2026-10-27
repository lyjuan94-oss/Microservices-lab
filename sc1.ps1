
# ============================================================
# SonarQube to Azure DevOps Binding Discovery
# Method:
#   1. Retrieve Azure DevOps pipeline inventory.
#   2. Retrieve build definition metadata.
#   3. Request expanded YAML through the Pipeline Preview API.
#   4. Match SonarQube project keys against expanded YAML.
#
# READ-ONLY:
#   This script does not create, update, or delete bindings.
#
# Required environment variables:
#   SONARQUBE_TOKEN
#   AZDO_PAT or SYSTEM_ACCESSTOKEN
#
# Input:
#   Sonar_Projects_Without_Binding.csv
#
# Output:
#   Sonar_AzDO_Binding_Discovery.csv
# ============================================================

[CmdletBinding()]
param(
    [string]$InputCsv = (Join-Path $PSScriptRoot "Sonar_Projects_Without_Binding.csv"),
    [string]$OutputCsv = (Join-Path $PSScriptRoot "Sonar_AzDO_Binding_Discovery.csv"),
    [string]$SonarUrl = "https://aas-sonar-pr.azure-paas.com",
    [string]$Organization = "AASolutions",
    [int]$RequestDelayMilliseconds = 0
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Authentication
# ------------------------------------------------------------

$SonarToken = $env:SONARQUBE_TOKEN

$AzureToken = $env:AZDO_PAT
if ([string]::IsNullOrWhiteSpace($AzureToken)) {
    $AzureToken = $env:SYSTEM_ACCESSTOKEN
}

if ([string]::IsNullOrWhiteSpace($SonarToken)) {
    throw "SONARQUBE_TOKEN environment variable is not set."
}

if ([string]::IsNullOrWhiteSpace($AzureToken)) {
    throw "AZDO_PAT or SYSTEM_ACCESSTOKEN environment variable is not set."
}

if (-not (Test-Path -LiteralPath $InputCsv)) {
    throw "Input CSV file was not found: $InputCsv"
}

$SonarUrl = $SonarUrl.TrimEnd("/")
$AzureBaseUrl = "https://dev.azure.com/$Organization"

$SonarEncodedToken = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${SonarToken}:")
)

$AzureEncodedToken = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":${AzureToken}")
)

$SonarHeaders = @{
    Authorization = "Basic $SonarEncodedToken"
    Accept        = "application/json"
}

$AzureHeaders = @{
    Authorization = "Basic $AzureEncodedToken"
    Accept        = "application/json"
}

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

function Get-HttpStatusCode {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        if ($null -ne $ErrorRecord.Exception.Response.StatusCode) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    }
    catch {
        # The response may not expose an HTTP status code.
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

    $delimiters = @(",", ";", "`t")
    $requiredColumns = @("ProjectName", "ProjectKey")

    foreach ($delimiter in $delimiters) {
        try {
            $rows = @(Import-Csv -LiteralPath $Path -Delimiter $delimiter -ErrorAction Stop)

            if ($rows.Count -eq 0) {
                continue
            }

            $headers = @($rows[0].PSObject.Properties.Name)

            $normalizedHeaders = @(
                $headers | ForEach-Object {
                    $_.Trim().TrimStart([char]0xFEFF)
                }
            )

            $hasRequiredColumns = $true

            foreach ($requiredColumn in $requiredColumns) {
                if ($normalizedHeaders -notcontains $requiredColumn) {
                    $hasRequiredColumns = $false
                    break
                }
            }

            if (-not $hasRequiredColumns) {
                continue
            }

            $normalizedRows = foreach ($row in $rows) {
                $projectName = [string](Get-ObjectProperty -Object $row -Name "ProjectName")
                $projectKey = [string](Get-ObjectProperty -Object $row -Name "ProjectKey")

                [PSCustomObject]@{
                    ProjectName = $projectName.Trim()
                    ProjectKey  = $projectKey.Trim()
                }
            }

            return @(
                $normalizedRows | Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.ProjectKey)
                }
            )
        }
        catch {
            # Try the next delimiter.
        }
    }

    throw "Could not import the CSV. Required columns are ProjectName and ProjectKey. Supported delimiters are comma, semicolon, and tab."
}

# ------------------------------------------------------------
# SonarQube binding verification
# ------------------------------------------------------------

function Get-SonarBindingState {
    param([Parameter(Mandatory)][string]$ProjectKey)

    $encodedKey = ConvertTo-EncodedSegment -Value $ProjectKey
    $uri = "$SonarUrl/api/alm_settings/get_binding?project=$encodedKey"

    try {
        $null = Invoke-RestMethod `
            -Method Get `
            -Uri $uri `
            -Headers $SonarHeaders `
            -ErrorAction Stop

        return [PSCustomObject]@{
            State = "Bound"
            Error = ""
        }
    }
    catch {
        $statusCode = Get-HttpStatusCode -ErrorRecord $_

        if ($statusCode -eq 404) {
            return [PSCustomObject]@{
                State = "NotBound"
                Error = ""
            }
        }

        return [PSCustomObject]@{
            State = "CheckError"
            Error = $_.Exception.Message
        }
    }
}

# ------------------------------------------------------------
# Azure DevOps inventory
# ------------------------------------------------------------

function Get-AzureProjects {
    $uri = "$AzureBaseUrl/_apis/projects?`$top=1000&api-version=7.1"
    $response = Invoke-AzureGet -Uri $uri

    return @($response.value)
}

function Get-AzurePipelines {
    param([Parameter(Mandatory)][string]$ProjectId)

    $encodedProjectId = ConvertTo-EncodedSegment -Value $ProjectId
    $uri = "$AzureBaseUrl/$encodedProjectId/_apis/pipelines?`$top=1000&api-version=7.1"

    $response = Invoke-AzureGet -Uri $uri

    return @($response.value)
}

# Uses the Build Definitions API to retrieve repository and YAML metadata.
function Get-PipelineDetails {
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$PipelineId
    )

    $encodedProjectId = ConvertTo-EncodedSegment -Value $ProjectId

    $uri = "$AzureBaseUrl/$encodedProjectId/_apis/build/definitions/$PipelineId?api-version=7.1"

    return Invoke-AzureGet -Uri $uri
}

# ------------------------------------------------------------
# Pipeline Preview API with detailed HTTP diagnostics
# ------------------------------------------------------------

function Get-PipelinePreview {
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$PipelineId
    )

    $encodedProjectId = ConvertTo-EncodedSegment -Value $ProjectId
    $uri = "$AzureBaseUrl/$encodedProjectId/_apis/pipelines/$PipelineId/preview?api-version=7.1"

    $body = @{
        previewRun = $true
    } | ConvertTo-Json -Compress

    if ($RequestDelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $RequestDelayMilliseconds
    }

    try {
        return Invoke-RestMethod `
            -Method Post `
            -Uri $uri `
            -Headers $AzureHeaders `
            -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -ErrorAction Stop
    }
    catch {
        $statusCode = Get-HttpStatusCode -ErrorRecord $_
        $responseBody = $null

        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $responseBody = $_.ErrorDetails.Message
        }
        else {
            try {
                $response = $_.Exception.Response
                $stream = $response.GetResponseStream()

                if ($null -ne $stream) {
                    $reader = [System.IO.StreamReader]::new($stream)
                    $responseBody = $reader.ReadToEnd()
                    $reader.Dispose()
                }
            }
            catch {
                $responseBody = "The response body could not be read."
            }
        }

        if ([string]::IsNullOrWhiteSpace($responseBody)) {
            $responseBody = $_.Exception.Message
        }

        throw "Pipeline preview failed. ProjectId='$ProjectId'; PipelineId='$PipelineId'; HTTP=$statusCode; Details=$responseBody"
    }
}

# ------------------------------------------------------------
# Extract repository and YAML metadata
# Supports Build Definition API response format.
# ------------------------------------------------------------

function Get-RepositoryMetadata {
    param([AllowNull()][object]$Definition)

    $repository = Get-ObjectProperty -Object $Definition -Name "repository"
    $process = Get-ObjectProperty -Object $Definition -Name "process"

    $repositoryId = [string](Get-ObjectProperty -Object $repository -Name "id")
    $repositoryName = [string](Get-ObjectProperty -Object $repository -Name "name")
    $repositoryType = [string](Get-ObjectProperty -Object $repository -Name "type")

    $yamlPath = [string](Get-ObjectProperty -Object $process -Name "yamlFilename")
    $processType = Get-ObjectProperty -Object $process -Name "type"

    $configurationType = "unknown"

    # Build definition process type 2 represents YAML.
    if ($null -ne $processType -and [string]$processType -eq "2") {
        $configurationType = "yaml"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($yamlPath)) {
        $configurationType = "yaml"
    }

    # Some API responses may expose pipeline configuration instead.
    if ([string]::IsNullOrWhiteSpace($repositoryId)) {
        $configuration = Get-ObjectProperty -Object $Definition -Name "configuration"
        $configurationRepository = Get-ObjectProperty -Object $configuration -Name "repository"

        $repositoryId = [string](Get-ObjectProperty -Object $configurationRepository -Name "id")
        $repositoryName = [string](Get-ObjectProperty -Object $configurationRepository -Name "name")
        $yamlPath = [string](Get-ObjectProperty -Object $configuration -Name "path")

        if ((Get-ObjectProperty -Object $configuration -Name "type") -eq "yaml") {
            $configurationType = "yaml"
        }
    }

    return [PSCustomObject]@{
        RepositoryId = $repositoryId
        RepositoryName = $repositoryName
        RepositoryType = $repositoryType
        YamlPath = $yamlPath
        ConfigurationType = $configurationType
    }
}

# ------------------------------------------------------------
# YAML matching helpers
# ------------------------------------------------------------

function Test-ProjectKeyInYaml {
    param(
        [Parameter(Mandatory)][string]$Yaml,
        [Parameter(Mandatory)][string]$ProjectKey
    )

    if ([string]::IsNullOrWhiteSpace($Yaml)) {
        return $false
    }

    $escapedKey = [regex]::Escape($ProjectKey)
    $pattern = "(?<![A-Za-z0-9_.-])$escapedKey(?![A-Za-z0-9_.-])"

    return [regex]::IsMatch(
        $Yaml,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Get-YamlEvidence {
    param(
        [Parameter(Mandatory)][string]$Yaml,
        [Parameter(Mandatory)][string]$ProjectKey
    )

    $lines = $Yaml -split "`r?`n"
    $escapedKey = [regex]::Escape($ProjectKey)
    $pattern = "(?<![A-Za-z0-9_.-])$escapedKey(?![A-Za-z0-9_.-])"

    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ([regex]::IsMatch(
            $lines[$index],
            $pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )) {
            $line = $lines[$index].Trim()

            if ($line.Length -gt 250) {
                $line = $line.Substring(0, 250)
            }

            return "Line $($index + 1): $line"
        }
    }

    return ""
}

# ------------------------------------------------------------
# Load SonarQube projects
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================================"
Write-Host "SonarQube to Azure DevOps Binding Discovery"
Write-Host "============================================================"
Write-Host ""

$SonarProjects = @(Import-ProjectsCsv -Path $InputCsv)

if ($SonarProjects.Count -eq 0) {
    throw "No valid SonarQube projects were found in the input CSV."
}

Write-Host "Input CSV: $InputCsv"
Write-Host "SonarQube projects loaded: $($SonarProjects.Count)"

# ------------------------------------------------------------
# Retrieve Azure DevOps projects
# ------------------------------------------------------------

Write-Host ""
Write-Host "Retrieving Azure DevOps projects..."

$AzureProjects = @(Get-AzureProjects)

Write-Host "Azure DevOps projects found: $($AzureProjects.Count)"

# ------------------------------------------------------------
# Inventory YAML pipelines and retrieve previews
# ------------------------------------------------------------

$PipelineInventory = [System.Collections.Generic.List[object]]::new()
$PreviewErrorCount = 0
$MetadataErrorCount = 0
$NonYamlCount = 0
$PipelineCounter = 0

foreach ($azureProject in $AzureProjects) {
    $azureProjectId = [string](Get-ObjectProperty -Object $azureProject -Name "id")
    $azureProjectName = [string](Get-ObjectProperty -Object $azureProject -Name "name")

    if ([string]::IsNullOrWhiteSpace($azureProjectId)) {
        continue
    }

    Write-Host ""
    Write-Host "Scanning Azure DevOps project: $azureProjectName"

    try {
        $pipelines = @(Get-AzurePipelines -ProjectId $azureProjectId)
    }
    catch {
        Write-Warning "Could not list pipelines in '$azureProjectName': $($_.Exception.Message)"
        continue
    }

    foreach ($pipeline in $pipelines) {
        $pipelineId = [string](Get-ObjectProperty -Object $pipeline -Name "id")
        $pipelineName = [string](Get-ObjectProperty -Object $pipeline -Name "name")

        if ([string]::IsNullOrWhiteSpace($pipelineId)) {
            continue
        }

        $PipelineCounter++

        $definition = $null
        $metadata = $null
        $metadataStatus = "Success"
        $metadataError = ""

        try {
            $definition = Get-PipelineDetails `
                -ProjectId $azureProjectId `
                -PipelineId $pipelineId

            $metadata = Get-RepositoryMetadata -Definition $definition
        }
        catch {
            $metadataStatus = "MetadataError"
            $metadataError = $_.Exception.Message
            $MetadataErrorCount++

            Write-Warning "Could not retrieve build definition for '$azureProjectName / $pipelineName' ($pipelineId): $metadataError"

            # Continue using the pipeline list object if it exposes metadata.
            $metadata = Get-RepositoryMetadata -Definition $pipeline
        }

        if ($metadata.ConfigurationType -ne "yaml") {
            $NonYamlCount++
            continue
        }

        $previewYaml = ""
        $previewStatus = "Success"
        $previewError = ""

        try {
            $preview = Get-PipelinePreview `
                -ProjectId $azureProjectId `
                -PipelineId $pipelineId

            $previewYaml = [string](Get-ObjectProperty -Object $preview -Name "finalYaml")

            if ([string]::IsNullOrWhiteSpace($previewYaml)) {
                $previewStatus = "EmptyPreview"
                $previewError = "The preview response did not contain finalYaml."
                $PreviewErrorCount++

                Write-Warning "Preview returned no finalYaml for '$azureProjectName / $pipelineName'."
            }
        }
        catch {
            $previewStatus = "PreviewError"
            $previewError = $_.Exception.Message
            $PreviewErrorCount++

            Write-Warning $previewError
        }

        $PipelineInventory.Add([PSCustomObject]@{
            AzureProjectName = $azureProjectName
            AzureProjectId = $azureProjectId
            PipelineName = $pipelineName
            PipelineId = $pipelineId
            RepositoryName = $metadata.RepositoryName
            RepositoryId = $metadata.RepositoryId
            RepositoryType = $metadata.RepositoryType
            YamlPath = $metadata.YamlPath
            ConfigurationType = $metadata.ConfigurationType
            MetadataStatus = $metadataStatus
            MetadataError = $metadataError
            PreviewStatus = $previewStatus
            PreviewError = $previewError
            FinalYaml = $previewYaml
        })
    }
}

Write-Host ""
Write-Host "Pipeline inventory completed."
Write-Host "Pipeline records processed: $PipelineCounter"
Write-Host "YAML pipeline records inventoried: $($PipelineInventory.Count)"
Write-Host "Non-YAML or unrecognized pipelines skipped: $NonYamlCount"
Write-Host "Metadata retrieval errors: $MetadataErrorCount"
Write-Host "Preview errors or empty previews: $PreviewErrorCount"

# ------------------------------------------------------------
# Match SonarQube project keys against expanded YAML
# ------------------------------------------------------------

$Results = [System.Collections.Generic.List[object]]::new()
$SonarCounter = 0

foreach ($sonarProject in $SonarProjects) {
    $SonarCounter++

    $projectName = $sonarProject.ProjectName
    $projectKey = $sonarProject.ProjectKey

    Write-Progress `
        -Activity "Matching SonarQube projects" `
        -Status "$projectName ($SonarCounter of $($SonarProjects.Count))" `
        -PercentComplete (($SonarCounter / $SonarProjects.Count) * 100)

    $binding = Get-SonarBindingState -ProjectKey $projectKey

    if ($binding.State -eq "Bound") {
        $Results.Add([PSCustomObject]@{
            ProjectName = $projectName
            ProjectKey = $projectKey
            BindingState = "AlreadyBound"
            MatchStatus = "SkippedAlreadyBound"
            CandidateCount = 0
            AzureProjectName = ""
            AzureProjectId = ""
            RepositoryName = ""
            RepositoryId = ""
            RepositoryType = ""
            PipelineName = ""
            PipelineId = ""
            YamlPath = ""
            Evidence = ""
            PreviewError = ""
            Approved = "NO"
            Notes = "An existing SonarQube binding was found. No changes were made."
        })

        continue
    }

    if ($binding.State -eq "CheckError") {
        $Results.Add([PSCustomObject]@{
            ProjectName = $projectName
            ProjectKey = $projectKey
            BindingState = "CheckError"
            MatchStatus = "BindingCheckError"
            CandidateCount = 0
            AzureProjectName = ""
            AzureProjectId = ""
            RepositoryName = ""
            RepositoryId = ""
            RepositoryType = ""
            PipelineName = ""
            PipelineId = ""
            YamlPath = ""
            Evidence = ""
            PreviewError = $binding.Error
            Approved = "NO"
            Notes = "The existing binding could not be verified. Review this project manually."
        })

        continue
    }

    $matches = [System.Collections.Generic.List[object]]::new()
    $projectPreviewErrors = [System.Collections.Generic.List[string]]::new()

    foreach ($inventoryItem in $PipelineInventory) {
        if ($inventoryItem.PreviewStatus -ne "Success") {
            if ($inventoryItem.PreviewStatus -eq "PreviewError") {
                $projectPreviewErrors.Add(
                    "$($inventoryItem.AzureProjectName) / $($inventoryItem.PipelineName): $($inventoryItem.PreviewError)"
                )
            }

            continue
        }

        if (Test-ProjectKeyInYaml -Yaml $inventoryItem.FinalYaml -ProjectKey $projectKey) {
            $evidence = Get-YamlEvidence `
                -Yaml $inventoryItem.FinalYaml `
                -ProjectKey $projectKey

            $matches.Add([PSCustomObject]@{
                AzureProjectName = $inventoryItem.AzureProjectName
                AzureProjectId = $inventoryItem.AzureProjectId
                RepositoryName = $inventoryItem.RepositoryName
                RepositoryId = $inventoryItem.RepositoryId
                RepositoryType = $inventoryItem.RepositoryType
                PipelineName = $inventoryItem.PipelineName
                PipelineId = $inventoryItem.PipelineId
                YamlPath = $inventoryItem.YamlPath
                Evidence = $evidence
            })
        }
    }

    # Multiple pipelines from the same repository count as one candidate.
    $repositoryGroups = @(
        $matches | Group-Object -Property {
            if (
                -not [string]::IsNullOrWhiteSpace($_.RepositoryId) -and
                -not [string]::IsNullOrWhiteSpace($_.AzureProjectId)
            ) {
                "$($_.AzureProjectId)|$($_.RepositoryId)"
            }
            else {
                "MISSING|$($_.AzureProjectId)|$($_.PipelineId)"
            }
        }
    )

    if ($repositoryGroups.Count -eq 0) {
        if ($projectPreviewErrors.Count -gt 0) {
            $status = "PreviewError"
            $notes = "No match was found in successfully previewed pipelines, but some previews failed. The result may be incomplete."
            $errorText = ($projectPreviewErrors | Select-Object -First 10) -join " || "
        }
        else {
            $status = "NoMatch"
            $notes = "The project key was not found in the expanded YAML of the successfully previewed pipelines."
            $errorText = ""
        }

        $Results.Add([PSCustomObject]@{
            ProjectName = $projectName
            ProjectKey = $projectKey
            BindingState = "NotBound"
            MatchStatus = $status
            CandidateCount = 0
            AzureProjectName = ""
            AzureProjectId = ""
            RepositoryName = ""
            RepositoryId = ""
            RepositoryType = ""
            PipelineName = ""
            PipelineId = ""
            YamlPath = ""
            Evidence = ""
            PreviewError = $errorText
            Approved = "NO"
            Notes = $notes
        })

        continue
    }

    $candidateCount = $repositoryGroups.Count

    foreach ($repositoryGroup in $repositoryGroups) {
        $groupMatches = @($repositoryGroup.Group)
        $firstMatch = $groupMatches[0]

        $hasRepositoryMetadata = (
            -not [string]::IsNullOrWhiteSpace($firstMatch.RepositoryId) -and
            -not [string]::IsNullOrWhiteSpace($firstMatch.RepositoryName)
        )

        if (-not $hasRepositoryMetadata) {
            $matchStatus = "RepositoryMetadataMissing"
            $notes = "The project key was found in pipeline YAML, but repository metadata is incomplete. Verify the repository manually."
        }
        elseif ($candidateCount -eq 1) {
            $matchStatus = "UniqueRepositoryMatch"
            $notes = "One distinct Azure DevOps repository matched the project key. Review the evidence before approving."
        }
        else {
            $matchStatus = "AmbiguousRepositoryMatch"
            $notes = "Multiple distinct Azure DevOps repositories matched the project key. Manual investigation is required."
        }

        $pipelineNames = @(
            $groupMatches | ForEach-Object { $_.PipelineName } | Select-Object -Unique
        )

        $pipelineIds = @(
            $groupMatches | ForEach-Object { $_.PipelineId } | Select-Object -Unique
        )

        $yamlPaths = @(
            $groupMatches | ForEach-Object { $_.YamlPath } |
                Where-Object { $_ } | Select-Object -Unique
        )

        $evidenceLines = @(
            $groupMatches | ForEach-Object { $_.Evidence } |
                Where-Object { $_ } | Select-Object -Unique
        )

        $repositoryTypes = @(
            $groupMatches | ForEach-Object { $_.RepositoryType } |
                Where-Object { $_ } | Select-Object -Unique
        )

        $Results.Add([PSCustomObject]@{
            ProjectName = $projectName
            ProjectKey = $projectKey
            BindingState = "NotBound"
            MatchStatus = $matchStatus
            CandidateCount = $candidateCount
            AzureProjectName = $firstMatch.AzureProjectName
            AzureProjectId = $firstMatch.AzureProjectId
            RepositoryName = $firstMatch.RepositoryName
            RepositoryId = $firstMatch.RepositoryId
            RepositoryType = ($repositoryTypes -join " | ")
            PipelineName = ($pipelineNames -join " | ")
            PipelineId = ($pipelineIds -join " | ")
            YamlPath = ($yamlPaths -join " | ")
            Evidence = ($evidenceLines -join " | ")
            PreviewError = ""
            Approved = "NO"
            Notes = $notes
        })
    }
}

Write-Progress -Activity "Matching SonarQube projects" -Completed

# ------------------------------------------------------------
# Export results
# ------------------------------------------------------------

$Results |
    Export-Csv `
        -LiteralPath $OutputCsv `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host "Discovery completed"
Write-Host "============================================================"
Write-Host "SonarQube projects processed: $($SonarProjects.Count)"
Write-Host "Pipeline records processed: $PipelineCounter"
Write-Host "YAML pipeline records inventoried: $($PipelineInventory.Count)"
Write-Host "Metadata retrieval errors: $MetadataErrorCount"
Write-Host "Preview errors or empty previews: $PreviewErrorCount"
Write-Host "Results exported to: $OutputCsv"
Write-Host ""
Write-Host "All candidates require manual review."
Write-Host "Approved is set to NO for every row."
Write-Host "No SonarQube bindings were created or modified."
