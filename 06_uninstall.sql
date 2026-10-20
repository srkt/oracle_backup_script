-- ============================================================================
-- 06_uninstall.sql
-- WARNING: this DELETES the backup tables including ALL stored DDL history.
-- Use it only to start over (for example after testing).
-- Run as the same schema user.
-- ============================================================================
BEGIN
  BEGIN
    DBMS_SCHEDULER.DROP_JOB(job_name => 'DPC_DDL_BKP_JOB', force => TRUE);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE NOT IN (-27475, -27486, -1031) THEN
        RAISE;
      END IF;
  END;
END;
/

DROP PACKAGE dpc_ddl_bkp_pkg;
DROP VIEW dpc_ddl_bkp_current_v;
DROP TRIGGER dpc_ddl_bkp_trg;
DROP TABLE dpc_ddl_bkp PURGE;
DROP TABLE dpc_ddl_bkp_scope PURGE;
