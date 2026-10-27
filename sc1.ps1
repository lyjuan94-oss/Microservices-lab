[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [string]$OutputCsv = ".\Sonar_Azure_Binding_Discovery.csv",
    [string]$SonarUrl = "https://aas-sonar-pr.azure-paas.com",
    [string]$AzureOrganization = "AASolutions",
    [string]$AlmSetting = "Azure DevOps",

    [string]$YamlPathPattern = '\.ya?ml$',

    [switch]$IncludeUnresolvedPipelines
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $env:SONARQUBE_TOKEN) {
    throw 'Define SONARQUBE_TOKEN como variable de entorno.'
}

$AzdoToken = if ($env:AZDO_PAT) {
    $env:AZDO_PAT
} elseif ($env:SYSTEM_ACCESSTOKEN) {
    $env:SYSTEM_ACCESSTOKEN
} else {
    $null
}

if (-not $AzdoToken) {
    throw 'Define AZDO_PAT o SYSTEM_ACCESSTOKEN como variable de entorno.'
}

$SonarUrl = $SonarUrl.TrimEnd('/')
$AzureBase = "https://dev.azure.com/$AzureOrganization"

$SonarHeaders = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("$($env:SONARQUBE_TOKEN):")
    )
}

$AzdoHeaders = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes(":$AzdoToken")
    )
}

function Invoke-JsonGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    Invoke-RestMethod -Method Get -Uri $Url -Headers $Headers -TimeoutSec 90
}

function Test-SonarBinding {
    param([string]$ProjectKey)

    $key = [Uri]::EscapeDataString($ProjectKey)

    try {
        $null = Invoke-JsonGet `
            -Url "$SonarUrl/api/alm_settings/get_binding?project=$key" `
            -Headers $SonarHeaders

        return 'AlreadyBound'
    }
    catch {
        $status = $null

        try {
            $status = [int]$_.Exception.Response.StatusCode
        }
        catch {}

        if ($status -eq 404) {
            return 'Unbound'
        }

        return "BindingCheckError:$($_.Exception.Message)"
    }
}

function Get-AzdoProjects {
    $uri = "$AzureBase/_apis/projects?`$top=1000&stateFilter=wellFormed&api-version=7.1"
    $response = Invoke-JsonGet -Url $uri -Headers $AzdoHeaders
    return @($response.value)
}

function Get-AzdoPipelines {
    param([string]$ProjectId)

    $uri = "$AzureBase/$ProjectId/_apis/pipelines?`$top=1000&api-version=7.1"
    $response = Invoke-JsonGet -Url $uri -Headers $AzdoHeaders
    return @($response.value)
}

function Get-PipelineDetails {
    param(
        [string]$ProjectId,
        [int]$PipelineId
    )

    $uri = "$AzureBase/$ProjectId/_apis/pipelines/$PipelineId`?api-version=7.1"
    Invoke-JsonGet -Url $uri -Headers $AzdoHeaders
}

function Get-YamlContent {
    param(
        [string]$ProjectId,
        [string]$RepositoryId,
        [string]$Path
    )

    $encodedPath = [Uri]::EscapeDataString($Path)

    $uri = "$AzureBase/$ProjectId/_apis/git/repositories/$RepositoryId/items?path=$encodedPath&includeContent=true&api-version=7.1"

    $response = Invoke-JsonGet -Url $uri -Headers $AzdoHeaders

    if ($response.PSObject.Properties.Name -contains 'content') {
        return [string]$response.content
    }

    return $null
}

if (-not (Test-Path -LiteralPath $InputCsv)) {
    throw "No existe el CSV de entrada: $InputCsv"
}

$sonarRows = @(Import-Csv -LiteralPath $InputCsv)

if ($sonarRows.Count -eq 0) {
    throw 'El CSV de entrada no contiene filas.'
}

if (-not ($sonarRows[0].PSObject.Properties.Name -contains 'ProjectKey')) {
    throw 'El CSV debe incluir una columna ProjectKey.'
}

if (-not ($sonarRows[0].PSObject.Properties.Name -contains 'ProjectName')) {
    throw 'El CSV debe incluir una columna ProjectName.'
}

Write-Host 'Obteniendo proyectos de Azure DevOps...'

$azProjects = @(Get-AzdoProjects)

if ($azProjects.Count -eq 0) {
    throw 'No se encontraron proyectos de Azure DevOps. Comprueba el PAT y sus permisos.'
}

$pipelineInventory = [System.Collections.Generic.List[object]]::new()

foreach ($ap in $azProjects) {
    Write-Host "Inspeccionando proyecto Azure DevOps: $($ap.name)"

    try {
        $pipes = @(Get-AzdoPipelines -ProjectId $ap.id)
    }
    catch {
        Write-Warning "No se pudieron listar pipelines en '$($ap.name)': $($_.Exception.Message)"
        continue
    }

    foreach ($p in $pipes) {
        $type = [string]$p.configuration.type

        # Excluir pipelines clásicas y tipos desconocidos.
        if ($type -ne 'yaml') {
            continue
        }

        try {
            $detail = Get-PipelineDetails `
                -ProjectId $ap.id `
                -PipelineId ([int]$p.id)
        }
        catch {
            Write-Warning "No se pudieron leer detalles de pipeline '$($p.name)' ($($ap.name)): $($_.Exception.Message)"
            continue
        }

        $cfg = $detail.configuration
        $path = [string]$cfg.path
        $repo = $cfg.repository

        $repoId = if ($repo) { [string]$repo.id } else { '' }
        $repoName = if ($repo) { [string]$repo.name } else { '' }
        $repoType = if ($repo) { [string]$repo.type } else { '' }

        if (-not $path -or $path -notmatch $YamlPathPattern) {
            continue
        }

        if (-not $repoId) {
            if (-not $IncludeUnresolvedPipelines) {
                continue
            }

            $pipelineInventory.Add([pscustomobject]@{
                AzureProjectName = $ap.name
                AzureProjectId   = $ap.id
                PipelineName     = $p.name
                PipelineId       = $p.id
                RepositoryName   = $repoName
                RepositoryId     = $repoId
                RepositoryType   = $repoType
                YamlPath         = $path
                YamlContent      = $null
                InventoryStatus  = 'RepositoryMetadataMissing'
            })

            continue
        }

        try {
            $content = Get-YamlContent `
                -ProjectId $ap.id `
                -RepositoryId $repoId `
                -Path $path

            $inventoryStatus = if ($null -ne $content) {
                'ReadOK'
            } else {
                'YamlContentMissing'
            }
        }
        catch {
            $content = $null
            $inventoryStatus = "YamlReadError: $($_.Exception.Message)"
        }

        $pipelineInventory.Add([pscustomobject]@{
            AzureProjectName = $ap.name
            AzureProjectId   = $ap.id
            PipelineName     = $p.name
            PipelineId       = $p.id
            RepositoryName   = $repoName
            RepositoryId     = $repoId
            RepositoryType   = $repoType
            YamlPath         = $path
            YamlContent      = $content
            InventoryStatus  = $inventoryStatus
        })
    }
}

Write-Host "Pipelines YAML inventariadas: $($pipelineInventory.Count)"

$results = [System.Collections.Generic.List[object]]::new()

foreach ($s in $sonarRows) {
    $key = ([string]$s.ProjectKey).Trim()
    $name = ([string]$s.ProjectName).Trim()

    if (-not $key) {
        continue
    }

    $bindingState = Test-SonarBinding -ProjectKey $key

    if ($bindingState -eq 'AlreadyBound') {
        $results.Add([pscustomobject]@{
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
            Notes            = 'El proyecto ya tiene binding; no se propone modificarlo.'
        })

        continue
    }

    if ($bindingState -ne 'Unbound') {
        $results.Add([pscustomobject]@{
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
            Notes            = 'No se pudo confirmar que el proyecto esté sin binding.'
        })

        continue
    }

    $escapedKey = [Regex]::Escape($key)

    $matches = @(
        $pipelineInventory | Where-Object {
            $_.YamlContent -and
            [Regex]::IsMatch(
                [string]$_.YamlContent,
                "(?<![A-Za-z0-9_.-])$escapedKey(?![A-Za-z0-9_.-])",
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }
    )

    if ($matches.Count -eq 0) {
        $results.Add([pscustomobject]@{
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
            Evidence         = 'No se encontró la clave exacta en YAML leído.'
            Approved         = 'NO'
            Notes            = 'Puede estar en un template compartido, una variable, una pipeline no accesible o una configuración clásica excluida.'
        })

        continue
    }

    # Se considera candidato distinto cada combinación de proyecto y repositorio.
    $repoGroups = @(
        $matches | Group-Object {
            "$($_.AzureProjectId)|$($_.RepositoryId)"
        }
    )

    $status = if ($repoGroups.Count -eq 1) {
        'UniqueRepositoryMatch'
    } else {
        'AmbiguousRepositoryMatch'
    }

    foreach ($m in $matches) {
        $notes = if ($repoGroups.Count -eq 1) {
            'Revisar y cambiar Approved a YES si se confirma la correspondencia.'
        } else {
            'Más de un repositorio candidato: revisión manual obligatoria.'
        }

        $results.Add([pscustomobject]@{
            ProjectName      = $name
            ProjectKey       = $key
            BindingState     = 'Unbound'
            MatchStatus      = $status
            CandidateCount   = $repoGroups.Count
            AzureProjectName = $m.AzureProjectName
            AzureProjectId   = $m.AzureProjectId
            RepositoryName   = $m.RepositoryName
            RepositoryId     = $m.RepositoryId
            PipelineName     = $m.PipelineName
            PipelineId       = $m.PipelineId
            YamlPath         = $m.YamlPath
            Evidence         = "Clave exacta encontrada en YAML ($($m.InventoryStatus))."
            Approved         = 'NO'
            Notes            = $notes
        })
    }
}

$results | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host "Auditoría guardada en: $((Resolve-Path -LiteralPath $OutputCsv).Path)"
Write-Host 'El script es de solo lectura: no ha creado ni modificado bindings.'
