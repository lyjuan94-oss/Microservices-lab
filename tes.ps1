$csvPath = ".\Sonar_Projects_Without_Binding.csv"

Get-Content -Path $csvPath -TotalCount 3

$data = Import-Csv -LiteralPath $csvPath

$data[0].PSObject.Properties.Name | ForEach-Object {
    "[$_]"
}
