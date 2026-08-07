<#
    Query an on-prem SQL Server for its user databases and write the names to
    migration\databases.txt (one per line), ready for MigrateSqlToBacpac.ps1.

    Excludes system databases (master/model/msdb/tempdb) and, by default,
    offline/restoring databases.

.EXAMPLE
    # Windows auth
    .\GetDatabases.ps1 -SourceServer 'ONPREM-SQL01' -SourceUseWindowsAuth

.EXAMPLE
    # SQL auth
    $env:SRC_SQL_PWD = '<password>'
    .\GetDatabases.ps1 -SourceServer 'ONPREM-SQL01' -SourceUser 'sa'
#>

#requires -Version 7.0

param(
    # ---- SOURCE (on-prem / staging copy) ----
    [Parameter(Mandatory)]
    [string] $SourceServer,
    [switch] $SourceUseWindowsAuth,                     # omit for SQL auth
    [string] $SourceUser           = "",               # used only for SQL auth

    # ---- OUTPUT ----
    [string] $WorkDir     = (Join-Path $PSScriptRoot "migration"),
    [switch] $IncludeOffline,                           # include databases not in ONLINE state
    [switch] $Append                                    # add to databases.txt instead of overwriting
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "sqlcmd not found. Install the SQL Server command-line tools (msodbcsql/sqlcmd)."
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$databaseListFile = Join-Path $WorkDir "databases.txt"

$srcPwd = $env:SRC_SQL_PWD
if (-not $SourceUseWindowsAuth) {
    if (-not $SourceUser) { throw "Pass -SourceUser when using SQL authentication (or add -SourceUseWindowsAuth)." }
    if (-not $srcPwd)     { throw "Set `$env:SRC_SQL_PWD for SQL-auth source." }
}

$stateFilter = if ($IncludeOffline) { "" } else { "AND state = 0" }
$query = "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 $stateFilter ORDER BY name;"

$sqlcmdArgs = @(
    "-S", $SourceServer
    "-h", "-1"
    "-W"
    "-Q", $query
)
if ($SourceUseWindowsAuth) {
    $sqlcmdArgs += "-E"
} else {
    $sqlcmdArgs += @("-U", $SourceUser, "-P", $srcPwd)
}

Write-Host "Querying databases on $SourceServer..." -ForegroundColor Cyan
$output = & sqlcmd @sqlcmdArgs
if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE). Check server name, credentials, and network access." }

$names = $output |
         ForEach-Object { $_.Trim() } |
         Where-Object   { $_ -and $_ -notmatch '^-+$' } |
         Sort-Object -Unique

if (-not $names) { throw "No user databases found on $SourceServer." }

Write-Host "Found $($names.Count) database(s):" -ForegroundColor Cyan
$names | ForEach-Object { Write-Host "  $_" }

if ($Append -and (Test-Path $databaseListFile)) {
    $existing = Get-Content $databaseListFile |
                ForEach-Object { $_.Trim() } |
                Where-Object   { $_ -and $_ -notmatch '^\s*#' -and $_ -notmatch '^-+$' }
    $names = @($existing + $names) | Sort-Object -Unique
}

$header = @(
    "# One target database name per line (must match <name>.bacpac in bacpac\)."
    "# Generated from $SourceServer on $(Get-Date -Format 's') by GetDatabases.ps1"
    "# Edit this file, then run:  .\MigrateSqlToBacpac.ps1"
    "#"
)
($header + $names) | Set-Content -Path $databaseListFile -Encoding utf8

Write-Host ""
Write-Host "Wrote $($names.Count) database name(s) to $databaseListFile" -ForegroundColor Cyan
Write-Host "Next: .\MigrateSqlToBacpac.ps1 -SourceServer '$SourceServer'"
