[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [string]$OutputCsv = ".\Sonar_Azure_Binding_Discovery.csv",
    [string]$SonarUrl = "https://aas-sonar-pr.azure-paas.com",
    [string]$AzureOrganization = "AASolutions",
    [string]$AlmSetting = "Azure DevOps",

    [string]$YamlPathPattern = '\.ya?ml$'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# 1. VALIDAR CREDENCIALES
# ============================================================

if ([string]::IsNullOrWhiteSpace($env:SONARQUBE_TOKEN)) {
    throw 'Define SONARQUBE_TOKEN como variable de entorno.'
}

$AzdoToken = if (-not [string]::IsNullOrWhiteSpace($env:AZDO_PAT)) {
    $env:AZDO_PAT
}
elseif (-not [string]::IsNullOrWhiteSpace($env:SYSTEM_ACCESSTOKEN)) {
    $env:SYSTEM_ACCESSTOKEN
}
else {
    $null
}

if ([string]::IsNullOrWhiteSpace($AzdoToken)) {
    throw 'Define AZDO_PAT o SYSTEM_ACCESSTOKEN como variable de entorno.'
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
# 2. FUNCIONES HTTP
# ============================================================

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
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        if ($null -ne $ErrorRecord.Exception.Response) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    }
    catch {}

    return $null
}

# ============================================================
# 3. IMPORTAR Y NORMALIZAR EL CSV
# ============================================================

if (-not (Test-Path -LiteralPath $InputCsv -PathType Leaf)) {
    throw "No existe el CSV de entrada: $InputCsv"
}

$resolvedInput = (Resolve-Path -LiteralPath $InputCsv).Path

Write-Host "CSV de entrada: $resolvedInput"

# Leer la primera línea para detectar delimitador.
$firstLine = Get-Content `
    -LiteralPath $resolvedInput `
    -TotalCount 1 `
    -Encoding UTF8

if ([string]::IsNullOrWhiteSpace($firstLine)) {
    throw 'El CSV está vacío o no contiene encabezados.'
}

$commaCount = ([regex]::Matches($firstLine, ',')).Count
$semicolonCount = ([regex]::Matches($firstLine, ';')).Count
$tabCount = ([regex]::Matches($firstLine, "`t")).Count

if ($semicolonCount -gt $commaCount -and $semicolonCount -ge $tabCount) {
    $delimiter = ';'
}
elseif ($tabCount -gt $commaCount -and $tabCount -gt $semicolonCount) {
    $delimiter = "`t"
}
else {
    $delimiter = ','
}

Write-Host "Delimitador detectado: $(
    switch ($delimiter) {
        ','  { 'coma' }
        ';'  { 'punto y coma' }
        "`t" { 'tabulador' }
    }
)"

# Importar filas.
$sonarRows = @(
    Import-Csv `
        -LiteralPath $resolvedInput `
        -Delimiter $delimiter `
        -Encoding UTF8
)

if ($sonarRows.Count -eq 0) {
    throw 'El CSV no contiene registros.'
}

# Normalizar encabezados: BOM, espacios y nombres.
$normalizedRows = [System.Collections.Generic.List[object]]::new()

foreach ($row in $sonarRows) {
    $normalized = [ordered]@{}

    foreach ($property in $row.PSObject.Properties) {
        $columnName = [string]$property.Name
        $columnName = $columnName.Trim()
        $columnName = $columnName.TrimStart([char]0xFEFF)

        if (-not $normalized.Contains($columnName)) {
            $normalized[$columnName] = $property.Value
        }
    }

    $normalizedRows.Add([pscustomobject]$normalized)
}

$sonarRows = @($normalizedRows)

$columns = @($sonarRows[0].PSObject.Properties.Name)

Write-Host "Columnas detectadas: $($columns -join ', ')"

# Comprobar encabezados obligatorios sin distinguir mayúsculas.
$projectNameColumn = @(
    $columns | Where-Object {
        $_.Trim() -ieq 'ProjectName'
    }
) | Select-Object -First 1

$projectKeyColumn = @(
    $columns | Where-Object {
        $_.Trim() -ieq 'ProjectKey'
    }
) | Select-Object -First 1

if (-not $projectNameColumn -or -not $projectKeyColumn) {
    Write-Host ''
    Write-Host 'Encabezados encontrados:'
    $columns | ForEach-Object { Write-Host "  [$($_)]" }

    throw (
        "El CSV debe incluir las columnas ProjectName y ProjectKey. " +
        "Revisa el delimitador y los encabezados del archivo."
    )
}

# Normalizar nombres a los esperados por el resto del script.
$sonarRows = @(
    foreach ($row in $sonarRows) {
        [pscustomobject]@{
            ProjectName = ([string]$row.$projectNameColumn).Trim()
            ProjectKey  = ([string]$row.$projectKeyColumn).Trim()
        }
    }
)

$sonarRows = @(
    $sonarRows | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.ProjectKey)
    }
)

if ($sonarRows.Count -eq 0) {
    throw 'No se encontraron filas con ProjectKey.'
}

Write-Host "Proyectos SonarQube en el CSV: $($sonarRows.Count)"

# ============================================================
# 4. COMPROBAR BINDINGS EXISTENTES
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
        $status = Get-HttpStatusCode -ErrorRecord $_

        if ($status -eq 404) {
            return 'Unbound'
        }

        return "BindingCheckError: $($_.Exception.Message)"
    }
}

# ============================================================
# 5. INVENTARIO DE PROYECTOS AZURE DEVOPS
# ============================================================

function Get-AzdoProjects {
    $uri = "$AzureBase/_apis/projects?`$top=1000&stateFilter=wellFormed&api-version=7.1"

    $response = Invoke-JsonGet -Url $uri -Headers $AzdoHeaders

    return @($response.value)
}

function Get-AzdoPipelines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectId
    )

    $encodedProjectId = [Uri]::EscapeDataString($ProjectId)

    $uri = "$AzureBase/$encodedProjectId/_apis/pipelines?`$top=1000&api-version=7.1"

    $response = Invoke-JsonGet -Url $uri -Headers $AzdoHeaders

    return @($response.value)
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

    Invoke-JsonGet -Url $uri -Headers $AzdoHeaders
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

    $uri = (
        "$AzureBase/$encodedProjectId/_apis/git/repositories/" +
        "$encodedRepositoryId/items?path=$encodedPath" +
        "&includeContent=true&api-version=7.1"
    )

    $response = Invoke-JsonGet -Url $uri -Headers $AzdoHeaders

    if ($response.PSObject.Properties.Name -contains 'content') {
        return [string]$response.content
    }

    return $null
}

Write-Host ''
Write-Host 'Obteniendo proyectos de Azure DevOps...'

$azProjects = @(Get-AzdoProjects)

if ($azProjects.Count -eq 0) {
    throw 'No se encontraron proyectos de Azure DevOps. Verifica los permisos del PAT.'
}

Write-Host "Proyectos Azure DevOps encontrados: $($azProjects.Count)"

# ============================================================
# 6. LEER PIPELINES YAML Y SUS ARCHIVOS
# ============================================================

$pipelineInventory = [System.Collections.Generic.List[object]]::new()

foreach ($azProject in $azProjects) {
    Write-Host "Proyecto Azure DevOps: $($azProject.name)"

    try {
        $pipelines = @(
            Get-AzdoPipelines -ProjectId ([string]$azProject.id)
        )
    }
    catch {
        Write-Warning (
            "No se pudieron listar pipelines en '$($azProject.name)': " +
            $_.Exception.Message
        )
        continue
    }

    foreach ($pipeline in $pipelines) {
        try {
            $details = Get-PipelineDetails `
                -ProjectId ([string]$azProject.id) `
                -PipelineId ([int]$pipeline.id)
        }
        catch {
            Write-Warning (
                "No se pudieron leer detalles de la pipeline " +
                "'$($pipeline.name)' en '$($azProject.name)': " +
                $_.Exception.Message
            )
            continue
        }

        $configuration = $details.configuration

        # Solo YAML; ignorar pipelines clásicas.
        if ([string]$configuration.type -ne 'yaml') {
            continue
        }

        $yamlPath = [string]$configuration.path
        $repository = $configuration.repository

        if ([string]::IsNullOrWhiteSpace($yamlPath)) {
            continue
        }

        if ($yamlPath -notmatch $YamlPathPattern) {
            continue
        }

        if ($null -eq $repository -or
            [string]::IsNullOrWhiteSpace([string]$repository.id)) {
            Write-Warning (
                "Pipeline '$($pipeline.name)' no expone un repositorio " +
                'identificable. Se excluye de la búsqueda.'
            )
            continue
        }

        $repositoryId = [string]$repository.id
        $repositoryName = [string]$repository.name
        $repositoryType = [string]$repository.type

        try {
            $yamlContent = Get-YamlContent `
                -ProjectId ([string]$azProject.id) `
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

            Write-Warning (
                "No se pudo leer '$yamlPath' del repositorio " +
                "'$repositoryName': $($_.Exception.Message)"
            )
        }

        $pipelineInventory.Add(
            [pscustomobject]@{
                AzureProjectName = [string]$azProject.name
                AzureProjectId   = [string]$azProject.id
                PipelineName     = [string]$pipeline.name
                PipelineId       = [int]$pipeline.id
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

Write-Host ''
Write-Host "Pipelines YAML inventariadas: $($pipelineInventory.Count)"

# ============================================================
# 7. BUSCAR CADA CLAVE SONAR EN LOS YAML
# ============================================================

$results = [System.Collections.Generic.List[object]]::new()

foreach ($sonarProject in $sonarRows) {
    $key = [string]$sonarProject.ProjectKey
    $name = [string]$sonarProject.ProjectName

    Write-Host "Buscando clave SonarQube: $key"

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
                Notes            = 'Ya tiene binding; no se propone modificarlo.'
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
                Notes            = 'No se pudo confirmar que el proyecto esté sin binding.'
            }
        )

        continue
    }

    $escapedKey = [Regex]::Escape($key)

    $keyMatches = @(
        $pipelineInventory | Where-Object {
            $content = [string]$_.YamlContent

            if ([string]::IsNullOrWhiteSpace($content)) {
                return $false
            }

            [Regex]::IsMatch(
                $content,
                "(?<![A-Za-z0-9_.-])$escapedKey(?![A-Za-z0-9_.-])",
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
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
                Evidence         = 'No se encontró la clave exacta en los YAML leídos.'
                Approved         = 'NO'
                Notes            = 'Puede aparecer en templates, variables dinámicas o pipelines excluidas.'
            }
        )

        continue
    }

    # Contar repositorios distintos, no pipelines.
    $repositoryGroups = @(
        $keyMatches |
            Group-Object {
                "$($_.AzureProjectId)|$($_.RepositoryId)"
            }
    )

    $matchStatus = if ($repositoryGroups.Count -eq 1) {
        'UniqueRepositoryMatch'
    }
    else {
        'AmbiguousRepositoryMatch'
    }

    # Registrar cada pipeline coincidente para facilitar la auditoría.
    foreach ($match in $keyMatches) {
        $notes = if ($repositoryGroups.Count -eq 1) {
            'Candidato único; revisar la evidencia antes de aprobar.'
        }
        else {
            'Existen varios repositorios candidatos. Revisión manual obligatoria.'
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
                Evidence         = "Clave exacta encontrada en YAML. Estado de lectura: $($match.InventoryStatus)."
                Approved         = 'NO'
                Notes            = $notes
            }
        )
    }
}

# ============================================================
# 8. EXPORTAR RESULTADOS
# ============================================================

$results | Export-Csv `
    -LiteralPath $OutputCsv `
    -NoTypeInformation `
    -Encoding UTF8

$outputResolved = (Resolve-Path -LiteralPath $OutputCsv).Path

Write-Host ''
Write-Host '============================================'
Write-Host 'DESCUBRIMIENTO COMPLETADO'
Write-Host '============================================'
Write-Host "Proyectos procesados: $($sonarRows.Count)"
Write-Host "Pipelines YAML inventariadas: $($pipelineInventory.Count)"
Write-Host "Filas de auditoría: $($results.Count)"
Write-Host "CSV generado: $outputResolved"
Write-Host ''
Write-Host 'Resumen por estado:'

$results |
    Group-Object -Property MatchStatus |
    Sort-Object -Property Name |
    ForEach-Object {
        Write-Host ("  {0}: {1}" -f $_.Name, $_.Count)
    }

Write-Host ''
Write-Host 'Este script no crea ni modifica bindings.'
Write-Host 'Todos los candidatos quedan Approved=NO por defecto.'
