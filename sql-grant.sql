-- =============================================================================
-- DEV/QA SQL-Login grants for the GPS app's per-subscriber DB principal
-- =============================================================================
--
-- Companion to scripts/sql-grants-prod.sql. The two scripts solve the same
-- problem (giving the app's DB principal datareader/datawriter + EXECUTE on
-- the schema, without which Widgetsphere.Core's metadata probe -- e.g.
-- `SELECT OBJECT_ID('[dbo].[gen_StaffActionAuthorization]')` -- returns NULL
-- from the app's session and surfaces as `InvalidOperationException: The
-- stored procedure '[dbo].[gen_StaffActionAuthorization]' doesn't exist.`)
-- but they target DIFFERENT principals because the env auth shapes differ:
--
--   PROD : sqlAzureADOnlyAuthentication=true.  No SQL-Login fallback. App
--          principals are the App Service system-assigned MIs, created via
--          `CREATE USER ... FROM EXTERNAL PROVIDER`. See sql-grants-prod.sql.
--
--   DEV  : sqlAzureADOnlyAuthentication=false (per dev.bicepparam).  GPS
--   /QA    today connects via a SQL-Login whose username+password ship in
--          the STS-issued `Common.User.SubscriberDbConnectionString` claim.
--          The login lives on the SQL Server (server-level), and a contained
--          DB user maps it into each per-subscriber GPS DB.  Until that
--          contained user + role membership exists, dbo objects are invisible
--          to the app's session and Widgetsphere reports them as "doesn't
--          exist". Verified 2026-05-13 (D-041 / commit c98586f).
--
-- Parameters (required; pass with sqlcmd -v — do not :setvar them in this file,
-- because :setvar overwrites -v and would ignore the values you pass)
-- --------------------------------
--   AppLogin  - server SQL login / DB user to grant (e.g. ExactGPS_Test01)
--
-- Azure SQL does not support USE to switch databases. Connect sqlcmd to the
-- target DB with -d <database> (ApplySqlGrants.ps1 does this per row).
--
-- Idempotency: each block is safe to re-run. The `IF NOT EXISTS` guards skip
-- the create; `ALTER ROLE ADD MEMBER` and `GRANT EXECUTE` are no-ops when
-- the membership / permission is already in place.
--
-- How to run
-- ----------
-- Prefer the PowerShell wrapper (loops migration\databases.txt):
--
--     $env:AZ_SQL_PWD = '<sqladmin password>'
--     .\ApplySqlGrants.ps1 -AppLogin ExactGPS_Test01
--
-- Manual sqlcmd (one database):
--
--     sqlcmd -S sql-exact-dev-001.database.windows.net -d db-exact-gps-dev `
--       -U sqladmin -P "<password>" `
--       -v AppLogin="ExactGPS_Test01" `
--       -i sql-grant.sql
--
-- For each migrated tenant DB / subscriber login, connect to that database
-- (-d) and pass AppLogin (often matches dbo.Subscriber.DbUserId).
--
-- =============================================================================

PRINT '== Database context: ' + DB_NAME() + ' ==';
PRINT '== App login: $(AppLogin) ==';
GO

-- =============================================================================
-- The DB principal the GPS app authenticates as. Pass via -v AppLogin=...
-- (sqlcmd substitutes $(AppLogin) before execution).
--
-- In a multi-subscriber world, run once per (database, AppLogin) pair; the
-- IF NOT EXISTS guard makes the file rerunnable.
-- =============================================================================
DECLARE @AppLogin sysname = N'$(AppLogin)';

-- (1) Contained DB user mapped to the server-level SQL login of the same
--     name. The SERVER-LEVEL CREATE LOGIN is out of scope of this file
--     (CREATE LOGIN must run against the `master` DB and is the AAD admin's
--     responsibility -- see PROD-READINESS.md). This block creates ONLY the
--     contained user once the login exists.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @AppLogin)
BEGIN
    DECLARE @CreateUserSql nvarchar(max) =
        N'CREATE USER [' + @AppLogin + N'] FOR LOGIN [' + @AppLogin + N']';
    EXEC sp_executesql @CreateUserSql;
    PRINT '  CREATE USER ' + @AppLogin + ' OK';
END
ELSE
    PRINT '  USER ' + @AppLogin + ' already exists, skipping CREATE';
GO

-- (2) Role memberships + EXECUTE on the dbo schema. Without these the
--     `OBJECT_ID()` metadata probe inside Widgetsphere.Core returns NULL from
--     the app's session and the framework reports every `gen_*` stored proc
--     as missing (D-041).
DECLARE @AppLogin sysname = N'$(AppLogin)';
DECLARE @sql nvarchar(max);

SET @sql = N'ALTER ROLE db_datareader ADD MEMBER [' + @AppLogin + N']';
EXEC sp_executesql @sql;

SET @sql = N'ALTER ROLE db_datawriter ADD MEMBER [' + @AppLogin + N']';
EXEC sp_executesql @sql;

SET @sql = N'GRANT EXECUTE ON SCHEMA::dbo TO [' + @AppLogin + N']';
EXEC sp_executesql @sql;

PRINT '  Role + EXECUTE grants applied to ' + @AppLogin;
GO

-- (3) Verification (verbatim copy of the probe used to diagnose D-041).
SELECT
    DB_NAME()                       AS [Database],
    dp.name                         AS [Principal],
    dp.type_desc                    AS [Type],
    STUFF((
        SELECT ', ' + r.name
        FROM sys.database_role_members rm
        JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
        WHERE rm.member_principal_id = dp.principal_id
        FOR XML PATH('')
    ), 1, 2, '')                    AS [Roles],
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.database_permissions p
        WHERE p.grantee_principal_id = dp.principal_id
          AND p.permission_name = 'EXECUTE'
          AND p.class_desc = 'SCHEMA'
    ) THEN 'YES' ELSE 'NO' END      AS [HasExecuteOnDbo]
FROM sys.database_principals dp
WHERE dp.name = N'$(AppLogin)';
GO
