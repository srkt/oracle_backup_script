-- ============================================================================
-- 00_check_privileges.sql
-- Run as the schema user that will own the backup objects (no DBA needed).
-- Shows which privileges you have before you install anything.
-- ============================================================================
SET SERVEROUTPUT ON

DECLARE
  PROCEDURE chk(p_priv VARCHAR2) IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM session_privs WHERE privilege = p_priv;
    DBMS_OUTPUT.PUT_LINE(RPAD(p_priv, 20) || CASE WHEN l_n > 0 THEN 'OK' ELSE 'MISSING' END);
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Connected as: ' || USER);
  chk('CREATE TABLE');
  chk('CREATE VIEW');
  chk('CREATE TRIGGER');
  chk('CREATE PROCEDURE');
  chk('CREATE JOB');          -- only needed for the Oracle-scheduled nightly run
END;
/

-- Space to store the history (MAX_BYTES = -1 means unlimited quota).
SELECT tablespace_name, max_bytes FROM user_ts_quotas;

-- Can you read DDL of your own objects? (should return one CREATE TABLE script)
SELECT DBMS_METADATA.GET_DDL('TABLE', table_name) AS sample_ddl
  FROM user_tables
 WHERE ROWNUM = 1;

-- What would the scope pick up? (objects in this schema starting with DPC_COST)
SELECT object_type, object_name
  FROM user_objects
 WHERE object_type IN ('TABLE','PACKAGE','PACKAGE BODY','PROCEDURE')
   AND object_name LIKE 'DPC\_COST%' ESCAPE '\'
 ORDER BY object_type, object_name;
