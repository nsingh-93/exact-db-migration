# Exact GPS SQL migration

Move on-prem SQL Server tenant databases to **Azure SQL Database** (BACPAC), grant the app SQL login access, and register the subscriber in **PASTS/STS**.

PowerShell 7+ is required for the migration scripts.

## End-to-end flow

```
On-prem SQL Server
        │
        ▼
GetDatabases.ps1              →  migration/databases.txt
        │
        ▼
MigrateSqlToBacpac.ps1        →  migration/bacpac/<name>.bacpac
        │
        ▼
MigrateBacpacToAzureSql.ps1   →  Azure SQL (standalone, then optional elastic pool)
        │
        ▼
ApplySqlGrants.ps1            →  DB user + reader/writer/EXECUTE  (or New-StsSubscriber -ProvisionSqlLogin)
        │
        ▼
New-StsSubscriber.ps1         →  clone STS subscriber + connection-string claims
```

`sql-connection.sql` is a read-only check of stored connection-string claims. It is not a migration step.

## Prerequisites

| Tool | Used by |
|------|---------|
| PowerShell 7+ | All `.ps1` scripts except notes that use `sqlcmd` only |
| [SqlPackage](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-download) (`dotnet tool install -g microsoft.sqlpackage`) | Export / import |
| `sqlcmd` | List DBs, grants, STS upsert |
| Azure CLI (`az login`) | Elastic pool move; Key Vault password for `New-StsSubscriber.ps1` |
| Network | This host must reach the source SQL Server **and** `*.database.windows.net` (firewall / VPN) |

**.NET runtime:** SqlPackage may require a newer .NET 10 runtime than the host already has. If you see “You must install or update .NET”, install `Microsoft.DotNet.Runtime.10` (or the version SqlPackage reports).

## Working folder

Defaults to `migration\` next to the scripts (`$PSScriptRoot\migration`).

```
migration/
  databases.txt          Inventory (one DB name per line; # comments ignored)
  bacpac/                Intermediate .bacpac files
  logs/                  Per-DB SqlPackage / sqlcmd logs
  export-state.csv       Export progress (gitignored)
  migration-state.csv    Import / pool-move progress (gitignored)
  grants-state.csv       Grant progress (gitignored)
```

`databases.txt` is gitignored. Edit it locally; comment out names you do not want to process.

## Secrets

Do not put passwords in scripts.

| Variable / source | Used for |
|-------------------|----------|
| `$env:SRC_SQL_PWD` | On-prem SQL auth (`GetDatabases.ps1`, `MigrateSqlToBacpac.ps1`) |
| `$env:AZ_SQL_PWD` | Azure SQL admin (`sqladmin`) for import and `ApplySqlGrants.ps1` |
| Key Vault `sql-admin-password` | `New-StsSubscriber.ps1` on **dev/qa** (`kv-exact-<env>-001`) |

Set session env vars once per terminal:

```powershell
$env:SRC_SQL_PWD = '...'
$env:AZ_SQL_PWD  = '...'
```

## Step-by-step

Run from the repo root. Adjust server names and logins for your environment.

### 1. List source databases

Writes user databases (excludes `master` / `model` / `msdb` / `tempdb`; online only by default) to `migration\databases.txt`.

```powershell
# Windows auth
.\GetDatabases.ps1 -SourceServer 'ONPREM-SQL01' -SourceUseWindowsAuth

# SQL auth
$env:SRC_SQL_PWD = '...'
.\GetDatabases.ps1 -SourceServer 'ONPREM-SQL01' -SourceUser 'sa'
```

Review and edit `migration\databases.txt` before export (comment out DBs you want to skip).

### 2. Export to BACPAC

Writes `migration\bacpac\<DbName>.bacpac`. Skips DBs already marked exported in `export-state.csv`.

```powershell
# SQL auth (script default)
$env:SRC_SQL_PWD = '...'
.\MigrateSqlToBacpac.ps1 -SourceServer 'ONPREM-SQL01' -SourceUser 'sa'

# Windows auth
.\MigrateSqlToBacpac.ps1 -SourceServer 'ONPREM-SQL01' -SourceUseWindowsAuth:$true
```

BACPAC export is **not** transactionally consistent on a busy live database. Prefer a quiet copy, restore, or snapshot when that matters.

### 3. Import into Azure SQL

Creates each database on the logical server (default `sql-exact-dev-001`) as General Purpose `GP_Gen5_2`, then optionally moves it into an elastic pool.

```powershell
$env:AZ_SQL_PWD = '...'

# Import only (default)
.\MigrateBacpacToAzureSql.ps1

# Import then move into pool-tenants-01
az login
.\MigrateBacpacToAzureSql.ps1 -Phase All

# Pool move only (already imported)
.\MigrateBacpacToAzureSql.ps1 -Phase Move
```

Expects `migration\bacpac\<name>.bacpac` for each name in `databases.txt`. Reruns skip rows already `Imported` / `Moved` in `migration-state.csv`.

### 4. Grant the app login on each tenant DB

Creates a **database user** mapped to an existing **server login** and grants `db_datawriter`, `db_datareader`, and `EXECUTE` on `dbo`. Does **not** create the server login.

```powershell
$env:AZ_SQL_PWD = '...'
.\ApplySqlGrants.ps1 -AppLogin ExactGPS_Test01
```

Applies only to names in `databases.txt`, not every database on the server. Azure SQL does not support `USE`; the script connects to each database with `sqlcmd -d <db>`.

If the login does not exist yet, create it on `master` first, or use `-ProvisionSqlLogin` in step 5.

### 5. Register the subscriber in STS (PASTS)

Clones apps, claim *names*, and policies from a template subscriber. Substitutes the new tenant’s connection string (and optional db user / password / code). Does **not** copy STS users.

```powershell
# See existing subscribers
.\New-StsSubscriber.ps1 -Environment dev -List

# Plan only
.\New-StsSubscriber.ps1 -Environment dev -DryRun `
  -Template 'ExactGPS_Demo' -Name 'NewAgency' `
  -ConnectionString 'Server=tcp:sql-exact-dev-001.database.windows.net,1433;Database=ExactGPS_NewAgency;User ID=...;Password=...;Encrypt=True;'

# Write STS rows; also CREATE LOGIN + grants on the tenant DB
.\New-StsSubscriber.ps1 -Environment dev -ProvisionSqlLogin `
  -Template 'ExactGPS_Demo' -Name 'NewAgency' `
  -ConnectionString '...'
```

- **dev/qa:** SQL auth as `sqladmin` from Key Vault.  
- **prod:** Azure AD via `az` CLI.  
- Re-run with the same `-Name` to update connection-string claims in place.

You can run `sql-upsert-subscriber.sql` in SSMS instead: set the `DECLARE` block and execute against `db-exact-sts-<env>`.

### 6. Verify connection-string claims

Against the **STS** database (`db-exact-sts-dev`), not a tenant GPS DB:

```powershell
sqlcmd -S sql-exact-dev-001.database.windows.net -d db-exact-sts-dev `
  -U sqladmin -P "$env:AZ_SQL_PWD" `
  -i sql-connection.sql
```

Or connect with the SQL Server (mssql) extension and run `sql-connection.sql`.

Then smoke-test the GPS app (or SSMS) as the tenant login and confirm objects such as `gen_*` procedures are visible.

## Script reference

| Script | Role |
|--------|------|
| `GetDatabases.ps1` | Query source SQL Server → `databases.txt` |
| `MigrateSqlToBacpac.ps1` | SqlPackage **Export** → `migration/bacpac` |
| `MigrateBacpacToAzureSql.ps1` | SqlPackage **Import**; optional `az sql db update` into elastic pool |
| `ApplySqlGrants.ps1` | Loop `databases.txt` and run `sql-grant.sql` |
| `New-StsSubscriber.ps1` | Fill and run `sql-upsert-subscriber.sql`; optional login + grants |

| SQL file | Role |
|----------|------|
| `sql-grant.sql` | Per-DB user + grants. Parameter: sqlcmd `-v AppLogin=...`. Connect with `-d <database>`. |
| `sql-upsert-subscriber.sql` | Clone/update STS subscriber from a template. Tokens filled by `New-StsSubscriber.ps1`. |
| `sql-connection.sql` | List subscriber connection-string claims (read-only). |

## Defaults (dev)

These can be overridden with script parameters:

- Azure logical server: `sql-exact-dev-001.database.windows.net`
- Admin login: `sqladmin`
- Resource group / pool (move phase): `rg-sql-migration` / `pool-tenants-01`
- Import SKU: `GP_Gen5_2` (temporary until pool move)
- STS database: `db-exact-sts-<environment>`

## Notes

- **Login vs user:** a SQL login is server-wide (`master`). A user + grants must exist **in each** tenant database. BACPAC import does not set that up for Azure.
- **One login vs per-tenant login:** `ApplySqlGrants.ps1` uses a single `-AppLogin` for every DB in the list. Per-subscriber logins need a different login per run (or `-ProvisionSqlLogin` from each connection string).
- **Resume:** delete or edit the relevant `*-state.csv` (or drop the Azure DB) if you need a full retry after a test import.
- **Drop a test DB in SSMS** (run against `master`): `DROP DATABASE [ExactGPS_Demo02];`
