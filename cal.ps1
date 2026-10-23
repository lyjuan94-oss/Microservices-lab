$projectKey = "aa-belgium-internal-Adhesions"
$almSetting = "Azure DevOps"
$azureProject = "aa-belgium-internal"
$repositoryName = "Adhesions"

# Comprobar si ya existe un binding
$bindingUri = "$baseUrl/api/alm_settings/get_binding?project=$([uri]::EscapeDataString($projectKey))"

try {
    $binding = Invoke-RestMethod `
        -Uri $bindingUri `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop

    Write-Host "El proyecto ya tiene un binding:" -ForegroundColor Yellow
    $binding | ConvertTo-Json -Depth 5
    Write-Host "No se ha realizado ningún cambio."
}
catch {
    $statusCode = 0

    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }

    if ($statusCode -ne 404) {
        throw "No se pudo comprobar el binding. HTTP $statusCode. No se realizará el POST."
    }

    # Solo se llega aquí si el GET devuelve HTTP 404
    $body = @{
        almSetting     = $almSetting
        project        = $projectKey
        projectName    = $azureProject
        repositoryName = $repositoryName
        monorepo       = "false"
    }

    $postUri = "$baseUrl/api/alm_settings/set_azure_binding"

    Invoke-RestMethod `
        -Uri $postUri `
        -Method POST `
        -Headers $headers `
        -Body $body `
        -ErrorAction Stop

    Write-Host "Petición de binding ejecutada." -ForegroundColor Green

    # Verificación posterior
    $verified = Invoke-RestMethod `
        -Uri $bindingUri `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop

    $verified | ConvertTo-Json -Depth 5
}
