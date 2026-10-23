$headers = @{
    Authorization = "Basic $(
        [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes(
                "$($env:SONARQUBE_TOKEN):"
            )
        )
    )"
    Accept = "application/json"
}

Invoke-RestMethod `
    -Uri "https://aas-sonar-pr.azure-paas.com/api/alm_settings/list" `
    -Method Get `
    -Headers $headers
