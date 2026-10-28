
$ErrorActionPreference = "Stop"

$Root = (Get-Location).Path
$Output = Join-Path $Root "_repo_inventory"
New-Item -ItemType Directory -Path $Output -Force | Out-Null

$IgnoredDirs = @(
    ".git", ".vs", "bin", "obj", "node_modules",
    ".sonarqube", "_repo_inventory"
)

Write-Host "Scanning repository: $Root"

$Files = Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
    Where-Object {
        $relative = $_.FullName.Substring($Root.Length).
            TrimStart('\', '/')
        $parts = $relative -split '[\\/]'
        -not ($parts | Where-Object { $_ -in $IgnoredDirs })
    }

$ByExtension = $Files |
    Group-Object {
        if ($_.Extension) { $_.Extension.ToLowerInvariant() }
        else { "[no extension]" }
    } |
    ForEach-Object {
        [PSCustomObject]@{
            Extension  = $_.Name
            FileCount  = $_.Count
            TotalBytes = ($_.Group |
                Measure-Object Length -Sum).Sum
            TotalMB    = [math]::Round(
                (($_.Group | Measure-Object Length -Sum).Sum / 1MB), 2
            )
        }
    } |
    Sort-Object TotalBytes -Descending

$ByExtension | Export-Csv `
    (Join-Path $Output "extensions.csv") `
    -NoTypeInformation -Encoding UTF8

$ByFolder = $Files |
    ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length).
            TrimStart('\', '/')
        $parts = $relative -split '[\\/]'
        $folder = if ($parts.Count -gt 1) {
            $parts[0]
        } else {
            "[root]"
        }

        [PSCustomObject]@{
            Folder = $folder
            Bytes  = $_.Length
        }
    } |
    Group-Object Folder |
    ForEach-Object {
        [PSCustomObject]@{
            Folder    = $_.Name
            FileCount = $_.Count
            TotalMB   = [math]::Round(
                (($_.Group | Measure-Object Bytes -Sum).Sum / 1MB), 2
            )
        }
    } |
    Sort-Object TotalMB -Descending

$ByFolder | Export-Csv `
    (Join-Path $Output "folders.csv") `
    -NoTypeInformation -Encoding UTF8

Write-Host "Inventory completed: $Output"
Write-Host "Review extensions.csv and folders.csv"
