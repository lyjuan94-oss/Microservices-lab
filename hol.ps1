
[CmdletBinding()]
param(
    [string]$Organization = "AASolutions",
    [string]$SonarQubeUrl = "https://aas-sonar-pr.azure-paas.com",
    [string]$TokenOverride = "",
    [string]$PatOverride = "",
    [string]$AlmSetting = "",

    # Apply changes only when explicitly requested.
    [switch]$ApplyChanges,

    [int]$PageSize = 500,

    [string]$ReportDirectory = ".\BindingReports"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# 1. Authentication
# ------------------------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($TokenOverride)) {
    $env:SONARQUBE_TOKEN = $TokenOverride.Trim()
}

if (-not [string]::IsNullOrWhiteSpace($PatOverride)) {
    $azdoToken = $PatOverride.Trim()
}
elseif (-not [string]::IsNullOrWhiteSpace($env:AZDO_PAT)) {
    $azdoToken = $env:AZDO_PAT.Trim()
}
elseif (-not [string]::IsNullOrWhiteSpace($env:SYSTEM_ACCESSTOKEN)) {
    $azdoToken = $env:SYSTEM_ACCESSTOKEN.Trim()
}
else {
    $azdoToken = ""
}

if ([string]::IsNullOrWhiteSpace($env:SONARQUBE_TOKEN)) {
    throw "Missing SonarQube token. Set SONARQUBE_TOKEN or use -TokenOverride."
}

if ([string]::IsNullOrWhiteSpace($azdoToken)) {
    throw "Missing Azure DevOps token. Set AZDO_PAT, enable SYSTEM_ACCESSTOKEN in the pipeline, or use -PatOverride."
}

if ([string]::IsNullOrWhiteSpace($Organization)) {
    throw "Organization is required."
}

if ([string]::IsNullOrWhiteSpace($AlmSetting)) {
    throw "AlmSetting is required. Supply the Azure DevOps ALM configuration key from SonarQube."
}

if ($PageSize -lt 1 -or $PageSize -gt 500) {
    throw "PageSize must be between 1 and 500."
}

$SonarQubeUrl = $SonarQubeUrl.Trim().TrimEnd("/")
$Organization = $Organization.Trim()

$sonarToken = $env:SONARQUBE_TOKEN.Trim()

$sonarBasic = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${sonarToken}:")
)

$azdoBasic = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":${azdoToken}")
)

$sonarHeaders = @{
    Authorization = "Basic $sonarBasic"
    Accept        = "application/json"
}

$azdoHeaders = @{
    Authorization = "Basic $azdoBasic"
    Accept        = "application/json"
}

# ------------------------------------------------------------
# 2. Helper functions
# ------------------------------------------------------------

function Invoke-SonarGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    Invoke-RestMethod `
        -Uri $Uri `
        -Method Get `
        -Headers $sonarHeaders `
        -TimeoutSec 60
}

function Invoke-AzDoGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    Invoke-RestMethod `
        -Uri $Uri `
        -Method Get `
        -Headers $azdoHeaders `
        -TimeoutSec 60
}

function Get-HttpStatusCode {
    param($ErrorRecord)

    try {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    }
    catch {
        return 0
    }
}

function Get-SonarProjects {
    $projects = @()
    $page = 1
    $total = [int]::MaxValue

    while ($projects.Count -lt $total) {
        $uri = "$SonarQubeUrl/api/projects/search?ps=$PageSize&p=$page"
        $response = Invoke-SonarGet -Uri $uri

        $projects += @($response.components)
        $total = [int]$response.paging.total

        Write-Host (
            "SonarQube projects loaded: {0}/{1}" -f
            $projects.Count, $total
        ) -ForegroundColor Gray

        if ($response.components.Count -eq 0) {
            break
        }

        $page++
    }

    return $projects
}

function Get-AzDoProjects {
    $projects = @()
    $continuationToken = $null

    do {
        $uri = "https://dev.azure.com/$Organization/_apis/projects?`$top=1000&api-version=7.1"

        if (-not [string]::IsNullOrWhiteSpace($continuationToken)) {
            $encodedToken = [Uri]::EscapeDataString($continuationToken)
            $uri += "&continuationToken=$encodedToken"
        }

        $response = Invoke-AzDoGet -Uri $uri

        $projects += @($response.value)

        $continuationToken = $null

        # Azure DevOps may return a continuation token in response headers.
        # Invoke-RestMethod returns the body, so the normal project listing
        # is used here. Organizations with more than 1,000 projects should
        # add explicit response-header pagination using Invoke-WebRequest.
        break

    } while (-not [string]::IsNullOrWhiteSpace($continuationToken))

    return $projects
}

function Get-AzDoRepositories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectId
    )

    $encodedProjectId = [Uri]::EscapeDataString($ProjectId)

    $uri = "https://dev.azure.com/$Organization/$encodedProjectId/_apis/git/repositories?api-version=7.1"

    $response = Invoke-AzDoGet -Uri $uri

    return @($response.value)
}

function Get-SonarBinding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectKey
    )

    $encodedKey = [Uri]::EscapeDataString($ProjectKey)
    $uri = "$SonarQubeUrl/api/alm_settings/get_binding?project=$encodedKey"

    try {
        $response = Invoke-SonarGet -Uri $uri

        if ($null -ne $response.alm -or
            $null -ne $response.almSetting) {
            return [PSCustomObject]@{
                Exists  = $true
                Binding = $response
            }
        }

        return [PSCustomObject]@{
            Exists  = $false
            Binding = $null
        }
    }
    catch {
        $statusCode = Get-HttpStatusCode -ErrorRecord $_

        if ($statusCode -eq 404) {
            return [PSCustomObject]@{
                Exists  = $false
                Binding = $null
            }
        }

        throw "Could not check binding for '$ProjectKey'. $($_.Exception.Message)"
    }
}

function Set-SonarBinding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectKey,

        [Parameter(Mandatory = $true)]
        [string]$AzureProjectName,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryName
    )

    $uri = "$SonarQubeUrl/api/alm_settings/set_azure_binding"

    $body = @{
        project        = $ProjectKey
        almSetting     = $AlmSetting
        projectName    = $AzureProjectName
        repositoryName = $RepositoryName
    }

    Invoke-RestMethod `
        -Uri $uri `
        -Method Post `
        -Headers $sonarHeaders `
        -Body $body `
        -TimeoutSec 60
}

# ------------------------------------------------------------
# 3. Validate connectivity before processing
# ------------------------------------------------------------

Write-Host ""
Write-Host "SonarQube / Azure DevOps binding automation" -ForegroundColor Cyan
Write-Host "Organization: $Organization"
Write-Host "SonarQube:    $SonarQubeUrl"
Write-Host "ALM setting:  $AlmSetting"

if ($ApplyChanges) {
    Write-Host "Mode: APPLY CHANGES" -ForegroundColor Yellow
}
else {
    Write-Host "Mode: PLANNING ONLY (no changes will be made)" -ForegroundColor Green
}

# Fail early if either API is inaccessible.
$null = Invoke-SonarGet -Uri "$SonarQubeUrl/api/server/version"
$null = Invoke-AzDoGet -Uri "https://dev.azure.com/$Organization/_apis/projects?`$top=1&api-version=7.1"

# ------------------------------------------------------------
# 4. Load projects and repositories
# ------------------------------------------------------------

$sonarProjects = @(Get-SonarProjects)
$azdoProjects = @(Get-AzDoProjects)

$azdoProjectLookup = @{}
$repositoryLookup = @{}

foreach ($project in $azdoProjects) {
    $azdoProjectLookup[$project.name.ToLowerInvariant()] = $project
}

Write-Host ""
Write-Host "Loading Azure DevOps repositories..." -ForegroundColor Cyan

foreach ($project in $azdoProjects) {
    try {
        $repositories = @(
            Get-AzDoRepositories -ProjectId $project.id
        )

        $repoNames = @{}

        foreach ($repo in $repositories) {
            $repoNames[$repo.name.ToLowerInvariant()] = $repo
        }

        $repositoryLookup[$project.id] = $repoNames
    }
    catch {
        throw "Unable to load repositories for Azure DevOps project '$($project.name)'. $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 5. Plan and execute
# ------------------------------------------------------------

$results = [System.Collections.Generic.List[object]]::new()

$counts = @{
    AlreadyBound        = 0
    Planned             = 0
    Applied             = 0
    InvalidConvention   = 0
    AzureProjectMissing = 0
    RepositoryMissing   = 0
    Failed              = 0
}

foreach ($sonarProject in $sonarProjects) {
    $projectKey  = [string]$sonarProject.key
    $projectName = [string]$sonarProject.name

    Write-Host ""
    Write-Host "Project: $projectName [$projectKey]" -ForegroundColor Cyan

    $result = [ordered]@{
        SonarProjectName = $projectName
        SonarProjectKey  = $projectKey
        AzureProject     = ""
        Repository       = ""
        Status           = ""
        Details          = ""
    }

    try {
        # Existing bindings must remain untouched, regardless of convention.
        $binding = Get-SonarBinding -ProjectKey $projectKey

        if ($binding.Exists) {
            $result.Status = "AlreadyBound"
            $result.Details = "Existing binding preserved; no changes made."

            $counts.AlreadyBound++

            Write-Host "SKIP: Existing binding preserved." -ForegroundColor DarkGray
            $results.Add([PSCustomObject]$result)
            continue
        }

        # Naming convention: AzureProject-Repository
        # Split on the FIRST hyphen.
        $separator = $projectName.IndexOf("-")

        if ($separator -le 0 -or
            $separator -ge ($projectName.Length - 1)) {

            $result.Status = "InvalidConvention"
            $result.Details = "Expected naming convention: AzureProject-Repository."

            $counts.InvalidConvention++

            Write-Host "SKIP: Naming convention not satisfied." -ForegroundColor Yellow
            $results.Add([PSCustomObject]$result)
            continue
        }

        $azureProjectName = $projectName.Substring(0, $separator).Trim()
        $repositoryName = $projectName.Substring($separator + 1).Trim()

        $result.AzureProject = $azureProjectName
        $result.Repository = $repositoryName

        if ([string]::IsNullOrWhiteSpace($azureProjectName) -or
            [string]::IsNullOrWhiteSpace($repositoryName)) {

            $result.Status = "InvalidConvention"
            $result.Details = "Project or repository name is empty."

            $counts.InvalidConvention++

            Write-Host "SKIP: Empty project/repository component." -ForegroundColor Yellow
            $results.Add([PSCustomObject]$result)
            continue
        }

        # Resolve the Azure DevOps project.
        $projectLookupKey = $azureProjectName.ToLowerInvariant()

        if (-not $azdoProjectLookup.ContainsKey($projectLookupKey)) {
            $result.Status = "AzureProjectMissing"
            $result.Details = "Azure DevOps project '$azureProjectName' not found."

            $counts.AzureProjectMissing++

            Write-Host "SKIP: Azure DevOps project not found." -ForegroundColor Yellow
            $results.Add([PSCustomObject]$result)
            continue
        }

        $azdoProject = $azdoProjectLookup[$projectLookupKey]
        $reposForProject = $repositoryLookup[$azdoProject.id]
        $repoLookupKey = $repositoryName.ToLowerInvariant()

        if (-not $reposForProject.ContainsKey($repoLookupKey)) {
            $result.Status = "RepositoryMissing"
            $result.Details = "Repository '$repositoryName' not found in '$azureProjectName'."

            $counts.RepositoryMissing++

            Write-Host "SKIP: Repository not found." -ForegroundColor Yellow
            $results.Add([PSCustomObject]$result)
            continue
        }

        if (-not $ApplyChanges) {
            $result.Status = "Planned"
            $result.Details = "Would bind to Azure DevOps project '$azureProjectName', repository '$repositoryName'."

            $counts.Planned++

            Write-Host (
                "PLAN: {0} -> {1}/{2}" -f
                $projectKey, $azureProjectName, $repositoryName
            ) -ForegroundColor Green

            $results.Add([PSCustomObject]$result)
            continue
        }

        # Recheck immediately before mutation to reduce race conditions.
        $binding = Get-SonarBinding -ProjectKey $projectKey

        if ($binding.Exists) {
            $result.Status = "AlreadyBound"
            $result.Details = "Binding appeared during execution; preserved."

            $counts.AlreadyBound++

            Write-Host "SKIP: Binding now exists; preserved." -ForegroundColor DarkGray
            $results.Add([PSCustomObject]$result)
            continue
        }

        $null = Set-SonarBinding `
            -ProjectKey $projectKey `
            -AzureProjectName $azureProjectName `
            -RepositoryName $repositoryName

        $result.Status = "Applied"
        $result.Details = "Binding created successfully."

        $counts.Applied++

        Write-Host "SUCCESS: Binding created." -ForegroundColor Green
    }
    catch {
        $result.Status = "Failed"
        $result.Details = $_.Exception.Message

        $counts.Failed++

        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }

    $results.Add([PSCustomObject]$result)
}

# ------------------------------------------------------------
# 6. Export reports
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ReportDirectory)) {
    New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$allReport = Join-Path $ReportDirectory "binding_report_$timestamp.csv"
$exceptionsReport = Join-Path $ReportDirectory "binding_exceptions_$timestamp.csv"

$results |
    Export-Csv -Path $allReport -NoTypeInformation -Encoding UTF8

$results |
    Where-Object {
        $_.Status -in @(
            "InvalidConvention",
            "AzureProjectMissing",
            "RepositoryMissing",
            "Failed"
        )
    } |
    Export-Csv -Path $exceptionsReport -NoTypeInformation -Encoding UTF8

# ------------------------------------------------------------
# 7. Summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "================ SUMMARY ================" -ForegroundColor Cyan
Write-Host "SonarQube projects:     $($sonarProjects.Count)"
Write-Host "Existing bindings:      $($counts.AlreadyBound)"
Write-Host "Planning candidates:    $($counts.Planned)"
Write-Host "Bindings applied:       $($counts.Applied)"
Write-Host "Invalid convention:     $($counts.InvalidConvention)"
Write-Host "Azure project missing:  $($counts.AzureProjectMissing)"
Write-Host "Repository missing:     $($counts.RepositoryMissing)"
Write-Host "Failures:               $($counts.Failed)"
Write-Host ""
Write-Host "Full report:       $allReport"
Write-Host "Exceptions report: $exceptionsReport"
Write-Host "=========================================" -ForegroundColor Cyan
