# DPC DDL Backup for Oracle

Automatically back up the DDL (no data) of selected Oracle database objects into a table inside the same schema, on a nightly schedule. A new version of an object is stored **only when its DDL actually changes**, and every older version is kept.

Everything runs inside Oracle (PL/SQL plus `DBMS_SCHEDULER`). No DBA access is required for the install, only the privileges listed below.

## How it works

1. `DPC_DDL_BKP_SCOPE` lists which objects to track: object type plus a name pattern, for example tables, packages, package bodies and procedures starting with `DPC_COST`.
2. The nightly job calls `DPC_DDL_BKP_PKG.RUN_CAPTURE`, which finds the matching objects and generates their DDL with `DBMS_METADATA`.
3. The new DDL text is compared with the latest stored version (`DBMS_LOB.COMPARE`). If it is the same, nothing is stored.
4. If it differs (or the object is new, or was dropped and recreated), a new row with the next `version_no` is inserted into `DPC_DDL_BKP`.
5. Tracked objects that no longer exist get a `DROPPED` row, so the history shows when they disappeared.
6. The history table is insert-only (a trigger blocks `UPDATE` and `DELETE`), so old versions are never lost.

## Objects created

| Object | Type | Purpose |
|---|---|---|
| `DPC_DDL_BKP_SCOPE` | table | What to track (owner, object type, name pattern, enabled flag) |
| `DPC_DDL_BKP` | table | DDL history, one row per object version |
| `DPC_DDL_BKP_TRG` | trigger | Makes `DPC_DDL_BKP` insert-only |
| `DPC_DDL_BKP_CURRENT_V` | view | Latest DDL per object (dropped objects hidden) |
| `DPC_DDL_BKP_PKG` | package | `RUN_CAPTURE` procedure that does the work |
| `DPC_DDL_BKP_JOB` | scheduler job | Runs `RUN_CAPTURE` every night |

## Requirements

Run the scripts as the schema user that **owns** the objects you want to back up. Needed privileges:

- `CREATE TABLE`, `CREATE VIEW`, `CREATE TRIGGER`, `CREATE PROCEDURE`
- Quota on a tablespace to store the history
- `CREATE JOB` for the Oracle-scheduled nightly run (optional, see [Scheduling](#scheduling))

`00_check_privileges.sql` reports what you have. A schema can always read the DDL of its own objects, so no extra grants such as `SELECT_CATALOG_ROLE` or `EXECUTE` on `DBMS_CRYPTO` are needed.

To back up several schemas, install the scripts in each of them.

## Install

Run these in order, as the owning schema user (SQL Developer: run as script, F5; SQL*Plus: `@file`):

| Step | Script | What it does |
|---|---|---|
| 0 | `00_check_privileges.sql` | Checks your privileges, quota and a sample `GET_DDL` |
| 1 | `01_tables.sql` | Creates the tables, trigger and view |
| 2 | `02_package.sql` | Creates `DPC_DDL_BKP_PKG` |
| 3 | `03_scope_seed.sql` | Adds the scope rows (`DPC_COST%` tables, packages, package bodies, procedures) |
| 4 | `04_job.sql` | Creates the nightly scheduler job |
| 5 | `05_verify.sql` | Runs a capture twice and shows results and job status |

Expected result of `05_verify.sql`: the first run adds version 1 for each in-scope object, and the second run reports `new_versions=0`. If the second run adds rows, the generated DDL is not stable for that object type, so open an issue with the object type.

## Configure what gets backed up

Scope is data, not code. Edit `DPC_DDL_BKP_SCOPE`:

```sql
-- Track functions starting with DPC_COST too
INSERT INTO dpc_ddl_bkp_scope (owner, object_type, name_pattern)
VALUES (USER, 'FUNCTION', 'DPC\_COST%');
COMMIT;

-- Pause a row without deleting it
UPDATE dpc_ddl_bkp_scope SET enabled = 'N' WHERE object_type = 'TABLE';
COMMIT;
```

Notes:

- `name_pattern` is a `LIKE` pattern matched with `ESCAPE '\'`. Write `DPC\_COST%` (with the backslash), because a bare `_` matches any single character.
- `object_type` uses the `ALL_OBJECTS` spelling, with a space: `PACKAGE BODY`, `TYPE BODY`, and so on.
- To track a package, add both a `PACKAGE` row and a `PACKAGE BODY` row.
- Objects that leave the scope are left alone. They are not marked as dropped.

## Scheduling

`04_job.sql` creates `DPC_DDL_BKP_JOB`, which runs daily at **23:30 America/New_York**. A region name is used, so the time follows daylight saving changes.

```sql
-- Run it now
BEGIN DBMS_SCHEDULER.RUN_JOB('DPC_DDL_BKP_JOB', use_current_session => FALSE); END;
/

-- Change the time (example: 22:00)
BEGIN
  DBMS_SCHEDULER.SET_ATTRIBUTE('DPC_DDL_BKP_JOB', 'repeat_interval',
                               'FREQ=DAILY;BYHOUR=22;BYMINUTE=0;BYSECOND=0');
END;
/

-- Check status and history
SELECT job_name, enabled, state, next_run_date FROM user_scheduler_jobs;
SELECT log_date, status, error#, additional_info
  FROM user_scheduler_job_run_details
 WHERE job_name = 'DPC_DDL_BKP_JOB' ORDER BY log_date DESC;
```

If you do not have `CREATE JOB`, ask your DBA to run `GRANT CREATE JOB TO <your_user>;` (or to create the job for you). `04_job.sql` also contains a commented `DBMS_JOB` fallback. Without any scheduler, you can run `BEGIN dpc_ddl_bkp_pkg.run_capture; END;` manually.

If any object fails during a run, the remaining objects are still processed, then the run ends with error `ORA-20002` listing the failed objects, which shows up in `USER_SCHEDULER_JOB_RUN_DETAILS`.

## Querying the history

```sql
-- Latest DDL of one object
SELECT ddl_text FROM dpc_ddl_bkp_current_v WHERE object_name = 'DPC_COST_ITEMS';

-- All versions of an object
SELECT version_no, change_type, captured_at
  FROM dpc_ddl_bkp
 WHERE object_name = 'DPC_COST_PKG' AND object_type = 'PACKAGE BODY'
 ORDER BY version_no;

-- What changed in the last 7 days
SELECT object_type, object_name, version_no, change_type, captured_at
  FROM dpc_ddl_bkp
 WHERE captured_at > SYSTIMESTAMP - INTERVAL '7' DAY
 ORDER BY captured_at DESC;

-- Fetch one specific old version
SELECT ddl_text FROM dpc_ddl_bkp
 WHERE object_name = 'DPC_COST_PKG' AND object_type = 'PACKAGE BODY' AND version_no = 3;
```

## Limitations

- **Table DDL** covers the table and its constraints. Separate indexes, triggers, comments and grants on the table are not captured yet.
- **Storage details** (tablespaces, storage clauses, segment attributes) are intentionally left out of the generated DDL, so environment differences do not create false versions.
- **Dropped detection** relies on `ALL_OBJECTS`. If the schema loses access to an object, it will look dropped.
- **Recompiles:** after an object is recompiled, it is re-checked every night because the stored `last_ddl_time` cannot be updated (the table is insert-only). This costs a few extra `GET_DDL` calls and never creates extra versions.
- **Backups of the backup:** the history lives in the same database it protects. Include these tables in your normal database backups or exports.
- Only DDL is stored, never table data.

## Purging or starting over

The history table is protected by a trigger. To delete rows on purpose, disable it first and re-enable it afterwards:

```sql
ALTER TRIGGER dpc_ddl_bkp_trg DISABLE;
-- delete what you need to
ALTER TRIGGER dpc_ddl_bkp_trg ENABLE;
```

`06_uninstall.sql` drops the job, package, view, trigger and both tables. **It deletes all stored history.**

## Repository contents

| File | Purpose |
|---|---|
| `00_check_privileges.sql` | Privilege, quota and `GET_DDL` check |
| `01_tables.sql` | Tables, trigger, view |
| `02_package.sql` | `DPC_DDL_BKP_PKG` |
| `03_scope_seed.sql` | Initial scope rows |
| `04_job.sql` | Nightly scheduler job |
| `05_verify.sql` | Verification run |
| `06_uninstall.sql` | Removes everything (deletes history) |

## Status

Review and test in a non-production schema before relying on it.
