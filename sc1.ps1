[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [string]$OutputCsv = ".\Sonar_Azure_Binding_Discovery.csv",

    [string]$SonarUrl = "https://aas-sonar-pr.azure-paas.com",

    [string]$AzureOrganization = "AASolutions"
)

$ErrorActionPreference = 'Stop'

# ============================================================
# 1. CONFIGURATION AND AUTHENTICATION
# ============================================================

if ([string]::IsNullOrWhiteSpace($env:SONARQUBE_TOKEN)) {
    throw "Environment variable SONARQUBE_TOKEN is not defined."
}

if (-not [string]::IsNullOrWhiteSpace($env:AZDO_PAT)) {
    $AzdoToken = $env:AZDO_PAT
}
elseif (-not [string]::IsNullOrWhiteSpace($env:SYSTEM_ACCESSTOKEN)) {
    $AzdoToken = $env:SYSTEM_ACCESSTOKEN
}
else {
    throw "Define AZDO_PAT or SYSTEM_ACCESSTOKEN."
}

$SonarUrl = $SonarUrl.TrimEnd('/')
$AzureBase = "https://dev.azure.com/$AzureOrganization"

$SonarHeaders = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes(
            "$($env:SONARQUBE_TOKEN):"
        )
    )
}

$AzdoHeaders = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes(
            ":$AzdoToken"
        )
    )
}

# ============================================================
# 2. SAFE OBJECT PROPERTY ACCESS
# Prevents failures when API objects omit optional properties.
# ============================================================

function Get-PropertyValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$PropertyName]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Invoke-JsonGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    Invoke-RestMethod `
        -Method Get `
        -Uri $Url `
        -Headers $Headers `
        -TimeoutSec 90 `
        -ErrorAction Stop
}

function Get-HttpStatusCode {
    param($ErrorRecord)

    try {
        if ($null -ne $ErrorRecord.Exception.Response) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    }
    catch {}

    return $null
}

# ============================================================
# 3. READ AND VALIDATE THE INPUT CSV
# Supports comma, semicolon, and UTF-8 BOM.
# ============================================================

if (-not (Test-Path -LiteralPath $InputCsv -PathType Leaf)) {
    throw "Input CSV file does not exist: $InputCsv"
}

$InputCsv = (Resolve-Path -LiteralPath $InputCsv).Path

Write-Host ""
Write-Host "Input CSV: $InputCsv"

$csvRows = $null
$detectedDelimiter = $null

foreach ($candidateDelimiter in @(',', ';', "`t")) {
    try {
        $candidateRows = @(
            Import-Csv `
                -LiteralPath $InputCsv `
                -Delimiter $candidateDelimiter `
                -Encoding UTF8 `
                -ErrorAction Stop
        )

        if ($candidateRows.Count -eq 0) {
            continue
        }

        $headers = @(
            $candidateRows[0].PSObject.Properties |
                ForEach-Object {
                    ([string]$_.Name).Trim().TrimStart([char]0xFEFF)
                }
        )

        $hasName = @(
            $headers | Where-Object { $_ -ieq 'ProjectName' }
        ).Count -gt 0

        $hasKey = @(
            $headers | Where-Object { $_ -ieq 'ProjectKey' }
        ).Count -gt 0

        if ($hasName -and $hasKey) {
            $csvRows = $candidateRows
            $detectedDelimiter = $candidateDelimiter
            break
        }
    }
    catch {
        # Try the next delimiter.
    }
}

if ($null -eq $csvRows) {
    throw "Could not find ProjectName and ProjectKey columns in the input CSV."
}

$sonarRows = @(
    foreach ($row in $csvRows) {
        $projectName = ''
        $projectKey = ''

        foreach ($property in $row.PSObject.Properties) {
            $columnName = ([string]$property.Name).
                Trim().
                TrimStart([char]0xFEFF)

            if ($columnName -ieq 'ProjectName') {
                $projectName = ([string]$property.Value).Trim()
            }

            if ($columnName -ieq 'ProjectKey') {
                $projectKey = ([string]$property.Value).Trim()
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($projectKey)) {
            [pscustomobject]@{
                ProjectName = $projectName
                ProjectKey  = $projectKey
            }
        }
    }
)

if ($sonarRows.Count -eq 0) {
    throw "No valid project keys were found in the CSV."
}

Write-Host "CSV columns validated: ProjectName, ProjectKey"
Write-Host "SonarQube projects loaded: $($sonarRows.Count)"

# ============================================================
# 4. CHECK SONARQUBE BINDING STATUS
# ============================================================

function Test-SonarBinding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectKey
    )

    $encodedKey = [Uri]::EscapeDataString($ProjectKey)

    $uri = "$SonarUrl/api/alm_settings/get_binding?project=$encodedKey"

    try {
        $null = Invoke-JsonGet -Url $uri -Headers $SonarHeaders
        return 'AlreadyBound'
    }
    catch {
        $status = Get-HttpStatusCode $_

        if ($status -eq 404) {
            return 'Unbound'
        }

        return "BindingCheckError: $($_.Exception.Message)"
    }
}

# ============================================================
# 5. AZURE DEVOPS API FUNCTIONS
# ============================================================

function Get-AzdoProjects {
    $uri = "$AzureBase/_apis/projects?`$top=1000&stateFilter=wellFormed&api-version=7.1"

    $response = Invoke-JsonGet -Url $uri -Headers $AzdoHeaders

    return @(Get-PropertyValue -Object $response -PropertyName 'value')
}

function Get-AzdoPipelines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectId
    )

    $encodedProjectId = [Uri]::EscapeDataString($ProjectId)

    $uri = "$AzureBase/$encodedProjectId/_apis/pipelines?`$top=1000&api-version=7.1"

    $response = Invoke-JsonGet -Url $uri -Headers $AzdoHeaders

    return @(Get-PropertyValue -Object $response -PropertyName 'value')
}

function Get-PipelineDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectId,

        [Parameter(Mandatory = $true)]
        [int]$PipelineId
    )

    $encodedProjectId = [Uri]::EscapeDataString($ProjectId)

    $uri = "$AzureBase/$encodedProjectId/_apis/pipelines/$PipelineId`?api-version=7.1"

    return Invoke-JsonGet -Url $uri -Headers $AzdoHeaders
}

function Get-YamlContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectId,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryId,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $encodedProjectId = [Uri]::EscapeDataString($ProjectId)
    $encodedRepositoryId = [Uri]::EscapeDataString($RepositoryId)
    $encodedPath = [Uri]::EscapeDataString($Path)

    $uri = "$AzureBase/$encodedProjectId/_apis/git/repositories/$encodedRepositoryId/items?path=$encodedPath&includeContent=true&api-version=7.1"

    $response = Invoke-JsonGet -Url $uri -Headers $AzdoHeaders

    # Some API responses may be returned as plain text.
    if ($response -is [string]) {
        return $response
    }

    $content = Get-PropertyValue -Object $response -PropertyName 'content'

    if ($null -ne $content) {
        return [string]$content
    }

    return $null
}

# ============================================================
# 6. DISCOVER AZURE DEVOPS PROJECTS
# ============================================================

Write-Host ""
Write-Host "Retrieving Azure DevOps projects..."

$azProjects = @(Get-AzdoProjects)

if ($azProjects.Count -eq 0) {
    throw "Azure DevOps returned no projects. Check the PAT permissions."
}

Write-Host "Azure DevOps projects found: $($azProjects.Count)"

# ============================================================
# 7. INVENTORY YAML PIPELINES
# Classic pipelines are intentionally excluded.
# ============================================================

$pipelineInventory = [System.Collections.Generic.List[object]]::new()

$projectIndex = 0

foreach ($azProject in $azProjects) {
    $projectIndex++

    $azProjectId = [string](
        Get-PropertyValue $azProject 'id'
    )

    $azProjectName = [string](
        Get-PropertyValue $azProject 'name'
    )

    if ([string]::IsNullOrWhiteSpace($azProjectId)) {
        Write-Warning "Skipping an Azure DevOps project with no ID."
        continue
    }

    if ([string]::IsNullOrWhiteSpace($azProjectName)) {
        $azProjectName = $azProjectId
    }

    Write-Host "[$projectIndex/$($azProjects.Count)] Project: $azProjectName"

    try {
        $pipelines = @(Get-AzdoPipelines -ProjectId $azProjectId)
    }
    catch {
        Write-Warning "Could not list pipelines for '$azProjectName': $($_.Exception.Message)"
        continue
    }

    foreach ($pipeline in $pipelines) {
        $pipelineIdValue = Get-PropertyValue $pipeline 'id'
        $pipelineName = [string](
            Get-PropertyValue $pipeline 'name'
        )

        if ($null -eq $pipelineIdValue) {
            Write-Warning "Skipping a pipeline without an ID in '$azProjectName'."
            continue
        }

        if ([string]::IsNullOrWhiteSpace($pipelineName)) {
            $pipelineName = "Pipeline-$pipelineIdValue"
        }

        try {
            $details = Get-PipelineDetails `
                -ProjectId $azProjectId `
                -PipelineId ([int]$pipelineIdValue
            )
        }
        catch {
            Write-Warning "Could not read pipeline '$pipelineName': $($_.Exception.Message)"
            continue
        }

        $configuration = Get-PropertyValue $details 'configuration'

        if ($null -eq $configuration) {
            continue
        }

        $configurationType = [string](
            Get-PropertyValue $configuration 'type'
        )

        # Only YAML pipelines are included.
        if ($configurationType -ine 'yaml') {
            continue
        }

        $yamlPath = [string](
            Get-PropertyValue $configuration 'path'
        )

        $repository = Get-PropertyValue $configuration 'repository'

        if ([string]::IsNullOrWhiteSpace($yamlPath)) {
            Write-Warning "Pipeline '$pipelineName' has no YAML path."
            continue
        }

        if ($yamlPath -notmatch '\.ya?ml$') {
            Write-Warning "Skipping non-YAML path '$yamlPath' in '$pipelineName'."
            continue
        }

        $repositoryId = [string](
            Get-PropertyValue $repository 'id'
        )

        $repositoryName = [string](
            Get-PropertyValue $repository 'name'
        )

        $repositoryType = [string](
            Get-PropertyValue $repository 'type'
        )

        if ([string]::IsNullOrWhiteSpace($repositoryId)) {
            Write-Warning "Repository ID is missing for '$pipelineName'."
            continue
        }

        if ([string]::IsNullOrWhiteSpace($repositoryName)) {
            $repositoryName = $repositoryId
        }

        try {
            $yamlContent = Get-YamlContent `
                -ProjectId $azProjectId `
                -RepositoryId $repositoryId `
                -Path $yamlPath

            if ($null -ne $yamlContent) {
                $readStatus = 'ReadOK'
            }
            else {
                $readStatus = 'YamlContentMissing'
            }
        }
        catch {
            $yamlContent = $null
            $readStatus = "YamlReadError: $($_.Exception.Message)"

            Write-Warning "Could not read '$yamlPath' from '$repositoryName'."
        }

        $pipelineInventory.Add(
            [pscustomobject]@{
                AzureProjectName = $azProjectName
                AzureProjectId   = $azProjectId
                PipelineName     = $pipelineName
                PipelineId       = [int]$pipelineIdValue
                RepositoryName   = $repositoryName
                RepositoryId     = $repositoryId
                RepositoryType   = $repositoryType
                YamlPath         = $yamlPath
                YamlContent      = $yamlContent
                InventoryStatus  = $readStatus
            }
        )
    }
}

Write-Host ""
Write-Host "YAML pipeline inventory completed."
Write-Host "YAML pipelines inspected: $($pipelineInventory.Count)"

# ============================================================
# 8. MATCH SONARQUBE PROJECT KEYS AGAINST YAML CONTENT
# ============================================================

$results = [System.Collections.Generic.List[object]]::new()

$sonarIndex = 0

foreach ($sonarProject in $sonarRows) {
    $sonarIndex++

    $key = [string]$sonarProject.ProjectKey
    $name = [string]$sonarProject.ProjectName

    Write-Host "[$sonarIndex/$($sonarRows.Count)] Searching key: $key"

    $bindingState = Test-SonarBinding -ProjectKey $key

    if ($bindingState -eq 'AlreadyBound') {
        $results.Add(
            [pscustomobject]@{
                ProjectName      = $name
                ProjectKey       = $key
                BindingState     = $bindingState
                MatchStatus      = 'SkippedAlreadyBound'
                CandidateCount   = 0
                AzureProjectName = ''
                AzureProjectId   = ''
                RepositoryName   = ''
                RepositoryId     = ''
                PipelineName     = ''
                PipelineId       = ''
                YamlPath         = ''
                Evidence         = ''
                Approved         = 'NO'
                Notes            = 'The project already has a binding.'
            }
        )

        continue
    }

    if ($bindingState -ne 'Unbound') {
        $results.Add(
            [pscustomobject]@{
                ProjectName      = $name
                ProjectKey       = $key
                BindingState     = $bindingState
                MatchStatus      = 'BindingCheckError'
                CandidateCount   = 0
                AzureProjectName = ''
                AzureProjectId   = ''
                RepositoryName   = ''
                RepositoryId     = ''
                PipelineName     = ''
                PipelineId       = ''
                YamlPath         = ''
                Evidence         = ''
                Approved         = 'NO'
                Notes            = 'Could not confirm the current binding state.'
            }
        )

        continue
    }

    $escapedKey = [Regex]::Escape($key)

    $keyMatches = @(
        foreach ($item in $pipelineInventory) {
            $content = [string]$item.YamlContent

            if ([string]::IsNullOrWhiteSpace($content)) {
                continue
            }

            $found = [Regex]::IsMatch(
                $content,
                "(?<![A-Za-z0-9_.-])$escapedKey(?![A-Za-z0-9_.-])",
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($found) {
                $item
            }
        }
    )

    if ($keyMatches.Count -eq 0) {
        $results.Add(
            [pscustomobject]@{
                ProjectName      = $name
                ProjectKey       = $key
                BindingState     = 'Unbound'
                MatchStatus      = 'NoMatch'
                CandidateCount   = 0
                AzureProjectName = ''
                AzureProjectId   = ''
                RepositoryName   = ''
                RepositoryId     = ''
                PipelineName     = ''
                PipelineId       = ''
                YamlPath         = ''
                Evidence         = 'The exact key was not found in readable YAML files.'
                Approved         = 'NO'
                Notes            = 'The key may be in a shared template, a variable, or an excluded pipeline.'
            }
        )

        continue
    }

    # Count distinct project/repository combinations.
    $repositoryGroups = @(
        $keyMatches |
            Group-Object {
                "$($_.AzureProjectId)|$($_.RepositoryId)"
            }
    )

    if ($repositoryGroups.Count -eq 1) {
        $matchStatus = 'UniqueRepositoryMatch'
    }
    else {
        $matchStatus = 'AmbiguousRepositoryMatch'
    }

    foreach ($match in $keyMatches) {
        if ($repositoryGroups.Count -eq 1) {
            $notes = 'Single repository candidate. Manual verification required.'
        }
        else {
            $notes = 'Multiple repositories match. Manual investigation required.'
        }

        $results.Add(
            [pscustomobject]@{
                ProjectName      = $name
                ProjectKey       = $key
                BindingState     = 'Unbound'
                MatchStatus      = $matchStatus
                CandidateCount   = $repositoryGroups.Count
                AzureProjectName = $match.AzureProjectName
                AzureProjectId   = $match.AzureProjectId
                RepositoryName   = $match.RepositoryName
                RepositoryId     = $match.RepositoryId
                PipelineName     = $match.PipelineName
                PipelineId       = $match.PipelineId
                YamlPath         = $match.YamlPath
                Evidence         = "Exact key found in YAML. Read status: $($match.InventoryStatus)"
                Approved         = 'NO'
                Notes            = $notes
            }
        )
    }
}

# ============================================================
# 9. EXPORT AUDIT REPORT
# ============================================================

$results |
    Export-Csv `
        -LiteralPath $OutputCsv `
        -NoTypeInformation `
        -Encoding UTF8

$outputFullPath = [System.IO.Path]::GetFullPath($OutputCsv)

Write-Host ""
Write-Host "=============================================="
Write-Host "DISCOVERY COMPLETED"
Write-Host "=============================================="
Write-Host "Input SonarQube projects: $($sonarRows.Count)"
Write-Host "Azure DevOps projects: $($azProjects.Count)"
Write-Host "YAML pipelines inventoried: $($pipelineInventory.Count)"
Write-Host "Audit report rows: $($results.Count)"
Write-Host "Output CSV: $outputFullPath"
Write-Host ""
Write-Host "Results by status:"

$results |
    Group-Object -Property MatchStatus |
    Sort-Object -Property Name |
    ForEach-Object {
        Write-Host ("  {0}: {1}" -f $_.Name, $_.Count)
    }

Write-Host ""
Write-Host "This script is read-only. No bindings were created or modified."
Write-Host "All candidate rows default to Approved=NO."
