<#
    Export databases from an on-prem SQL Server to .bacpac files (SqlPackage).
    Reads migration\databases.txt; writes migration\bacpac\<name>.bacpac.
    Resumable via export-state.csv (skips DBs already marked Exported).

.IMPORTANT
    BACPAC export is NOT transactionally consistent on a live database.
    Prefer a quiet copy, restored backup, or snapshot when consistency matters.

    Source DB users mapped to server logins cannot be stored in a BACPAC
    (SQL71501). Export sets VerifyExtraction=false so those references do
    not fail the package. Recreate Azure users after import with ApplySqlGrants.ps1.

.EXAMPLE
    # Windows auth (default)
    .\MigrateSqlToBacpac.ps1 -SourceServer 'ONPREM-SQL01'

.EXAMPLE
    # SQL auth
    $env:SRC_SQL_PWD = '<password>'
    .\MigrateSqlToBacpac.ps1 -SourceServer 'ONPREM-SQL01' -SourceUseWindowsAuth:$false -SourceUser 'sa'
#>

#requires -Version 7.0

param(
    # ---- SOURCE (on-prem / staging copy) ----
    [Parameter(Mandatory)]
    [string] $SourceServer,
    [bool]   $SourceUseWindowsAuth = $false,            # uses Windows login when -SourceUseWindowsAuth:$true
    [string] $SourceUser           = "",               # used only when -SourceUseWindowsAuth:$false

    # ---- RUNTIME ----
    [string] $WorkDir     = (Join-Path $PSScriptRoot "migration"),
    [int]    $Throttle    = 1,
    [string] $SqlPackage  = "SqlPackage"
)

$ErrorActionPreference = "Stop"

$bacpacDir        = Join-Path $WorkDir "bacpac"
$logDir           = Join-Path $WorkDir "logs"
$stateFile        = Join-Path $WorkDir "export-state.csv"
$databaseListFile = Join-Path $WorkDir "databases.txt"
New-Item -ItemType Directory -Force -Path $bacpacDir, $logDir | Out-Null

if (-not (Get-Command $SqlPackage -ErrorAction SilentlyContinue)) {
    throw "SqlPackage not found ('$SqlPackage'). Install: dotnet tool install -g microsoft.sqlpackage"
}

if (-not (Test-Path $databaseListFile)) {
    throw "Database list not found: $databaseListFile (one source DB name per line)."
}
$databases = Get-Content $databaseListFile |
             ForEach-Object { $_.Trim() } |
             Where-Object   { $_ -and $_ -notmatch '^\s*#' -and $_ -notmatch '^-+$' } |
             Sort-Object -Unique
if (-not $databases) { throw "No database names parsed from $databaseListFile" }

# Load or initialise export state (keyed by database name)
$state = @{}
if (Test-Path $stateFile) {
    Import-Csv $stateFile | ForEach-Object { $state[$_.Database] = $_ }
}
foreach ($db in $databases) {
    if (-not $state.ContainsKey($db)) {
        $state[$db] = [pscustomobject]@{
            Database = $db; Exported = ""; Error = ""; Bacpac = (Join-Path $bacpacDir "$db.bacpac")
        }
    }
}

function Save-State {
    $state.Values | Sort-Object Database | Export-Csv -Path $stateFile -NoTypeInformation
}

function Merge-Results([array]$results) {
    foreach ($r in $results) {
        $row = $state[$r.Database]
        if ($r.Ok) {
            $row.Exported = (Get-Date -Format o)
            $row.Error    = ""
            $row.Bacpac   = $r.Bacpac
        }
        else {
            $row.Error = $r.Error
        }
    }
    Save-State
}

$srcPwd = $env:SRC_SQL_PWD
if (-not $SourceUseWindowsAuth) {
    if (-not $SourceUser) { throw "Pass -SourceUser when using SQL authentication (-SourceUseWindowsAuth:`$false)." }
    if (-not $srcPwd)     { throw "Set `$env:SRC_SQL_PWD for SQL-auth source." }
}

Write-Host "Databases to export : $($databases.Count)" -ForegroundColor Cyan
Write-Host "Source server       : $SourceServer"
Write-Host "Auth                : $(if ($SourceUseWindowsAuth) { 'Windows integrated' } else { "SQL ($SourceUser)" })"
Write-Host "Database list       : $databaseListFile"
Write-Host "BACPAC output       : $bacpacDir"
Write-Host ""

$todo = @($databases | Where-Object { -not $state[$_].Exported })
Write-Host "[Export] $($todo.Count) database(s) to export..." -ForegroundColor Yellow

$results = $todo | ForEach-Object -ThrottleLimit $Throttle -Parallel {
    $db     = $_
    $exe    = $using:SqlPackage
    $bacpac = Join-Path $using:bacpacDir "$db.bacpac"
    $log    = Join-Path $using:logDir "$db.export.log"

    $args = @(
        "/Action:Export"
        "/SourceServerName:$($using:SourceServer)"
        "/SourceDatabaseName:$db"
        "/SourceTrustServerCertificate:True"
        "/TargetFile:$bacpac"
        "/OverwriteFiles:True"
        "/p:VerifyExtraction=false"
    )
    if (-not $using:SourceUseWindowsAuth) {
        $args += "/SourceUser:$($using:SourceUser)"
        $args += "/SourcePassword:$($using:srcPwd)"
    }

    try {
        & $exe @args *> $log
        if ($LASTEXITCODE -ne 0) { throw "SqlPackage exit $LASTEXITCODE (see $log)" }
        [pscustomobject]@{ Database = $db; Ok = $true;  Error = ""; Bacpac = $bacpac }
    } catch {
        [pscustomobject]@{ Database = $db; Ok = $false; Error = $_.Exception.Message; Bacpac = $bacpac }
    }
}

Merge-Results $results
$results | Where-Object { -not $_.Ok } |
    ForEach-Object { Write-Host "  EXPORT FAILED: $($_.Database) - $($_.Error)" -ForegroundColor Red }

$ok   = ($state.Values | Where-Object { $_.Exported }).Count
$errs = ($state.Values | Where-Object { $_.Error }).Count
Write-Host ""
Write-Host "Export complete: $ok / $($databases.Count) succeeded. Errors: $errs." -ForegroundColor Cyan
Write-Host "State file: $stateFile"
Write-Host "Next: .\MigrateBacpacToAzureSql.ps1"
if ($errs) { Write-Host "Rerun to retry failed items (completed exports are skipped)." }
