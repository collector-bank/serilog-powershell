Set-StrictMode -v latest
$ErrorActionPreference = "Stop"

${env:serilog.Author.Department}="MyDepartment"
${env:serilog.Author.Team}="MyTeam"

Import-Module "./log_to_eventhub.psm1"

$logger.Information("hello123")
