-- ============================================================================
-- 05_verify.sql
-- Run as the same schema user, as a script (or one statement at a time).
-- ============================================================================
SET SERVEROUTPUT ON

-- 1) First run: should add version 1 (CREATED) for every in-scope object.
BEGIN
  dpc_ddl_bkp_pkg.run_capture;
END;
/

SELECT owner, object_type, object_name, version_no, change_type, captured_at
  FROM dpc_ddl_bkp
 ORDER BY owner, object_type, object_name, version_no;

-- 2) Second run on unchanged objects: output should say new_versions=0.
--    If it adds rows, the DDL output is not stable (tell me which object type).
BEGIN
  dpc_ddl_bkp_pkg.run_capture;
END;
/

SELECT COUNT(*) AS total_rows FROM dpc_ddl_bkp;

-- 3) Look at the latest DDL of one object
-- SELECT ddl_text FROM dpc_ddl_bkp_current_v WHERE object_name = 'DPC_COST_SOMETHING';

-- 4) Scheduler job status and run history (empty if you have no scheduler job)
SELECT job_name, enabled, state, next_run_date
  FROM user_scheduler_jobs
 WHERE job_name = 'DPC_DDL_BKP_JOB';

SELECT log_date, status, error#, additional_info
  FROM user_scheduler_job_run_details
 WHERE job_name = 'DPC_DDL_BKP_JOB'
 ORDER BY log_date DESC;
