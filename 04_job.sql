-- ============================================================================
-- 04_job.sql
-- Run as the same schema user, after 02_package.sql.
-- Creates the nightly DBMS_SCHEDULER job DPC_DDL_BKP_JOB.
-- Needs the CREATE JOB privilege (see 00_check_privileges.sql). If you do not
-- have it, ask your DBA for:   GRANT CREATE JOB TO <your_user>;
-- or ask them to create this job for you. A fallback using DBMS_JOB is at the
-- bottom of this file.
--
-- Default schedule: every day at 23:30 America/New_York (follows daylight
-- saving time because a region name is used, not a fixed offset).
-- Change BYHOUR / BYMINUTE below to move the run time.
-- ============================================================================
SET SERVEROUTPUT ON

BEGIN
  -- Drop the job first if it already exists (ORA-27475 = job not found)
  BEGIN
    DBMS_SCHEDULER.DROP_JOB(job_name => 'DPC_DDL_BKP_JOB', force => TRUE);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE != -27475 THEN
        RAISE;
      END IF;
  END;

  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'DPC_DDL_BKP_JOB',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'DPC_DDL_BKP_PKG.RUN_CAPTURE',
    start_date      => SYSTIMESTAMP AT TIME ZONE 'America/New_York',
    repeat_interval => 'FREQ=DAILY;BYHOUR=23;BYMINUTE=30;BYSECOND=0',
    enabled         => TRUE,
    comments        => 'Nightly DDL backup into DPC_DDL_BKP (new version only when DDL changes)');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE IN (-27486, -1031) THEN
      DBMS_OUTPUT.PUT_LINE('Missing privilege: ask your DBA to run  GRANT CREATE JOB TO '
                           || USER || ';');
    END IF;
    RAISE;
END;
/

-- Run it right now (as a scheduler job) to test:
-- BEGIN DBMS_SCHEDULER.RUN_JOB('DPC_DDL_BKP_JOB', use_current_session => FALSE); END;
-- /

-- Change the time later, for example to 22:00:
-- BEGIN
--   DBMS_SCHEDULER.SET_ATTRIBUTE('DPC_DDL_BKP_JOB', 'repeat_interval',
--                                'FREQ=DAILY;BYHOUR=22;BYMINUTE=0;BYSECOND=0');
-- END;
-- /

-- ----------------------------------------------------------------------------
-- FALLBACK (only if DBMS_SCHEDULER is not allowed for you): legacy DBMS_JOB.
-- Uses the database server's time zone, and on newer Oracle versions it may
-- need the same CREATE JOB privilege. Uncomment to try it.
-- ----------------------------------------------------------------------------
-- DECLARE
--   l_job BINARY_INTEGER;
-- BEGIN
--   DBMS_JOB.SUBMIT(l_job,
--                   'BEGIN dpc_ddl_bkp_pkg.run_capture; END;',
--                   TRUNC(SYSDATE) + 23.5/24,
--                   'TRUNC(SYSDATE) + 1 + 23.5/24');
--   COMMIT;
-- END;
-- /
