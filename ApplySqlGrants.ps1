<#
    Apply sql-grant.sql to each database listed in migration\databases.txt.
    Creates the DB user for -AppLogin (must already exist as a server login)
    and grants db_datareader, db_datawriter, and EXECUTE on dbo.

.EXAMPLE
    $env:AZ_SQL_PWD = '<sqladmin password>'
    .\ApplySqlGrants.ps1 -AppLogin ExactGPS_Test01
#>

#requires -Version 7.0

param(
    [Parameter(Mandatory)]
    [string] $AppLogin,

    [string] $AzureServerShortName = "sql-exact-dev-001",
    [string] $AzureAdminUser       = "sqladmin",
    [string] $WorkDir              = (Join-Path $PSScriptRoot "migration"),
    [string] $SqlFile              = (Join-Path $PSScriptRoot "sql-grant.sql")
)

$ErrorActionPreference = "Stop"
$AzureFqdn = "$AzureServerShortName.database.windows.net"

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "sqlcmd not found. Install the SQL Server command-line tools (sqlcmd)."
}
if (-not (Test-Path -LiteralPath $SqlFile)) {
    throw "SQL grants file not found: $SqlFile"
}

$azPwd = $env:AZ_SQL_PWD
if (-not $azPwd) { throw "Set `$env:AZ_SQL_PWD for the Azure SQL admin." }

$logDir           = Join-Path $WorkDir "logs"
$stateFile        = Join-Path $WorkDir "grants-state.csv"
$databaseListFile = Join-Path $WorkDir "databases.txt"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

if (-not (Test-Path $databaseListFile)) {
    throw "Database list not found: $databaseListFile"
}
$databases = Get-Content $databaseListFile |
             ForEach-Object { $_.Trim() } |
             Where-Object   { $_ -and $_ -notmatch '^\s*#' -and $_ -notmatch '^-+$' } |
             Sort-Object -Unique
if (-not $databases) { throw "No database names parsed from $databaseListFile" }

$state = @{}
if (Test-Path $stateFile) {
    Import-Csv $stateFile | ForEach-Object { $state["$($_.Database)|$($_.AppLogin)"] = $_ }
}
foreach ($db in $databases) {
    $key = "$db|$AppLogin"
    if (-not $state.ContainsKey($key)) {
        $state[$key] = [pscustomobject]@{
            Database = $db; AppLogin = $AppLogin; Granted = ""; Error = ""
        }
    }
}

function Save-State {
    $state.Values | Sort-Object Database, AppLogin | Export-Csv -Path $stateFile -NoTypeInformation
}

Write-Host "Databases to grant : $($databases.Count)" -ForegroundColor Cyan
Write-Host "Target             : $AzureFqdn"
Write-Host "App login          : $AppLogin"
Write-Host "SQL file           : $SqlFile"
Write-Host ""

$todo = @($databases | Where-Object { -not $state["$_|$AppLogin"].Granted })
Write-Host "[Grants] $($todo.Count) database(s) to process..." -ForegroundColor Yellow

foreach ($db in $todo) {
    $log = Join-Path $logDir "$db.grants.log"
    $row = $state["$db|$AppLogin"]
    Write-Host "  $db"
    try {
        sqlcmd -S $AzureFqdn -d $db -U $AzureAdminUser -P $azPwd `
            -v AppLogin="$AppLogin" `
            -b `
            -i $SqlFile *> $log
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd exit $LASTEXITCODE (see $log)" }
        $row.Granted = (Get-Date -Format o)
        $row.Error   = ""
    }
    catch {
        $row.Error = $_.Exception.Message
        Write-Host "  GRANTS FAILED: $db - $($_.Exception.Message)" -ForegroundColor Red
    }
    Save-State
}

$ok   = ($state.Values | Where-Object { $_.AppLogin -eq $AppLogin -and $_.Granted }).Count
$errs = ($state.Values | Where-Object { $_.AppLogin -eq $AppLogin -and $_.Error }).Count
Write-Host ""
Write-Host "Grants complete: $ok / $($databases.Count) succeeded. Errors: $errs." -ForegroundColor Cyan
Write-Host "State file: $stateFile"
if ($errs) { Write-Host "Rerun to retry failed items (completed grants are skipped)." }
