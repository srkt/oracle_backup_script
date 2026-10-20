-- ============================================================================
-- 02_package.sql
-- Run as the same schema user, after 01_tables.sql (no DBA needed).
-- DPC_DDL_BKP_PKG.RUN_CAPTURE:
--   1. finds objects matching DPC_DDL_BKP_SCOPE
--   2. gets their DDL with DBMS_METADATA
--   3. compares it with the latest stored version (exact text comparison with
--      DBMS_LOB.COMPARE, so no DBMS_CRYPTO grant is needed) and inserts a new
--      version ONLY if it differs, or the object is new / was recreated
--   4. records a DROPPED version for tracked objects that no longer exist
-- Each object is committed on its own. If any object fails, the run still
-- processes the rest and then raises an error at the end, so the scheduler
-- shows the run as FAILED with the object names in the error text.
-- ============================================================================
SET DEFINE OFF

CREATE OR REPLACE PACKAGE dpc_ddl_bkp_pkg
AS
  PROCEDURE run_capture;
END dpc_ddl_bkp_pkg;
/

CREATE OR REPLACE PACKAGE BODY dpc_ddl_bkp_pkg
AS
  c_max_err_len CONSTANT PLS_INTEGER := 1500;

  -- Same settings every run, so the generated DDL stays stable between runs.
  PROCEDURE set_transforms IS
  BEGIN
    DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'DEFAULT', TRUE);
    DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'PRETTY', TRUE);
    DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SQLTERMINATOR', TRUE);
    DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SEGMENT_ATTRIBUTES', FALSE);
    DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'STORAGE', FALSE);
  END set_transforms;

  PROCEDURE run_capture IS
    l_ddl      CLOB;
    l_prev     CLOB;
    l_change   VARCHAR2(10);
    l_save     BOOLEAN;
    l_msg      VARCHAR2(4000);
    l_err_text VARCHAR2(4000);
    l_checked  PLS_INTEGER := 0;
    l_added    PLS_INTEGER := 0;
    l_dropped  PLS_INTEGER := 0;
    l_errors   PLS_INTEGER := 0;

    -- In-scope objects that exist now, with their latest stored version (if any).
    CURSOR c_obj IS
      SELECT o.owner, o.object_type, o.object_name,
             o.last_ddl_time,
             l.version_no,
             l.change_type,
             l.last_ddl_time AS prev_ddl_time
        FROM (SELECT ao.owner, ao.object_type, ao.object_name,
                     MAX(ao.last_ddl_time) AS last_ddl_time
                FROM dpc_ddl_bkp_scope s
                JOIN all_objects ao
                  ON ao.owner       = s.owner
                 AND ao.object_type LIKE s.object_type
                 AND ao.object_name LIKE s.name_pattern ESCAPE '\'
               WHERE s.enabled = 'Y'
                 AND ao.object_name NOT LIKE 'BIN$%'
               GROUP BY ao.owner, ao.object_type, ao.object_name) o
        LEFT JOIN (SELECT b.owner, b.object_type, b.object_name,
                          b.version_no, b.change_type, b.last_ddl_time,
                          ROW_NUMBER() OVER (PARTITION BY b.owner, b.object_type, b.object_name
                                             ORDER BY b.version_no DESC) AS rn
                     FROM dpc_ddl_bkp b) l
          ON l.rn          = 1
         AND l.owner       = o.owner
         AND l.object_type = o.object_type
         AND l.object_name = o.object_name
       ORDER BY o.owner, o.object_type, o.object_name;
  BEGIN
    set_transforms;

    ---------------------------------------------------------------------------
    -- 1) New and changed objects
    ---------------------------------------------------------------------------
    FOR r IN c_obj LOOP
      l_checked := l_checked + 1;
      BEGIN
        -- Cheap skip: object exists, was not dropped, and Oracle's LAST_DDL_TIME
        -- is the same as when we last captured it, so nothing can have changed.
        IF r.version_no IS NOT NULL
           AND r.change_type <> 'DROPPED'
           AND r.prev_ddl_time = r.last_ddl_time
        THEN
          NULL;
        ELSE
          l_ddl  := DBMS_METADATA.GET_DDL(REPLACE(r.object_type, ' ', '_'),
                                          r.object_name, r.owner);
          l_save := FALSE;

          IF r.version_no IS NULL OR r.change_type = 'DROPPED' THEN
            l_change := 'CREATED';
            l_save   := TRUE;
          ELSE
            SELECT b.ddl_text
              INTO l_prev
              FROM dpc_ddl_bkp b
             WHERE b.owner       = r.owner
               AND b.object_type = r.object_type
               AND b.object_name = r.object_name
               AND b.version_no  = r.version_no;

            IF l_prev IS NULL OR DBMS_LOB.COMPARE(l_ddl, l_prev) <> 0 THEN
              l_change := 'MODIFIED';
              l_save   := TRUE;
            END IF;
          END IF;

          IF l_save THEN
            INSERT INTO dpc_ddl_bkp
                   (owner, object_type, object_name, version_no, change_type,
                    ddl_text, last_ddl_time)
            VALUES (r.owner, r.object_type, r.object_name,
                    NVL(r.version_no, 0) + 1, l_change,
                    l_ddl, r.last_ddl_time);
            COMMIT;
            l_added := l_added + 1;
          END IF;

          IF DBMS_LOB.ISTEMPORARY(l_ddl) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_ddl);
          END IF;
        END IF;
      EXCEPTION
        WHEN OTHERS THEN
          l_msg := SQLERRM;
          ROLLBACK;
          l_errors := l_errors + 1;
          IF NVL(LENGTH(l_err_text), 0) < c_max_err_len THEN
            l_err_text := SUBSTR(l_err_text || r.object_type || ' ' || r.owner || '.'
                                 || r.object_name || ': ' || l_msg || ' | ',
                                 1, c_max_err_len);
          END IF;
      END;
    END LOOP;

    ---------------------------------------------------------------------------
    -- 2) Dropped objects: latest version is not DROPPED, but the object no
    --    longer exists in the database at all. (Objects that merely left the
    --    scope table are NOT treated as dropped.)
    ---------------------------------------------------------------------------
    BEGIN
      FOR d IN (SELECT l.owner, l.object_type, l.object_name, l.version_no
                  FROM (SELECT b.owner, b.object_type, b.object_name,
                               b.version_no, b.change_type,
                               ROW_NUMBER() OVER (PARTITION BY b.owner, b.object_type, b.object_name
                                                  ORDER BY b.version_no DESC) AS rn
                          FROM dpc_ddl_bkp b) l
                 WHERE l.rn = 1
                   AND l.change_type <> 'DROPPED'
                   AND NOT EXISTS (SELECT 1
                                     FROM all_objects a
                                    WHERE a.owner       = l.owner
                                      AND a.object_type = l.object_type
                                      AND a.object_name = l.object_name))
      LOOP
        INSERT INTO dpc_ddl_bkp
               (owner, object_type, object_name, version_no, change_type,
                ddl_text, last_ddl_time)
        VALUES (d.owner, d.object_type, d.object_name, d.version_no + 1, 'DROPPED',
                NULL, NULL);
        COMMIT;
        l_dropped := l_dropped + 1;
      END LOOP;
    EXCEPTION
      WHEN OTHERS THEN
        l_msg := SQLERRM;
        ROLLBACK;
        l_errors := l_errors + 1;
        l_err_text := SUBSTR(l_err_text || 'DROPPED-CHECK: ' || l_msg || ' | ',
                             1, c_max_err_len);
    END;

    DBMS_OUTPUT.PUT_LINE('DPC_DDL_BKP_PKG: checked=' || l_checked
                         || ' new_versions=' || l_added
                         || ' dropped=' || l_dropped
                         || ' errors=' || l_errors);

    IF l_errors > 0 THEN
      RAISE_APPLICATION_ERROR(-20002,
        SUBSTR('DPC_DDL_BKP_PKG finished with ' || l_errors || ' error(s) (checked '
               || l_checked || ', new versions ' || l_added || ', dropped '
               || l_dropped || '): ' || l_err_text, 1, 2000));
    END IF;
  END run_capture;

END dpc_ddl_bkp_pkg;
/

SHOW ERRORS PACKAGE dpc_ddl_bkp_pkg
SHOW ERRORS PACKAGE BODY dpc_ddl_bkp_pkg
