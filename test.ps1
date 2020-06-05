Set-StrictMode -v latest
$ErrorActionPreference = "Stop"

${env:serilog.Author.Department}="MyDepartment"
${env:serilog.Author.Team}="MyTeam"
${env:serilog.Author.System}="MySystem"
${env:serilog.Author.Service}="MyService"

Import-Module "./LogToEventhub.psm1"

$logger.Information("hello123")
