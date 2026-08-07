<#
    Discover SQLite database files and write their names to migration\databases.txt
    (one per line), same inventory format as GetDatabases.ps1.

    Unlike SQL Server, SQLite has no server catalog of databases — each DB is a
    file. This script either:
      - scans a folder for *.db / *.sqlite / *.sqlite3, or
      - takes a single SQLite file path and records its base name

    Note: these names are for inventory only. MigrateSqlToBacpac.ps1 / SqlPackage
    target SQL Server, not SQLite.

.EXAMPLE
    # List all SQLite DBs under a folder
    .\GetDBSqlite.ps1 -SqlitePath 'D:\data\sqlite'

.EXAMPLE
    # Single file
    .\GetDBSqlite.ps1 -SqlitePath 'D:\data\app.db'
#>

#requires -Version 7.0

param(
    # Folder to scan, or a single .db / .sqlite / .sqlite3 file
    [Parameter(Mandatory)]
    [string] $SqlitePath,

    [string[]] $Extensions = @('.db', '.sqlite', '.sqlite3'),

    # ---- OUTPUT ----
    [string] $WorkDir = (Join-Path $PSScriptRoot "migration"),
    [switch] $Recurse,                                  # scan subfolders
    [switch] $Append                                    # add to databases.txt instead of overwriting
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $SqlitePath)) {
    throw "Path not found: $SqlitePath"
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$databaseListFile = Join-Path $WorkDir "databases.txt"

$item = Get-Item -LiteralPath $SqlitePath
$names = @()

if ($item.PSIsContainer) {
    Write-Host "Scanning for SQLite databases under $SqlitePath..." -ForegroundColor Cyan
    $files = Get-ChildItem -LiteralPath $SqlitePath -File -Recurse:$Recurse |
             Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() }
    $names = $files | ForEach-Object { $_.BaseName } | Sort-Object -Unique
}
else {
    $ext = $item.Extension.ToLowerInvariant()
    if ($Extensions -notcontains $ext) {
        Write-Host "Warning: '$ext' is not in -Extensions ($($Extensions -join ', ')); using file name anyway." -ForegroundColor Yellow
    }
    Write-Host "Using single SQLite file: $($item.FullName)" -ForegroundColor Cyan
    $names = @($item.BaseName)
}

if (-not $names) {
    throw "No SQLite database files found under $SqlitePath (extensions: $($Extensions -join ', '))."
}

Write-Host "Found $($names.Count) database(s):" -ForegroundColor Cyan
$names | ForEach-Object { Write-Host "  $_" }

if ($Append -and (Test-Path $databaseListFile)) {
    $existing = Get-Content $databaseListFile |
                ForEach-Object { $_.Trim() } |
                Where-Object   { $_ -and $_ -notmatch '^\s*#' -and $_ -notmatch '^-+$' }
    $names = @($existing + $names) | Sort-Object -Unique
}

$header = @(
    "# One database name per line (SQLite file base name)."
    "# Generated from $SqlitePath on $(Get-Date -Format 's') by GetDBSqlite.ps1"
    "# Inventory only — not used by SqlPackage / MigrateSqlToBacpac.ps1."
    "#"
)
($header + $names) | Set-Content -Path $databaseListFile -Encoding utf8

Write-Host ""
Write-Host "Wrote $($names.Count) database name(s) to $databaseListFile" -ForegroundColor Cyan
