<#
    Import .bacpac files listed in migration\databases.txt into Azure SQL Database (SqlPackage),
    optionally move each database into an elastic pool. Resumable via state CSV.

.EXAMPLE
    $env:AZ_SQL_PWD = '<password>'
    .\MigrateBacpacToAzureSql.ps1

    .\MigrateBacpacToAzureSql.ps1 -Phase Move
    Use the above to just move to elastic pools

    .\MigrateBacpacToAzureSql.ps1 -Phase All
    Use the above to import to standalone DBs and then move to elastic pools
#>

#requires -Version 7.0

param(
    # ---- TARGET (Azure) ----
    [string] $AzureServerShortName   = "sql-exact-dev-001",
    [string] $ResourceGroup          = "rg-sql-migration",
    [string] $ElasticPool            = "pool-tenants-01",
    [string] $AzureAdminUser         = "sqladmin",
    [string] $ImportServiceObjective = "GP_Gen5_2",       # temp objective before pool move
    [string] $TargetTenantId         = "",               # target Entra tenant (cross-tenant move)
    [string] $TargetSubscription     = "",               # target subscription id/name for Phase 2

    # ---- RUNTIME ----
    [string] $WorkDir                = (Join-Path $PSScriptRoot "migration"),
    [int]    $Throttle               = 1,                 # concurrent workers
    [string] $SqlPackage             = "SqlPackage",      # or full path to SqlPackage(.exe)
    [ValidateSet("Import","Move","All")]
    [string] $Phase                  = "Import"
)

$ErrorActionPreference = "Stop"
$AzureFqdn = "$AzureServerShortName.database.windows.net"

$bacpacDir        = Join-Path $WorkDir "bacpac"
$logDir           = Join-Path $WorkDir "logs"
$stateFile        = Join-Path $WorkDir "migration-state.csv"
$databaseListFile = Join-Path $WorkDir "databases.txt"
New-Item -ItemType Directory -Force -Path $bacpacDir, $logDir | Out-Null

# Build list from migration\databases.txt -> migration\bacpac\<name>.bacpac
if (-not (Test-Path $databaseListFile)) {
    throw "Database list not found: $databaseListFile (one target DB name per line; bacpac files in $bacpacDir)."
}
$names = Get-Content $databaseListFile |
         ForEach-Object { $_.Trim() } |
         Where-Object   { $_ -and $_ -notmatch '^\s*#' -and $_ -notmatch '^-+$' } |
         Sort-Object -Unique
if (-not $names) { throw "No database names parsed from $databaseListFile" }

$importJobs = foreach ($db in $names) {
    [pscustomobject]@{
        Database = $db
        Bacpac   = Join-Path $bacpacDir "$db.bacpac"
    }
}
$databases = $importJobs.Database

# Load or initialise the state table (keyed by database name)
$state = @{}
if (Test-Path $stateFile) {
    Import-Csv $stateFile | ForEach-Object { $state[$_.Database] = $_ }
}
foreach ($db in $databases) {
    if (-not $state.ContainsKey($db)) {
        $state[$db] = [pscustomobject]@{
            Database = $db; Imported = ""; Moved = ""; Error = ""
        }
    }
}

function Save-State {
    $state.Values | Sort-Object Database | Export-Csv -Path $stateFile -NoTypeInformation
}

function Merge-Results([array]$results, [string]$field) {
    foreach ($r in $results) {
        $row = $state[$r.Database]
        if ($r.Ok) { $row.$field = (Get-Date -Format o); $row.Error = "" }
        else       { $row.Error  = $r.Error }
    }
    Save-State
}

$azPwd = $env:AZ_SQL_PWD

Write-Host "Databases to process : $($databases.Count)" -ForegroundColor Cyan
Write-Host "Work directory       : $WorkDir"
Write-Host "Database list        : $databaseListFile"
Write-Host "Target               : $AzureFqdn / pool '$ElasticPool'"
Write-Host ""

# ---------------------------------------------------------------------------
# Phase 1 - IMPORT  (creates a standalone DB on the Azure logical server)
# ---------------------------------------------------------------------------
if ($Phase -in "Import","All") {
    if (-not $azPwd) { throw "Set `$env:AZ_SQL_PWD for the Azure SQL admin." }
    $todo = @(
        foreach ($job in $importJobs) {
            if ($state[$job.Database].Imported) { continue }
            [pscustomobject]@{ Database = $job.Database; Bacpac = $job.Bacpac }
        }
    )
    Write-Host "[Import] $($todo.Count) database(s) to import..." -ForegroundColor Yellow

    $results = $todo | ForEach-Object -ThrottleLimit $Throttle -Parallel {
        $db     = $_.Database
        $bacpac = $_.Bacpac
        $exe    = $using:SqlPackage
        $log    = Join-Path $using:logDir "$db.import.log"

        if (-not (Test-Path -LiteralPath $bacpac)) {
            return [pscustomobject]@{ Database = $db; Ok = $false; Error = "bacpac missing: $bacpac" }
        }

        $args = @(
            "/Action:Import"
            "/SourceFile:$bacpac"
            "/TargetServerName:$($using:AzureFqdn)"
            "/TargetDatabaseName:$db"
            "/TargetUser:$($using:AzureAdminUser)"
            "/TargetPassword:$($using:azPwd)"
            "/TargetEncryptConnection:True"
            "/TargetTrustServerCertificate:False"
            "/p:DatabaseEdition=GeneralPurpose"
            "/p:DatabaseServiceObjective=$($using:ImportServiceObjective)"
        )

        try {
            & $exe @args *> $log
            if ($LASTEXITCODE -ne 0) { throw "SqlPackage exit $LASTEXITCODE (see $log)" }
            [pscustomobject]@{ Database = $db; Ok = $true;  Error = "" }
        } catch {
            [pscustomobject]@{ Database = $db; Ok = $false; Error = $_.Exception.Message }
        }
    }
    Merge-Results $results "Imported"
    $results | Where-Object { -not $_.Ok } |
        ForEach-Object { Write-Host "  IMPORT FAILED: $($_.Database) - $($_.Error)" -ForegroundColor Red }
}

# ---------------------------------------------------------------------------
# Phase 2 - MOVE into the elastic pool
# ---------------------------------------------------------------------------
if ($Phase -in "Move","All") {
    if ($TargetSubscription) {
        az account set --subscription $TargetSubscription
        if ($LASTEXITCODE -ne 0) {
            throw "Could not select target subscription '$TargetSubscription'. Run 'az login --tenant $TargetTenantId' first."
        }
    }

    $todo = $databases | Where-Object { $state[$_].Imported -and -not $state[$_].Moved }
    Write-Host "[Move] $($todo.Count) database(s) into pool '$ElasticPool'..." -ForegroundColor Yellow

    foreach ($db in $todo) {
        $log = Join-Path $logDir "$db.move.log"
        try {
            az sql db update `
                --resource-group $ResourceGroup `
                --server $AzureServerShortName `
                --name $db `
                --elastic-pool $ElasticPool *> $log
            if ($LASTEXITCODE -ne 0) { throw "az exit $LASTEXITCODE (see $log)" }
            $state[$db].Moved = (Get-Date -Format o); $state[$db].Error = ""
        } catch {
            $state[$db].Error = $_.Exception.Message
            Write-Host "  MOVE FAILED: $db - $($_.Exception.Message)" -ForegroundColor Red
        }
        Save-State
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$done = ($state.Values | Where-Object { $_.Moved }).Count
$imported = ($state.Values | Where-Object { $_.Imported }).Count
$errs = ($state.Values | Where-Object { $_.Error }).Count
Write-Host ""
if ($Phase -eq "Import") {
    Write-Host "Import complete: $imported / $($databases.Count). Errors: $errs." -ForegroundColor Cyan
} else {
    Write-Host "Complete: $done / $($databases.Count) fully migrated (import + pool). Errors: $errs." -ForegroundColor Cyan
}
Write-Host "State file: $stateFile"
if ($errs) { Write-Host "Rerun the script to retry failed items (completed steps are skipped)." }
