Set-StrictMode -v latest
$ErrorActionPreference = "Stop"

$env:serilogdepartment="MyDepartment"
$env:serilogteam="MyTeam"

Import-Module "./log_to_eventhub.psm1"

$logger.Information("hello123")
