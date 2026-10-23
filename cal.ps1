
[CmdletBinding()]
param(
    [switch]$ApplyChanges,
    [string]$SonarTokenOverride,
    [string]$PatOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# 1. CONFIGURATION
# ============================================================

$SonarBaseUrl = "https://aas-sonar-pr.azure-paas.com".TrimEnd("/")
$AzureOrgName = "AASolutions"
$AzureOrgUrl = "https://dev.azure.com/$AzureOrgName"
$AlmSetting = "Azure DevOps"
$PageSize = 500
$Monorepo = "false"

$ReportDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReportDirectory)) {
    $ReportDirectory = (Get-Location).Path
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ReportPath = Join-Path $ReportDirectory "ALM_Binding_Report_$Timestamp.csv"

# ============================================================
# 2. AUTHENTICATION
# ============================================================

# SonarQube: explicit override > environment variable.
$SonarToken = $SonarTokenOverride
if ([string]::IsNullOrWhiteSpace($SonarToken)) {
    $SonarToken = $env:SONARQUBE_TOKEN
}

if ([string]::IsNullOrWhiteSpace($SonarToken)) {
    throw "SonarQube token missing. Set SONARQUBE_TOKEN or pass -SonarTokenOverride."
}

# Azure DevOps: explicit override > AZDO_PAT > SYSTEM_ACCESSTOKEN.
$AzureToken = $PatOverride
if ([string]::IsNullOrWhiteSpace($AzureToken)) {
    $AzureToken = $env:AZDO_PAT
}
if ([string]::IsNullOrWhiteSpace($AzureToken)) {
    $AzureToken = $env:SYSTEM_ACCESSTOKEN
}

if ([string]::IsNullOrWhiteSpace($AzureToken)) {
    throw "Azure DevOps token missing. Set AZDO_PAT, SYSTEM_ACCESSTOKEN, or pass -PatOverride."
}

# SonarQube Basic authentication: token:
$SonarEncodedAuth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${SonarToken}:")
)

$SonarHeaders = @{
    Authorization = "Basic $SonarEncodedAuth"
    Accept        = "application/json"
}

# Azure DevOps Basic authentication: :PAT
$AzureEncodedAuth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":${AzureToken}")
)

$AzureHeaders = @{
    Authorization = "Basic $AzureEncodedAuth"
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

    # Response is not available on every exception type.
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
            # Try another representation.
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

    # Some PowerShell/.NET exceptions expose StatusCode directly.
    try {
        $statusCode = $ErrorRecord.Exception.StatusCode
        if ($null -ne $statusCode) {
            return [int]$statusCode
        }
    }
    catch {
        # Continue.
    }

    # Try the inner exception.
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

function Add-ReportRow {
    param(
        [Parameter(Mandatory)][string]$SonarName,
        [Parameter(Mandatory)][string]$SonarKey,
        [string]$AzureProject = "",
        [string]$AzureRepository = "",
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Reason
    )

    $script:Report.Add([PSCustomObject]@{
        SonarProjectName = $SonarName
        SonarProjectKey  = $SonarKey
        AzureProject     = $AzureProject
        AzureRepository  = $AzureRepository
        Status           = $Status
        Reason           = $Reason
    }) | Out-Null
}

# Corrected: delimit the variable before the query string.
function Get-AzureProject {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectName
    )

    $encodedName = [uri]::EscapeDataString($ProjectName)

    $uri = "${script:AzureOrgUrl}/_apis/projects/${encodedName}?api-version=7.1"

    return Invoke-RestMethod `
        -Uri $uri `
        -Method GET `
        -Headers $script:AzureHeaders `
        -ErrorAction Stop
}

function Get-AzureRepositories {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectId
    )

    $uri = "${script:AzureOrgUrl}/${ProjectId}/_apis/git/repositories?api-version=7.1"

    return Invoke-RestMethod `
        -Uri $uri `
        -Method GET `
        -Headers $script:AzureHeaders `
        -ErrorAction Stop
}

function Get-SonarBinding {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectKey
    )

    $encodedKey = [uri]::EscapeDataString($ProjectKey)
    $uri = "${script:SonarBaseUrl}/api/alm_settings/get_binding?project=${encodedKey}"

    return Invoke-RestMethod `
        -Uri $uri `
        -Method GET `
        -Headers $script:SonarHeaders `
        -ErrorAction Stop
}

# ============================================================
# 4. INITIALIZE REPORT AND MODE
# ============================================================

$Report = [System.Collections.Generic.List[object]]::new()

if ($ApplyChanges) {
    Write-Host "`nMODE: APPLY CHANGES" -ForegroundColor Red
    Write-Host "Valid bindings will be created in SonarQube."
}
else {
    Write-Host "`nMODE: DRY RUN / PLANNING" -ForegroundColor Cyan
    Write-Host "No bindings will be created."
    Write-Host "Use -ApplyChanges only after reviewing the CSV."
}

Write-Host "SonarQube: $SonarBaseUrl"
Write-Host "Azure DevOps organization: $AzureOrgName"
Write-Host "ALM setting: $AlmSetting"
Write-Host "Report: $ReportPath"

# ============================================================
# 5. VERIFY CONNECTIVITY
# ============================================================

Write-Host "`nChecking SonarQube connectivity..." -ForegroundColor Cyan

try {
    $sonarVersion = Invoke-RestMethod `
        -Uri "${SonarBaseUrl}/api/server/version" `
        -Method GET `
        -Headers $SonarHeaders `
        -ErrorAction Stop

    Write-Host "SonarQube version: $sonarVersion" -ForegroundColor Green
}
catch {
    throw "Cannot connect to SonarQube: $(Get-ErrorDescription -ErrorRecord $_)"
}

Write-Host "`nChecking Azure DevOps connectivity..." -ForegroundColor Cyan

try {
    $null = Invoke-RestMethod `
        -Uri "${AzureOrgUrl}/_apis/projects?%24top=1&api-version=7.1" `
        -Method GET `
        -Headers $AzureHeaders `
        -ErrorAction Stop

    Write-Host "Azure DevOps API is accessible." -ForegroundColor Green
}
catch {
    throw "Cannot access Azure DevOps projects API: $(Get-ErrorDescription -ErrorRecord $_)"
}

# ============================================================
# 6. RETRIEVE ALL SONARQUBE PROJECTS
# ============================================================

Write-Host "`nRetrieving SonarQube projects..." -ForegroundColor Cyan

$SonarProjects = [System.Collections.Generic.List[object]]::new()
$page = 1
$total = 0

do {
    $uri = "${SonarBaseUrl}/api/projects/search?qualifiers=TRK&ps=${PageSize}&p=${page}"

    try {
        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method GET `
            -Headers $SonarHeaders `
            -ErrorAction Stop
    }
    catch {
        throw "Failed to retrieve SonarQube projects (page $page): $(Get-ErrorDescription -ErrorRecord $_)"
    }

    foreach ($component in $response.components) {
        $SonarProjects.Add($component) | Out-Null
    }

    $total = [int]$response.paging.total

    Write-Host "Retrieved $($SonarProjects.Count) of $total projects..."

    $page++
}
while ($SonarProjects.Count -lt $total)

Write-Host "`nTotal projects retrieved: $($SonarProjects.Count)" -ForegroundColor Green

# ============================================================
# 7. PROCESS PROJECTS
# ============================================================

$counter = 0
$created = 0
$verified = 0
$existing = 0
$invalid = 0
$missingAzureProject = 0
$missingRepository = 0
$errors = 0
$ready = 0

foreach ($sonarProject in $SonarProjects) {
    $counter++

    $sonarName = [string]$sonarProject.name
    $sonarKey = [string]$sonarProject.key

    Write-Host "`n[$counter/$($SonarProjects.Count)] $sonarName" -ForegroundColor Cyan

    # 7.1 Check binding first; preserve existing bindings.
    try {
        $null = Get-SonarBinding -ProjectKey $sonarKey

        $existing++
        Write-Host "SKIPPED: Binding already exists." -ForegroundColor Yellow

        Add-ReportRow `
            -SonarName $sonarName `
            -SonarKey $sonarKey `
            -Status "SKIPPED_EXISTING_BINDING" `
            -Reason "Project already has an ALM binding; existing binding was preserved."

        continue
    }
    catch {
        $bindingStatus = Get-HttpStatusCode -ErrorRecord $_

        if ($bindingStatus -ne 404) {
            $errors++
            $reason = Get-ErrorDescription -ErrorRecord $_

            Write-Host "ERROR: Could not determine binding status: $reason" -ForegroundColor Red

            Add-ReportRow `
                -SonarName $sonarName `
                -SonarKey $sonarKey `
                -Status "ERROR_BINDING_CHECK" `
                -Reason $reason

            continue
        }
    }

    # 7.2 Parse the SonarQube DISPLAY NAME at its last hyphen.
    $lastHyphen = $sonarName.LastIndexOf("-")

    if ($lastHyphen -le 0 -or $lastHyphen -ge ($sonarName.Length - 1)) {
        $invalid++
        $reason = "Invalid naming convention: expected '<AzureProject>-<Repository>' with non-empty parts."

        Write-Host "SKIPPED: $reason" -ForegroundColor Yellow

        Add-ReportRow `
            -SonarName $sonarName `
            -SonarKey $sonarKey `
            -Status "INVALID_NAMING_CONVENTION" `
            -Reason $reason

        continue
    }

    $azureProjectName = $sonarName.Substring(0, $lastHyphen).Trim()
    $repositoryName = $sonarName.Substring($lastHyphen + 1).Trim()

    if ([string]::IsNullOrWhiteSpace($azureProjectName) -or
        [string]::IsNullOrWhiteSpace($repositoryName)) {

        $invalid++
        $reason = "Invalid naming convention: Azure project or repository name is empty."

        Write-Host "SKIPPED: $reason" -ForegroundColor Yellow

        Add-ReportRow `
            -SonarName $sonarName `
            -SonarKey $sonarKey `
            -Status "INVALID_NAMING_CONVENTION" `
            -Reason $reason

        continue
    }

    Write-Host "Azure project candidate: $azureProjectName"
    Write-Host "Repository candidate:    $repositoryName"

    # 7.3 Verify Azure DevOps project exists.
    try {
        $azureProject = Get-AzureProject -ProjectName $azureProjectName
    }
    catch {
        $statusCode = Get-HttpStatusCode -ErrorRecord $_
        $reason = Get-ErrorDescription -ErrorRecord $_

        if ($statusCode -eq 404) {
            $missingAzureProject++

            Write-Host "SKIPPED: Azure DevOps project not found." -ForegroundColor Yellow

            Add-ReportRow `
                -SonarName $sonarName `
                -SonarKey $sonarKey `
                -AzureProject $azureProjectName `
                -AzureRepository $repositoryName `
                -Status "AZDO_PROJECT_NOT_FOUND" `
                -Reason "Azure DevOps project '$azureProjectName' was not found. $reason"
        }
        else {
            $errors++

            Write-Host "ERROR checking Azure project: $reason" -ForegroundColor Red

            Add-ReportRow `
                -SonarName $sonarName `
                -SonarKey $sonarKey `
                -AzureProject $azureProjectName `
                -AzureRepository $repositoryName `
                -Status "ERROR_AZDO_PROJECT_LOOKUP" `
                -Reason $reason
        }

        continue
    }

    $azureProjectName = [string]$azureProject.name
    $azureProjectId = [string]$azureProject.id

    # 7.4 Verify repository exists inside that project.
    try {
        $repositoriesResponse = Get-AzureRepositories -ProjectId $azureProjectId
        $repositories = @($repositoriesResponse.value)

        $repository = $repositories |
            Where-Object { $_.name -ieq $repositoryName } |
            Select-Object -First 1

        if ($null -eq $repository) {
            $missingRepository++
            $reason = "Repository '$repositoryName' was not found in Azure DevOps project '$azureProjectName'."

            Write-Host "SKIPPED: $reason" -ForegroundColor Yellow

            Add-ReportRow `
                -SonarName $sonarName `
                -SonarKey $sonarKey `
                -AzureProject $azureProjectName `
                -AzureRepository $repositoryName `
                -Status "AZDO_REPOSITORY_NOT_FOUND" `
                -Reason $reason

            continue
        }

        $repositoryName = [string]$repository.name
    }
    catch {
        $errors++
        $reason = Get-ErrorDescription -ErrorRecord $_

        Write-Host "ERROR checking Azure repositories: $reason" -ForegroundColor Red

        Add-ReportRow `
            -SonarName $sonarName `
            -SonarKey $sonarKey `
            -AzureProject $azureProjectName `
            -AzureRepository $repositoryName `
            -Status "ERROR_AZDO_REPOSITORY_LOOKUP" `
            -Reason $reason

        continue
    }

    # 7.5 Dry-run: validated candidate, no changes.
    if (-not $ApplyChanges) {
        $ready++

        Write-Host "READY: Project and repository exist. No changes made." -ForegroundColor Green

        Add-ReportRow `
            -SonarName $sonarName `
            -SonarKey $sonarKey `
            -AzureProject $azureProjectName `
            -AzureRepository $repositoryName `
            -Status "READY_DRY_RUN" `
            -Reason "Naming convention valid; Azure DevOps project and repository verified. No binding created."

        continue
    }

    # 7.6 Create binding only for validated, unbound projects.
    $body = @{
        almSetting     = $AlmSetting
        project        = $sonarKey
        projectName    = $azureProjectName
        repositoryName = $repositoryName
        monorepo       = $Monorepo
    }

    try {
        Write-Host "Creating binding..." -ForegroundColor Cyan

        $null = Invoke-RestMethod `
            -Uri "${SonarBaseUrl}/api/alm_settings/set_azure_binding" `
            -Method POST `
            -Headers $SonarHeaders `
            -Body $body `
            -ErrorAction Stop

        $created++

        # 7.7 Verify binding after creation.
        try {
            $null = Get-SonarBinding -ProjectKey $sonarKey
            $verified++

            Write-Host "SUCCESS: Binding created and verified." -ForegroundColor Green

            Add-ReportRow `
                -SonarName $sonarName `
                -SonarKey $sonarKey `
                -AzureProject $azureProjectName `
                -AzureRepository $repositoryName `
                -Status "BINDING_CREATED_VERIFIED" `
                -Reason "POST succeeded and GET verified the binding."
        }
        catch {
            $errors++
            $reason = Get-ErrorDescription -ErrorRecord $_

            Write-Host "WARNING: POST succeeded but verification failed: $reason" -ForegroundColor Yellow

            Add-ReportRow `
                -SonarName $sonarName `
                -SonarKey $sonarKey `
                -AzureProject $azureProjectName `
                -AzureRepository $repositoryName `
                -Status "BINDING_VERIFICATION_FAILED" `
                -Reason "POST succeeded but GET verification failed. Check manually. $reason"
        }
    }
    catch {
        $errors++
        $reason = Get-ErrorDescription -ErrorRecord $_

        Write-Host "ERROR creating binding: $reason" -ForegroundColor Red

        Add-ReportRow `
            -SonarName $sonarName `
            -SonarKey $sonarKey `
            -AzureProject $azureProjectName `
            -AzureRepository $repositoryName `
            -Status "BINDING_POST_FAILED" `
            -Reason $reason
    }
}

# ============================================================
# 8. EXPORT CSV REPORT
# ============================================================

$Report |
    Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8

# ============================================================
# 9. SUMMARY
# ============================================================

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "BINDING PROCESS SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Write-Host "Mode:                     $(if ($ApplyChanges) { 'APPLY CHANGES' } else { 'DRY RUN' })"
Write-Host "SonarQube projects:       $($SonarProjects.Count)"
Write-Host "Already bound / skipped:  $existing"
Write-Host "Invalid naming:           $invalid"
Write-Host "Azure project missing:    $missingAzureProject"
Write-Host "Azure repository missing: $missingRepository"

if ($ApplyChanges) {
    Write-Host "POST succeeded:           $created"
    Write-Host "Bindings verified:        $verified"
}

Write-Host "Ready in dry-run:         $ready"
Write-Host "Errors / warnings:        $errors"
Write-Host "Report saved to:          $ReportPath"

Write-Host "`nStatus counts:" -ForegroundColor Cyan

$Report |
    Group-Object -Property Status |
    Sort-Object -Property Name |
    ForEach-Object {
        Write-Host ("{0,-34} {1,6}" -f $_.Name, $_.Count)
    }

Write-Host "`nProcess completed." -ForegroundColor Green
