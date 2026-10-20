-- ============================================================================
-- 01_tables.sql
-- Run as the schema user that owns the DPC_COST% objects (no DBA needed).
-- Creates: DPC_DDL_BKP_SCOPE, DPC_DDL_BKP, insert-only trigger, current view.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Which objects to capture. One row per (object type, name pattern) in this
-- schema. name_pattern is a LIKE pattern matched with ESCAPE '\'
--   so  DPC\_COST%  means: starts with the literal text DPC_COST
-- object_type uses the ALL_OBJECTS spelling: TABLE, PACKAGE, PACKAGE BODY, ...
-- ----------------------------------------------------------------------------
CREATE TABLE dpc_ddl_bkp_scope (
  owner         VARCHAR2(128) NOT NULL,
  object_type   VARCHAR2(30)  NOT NULL,
  name_pattern  VARCHAR2(128) NOT NULL,
  enabled       CHAR(1) DEFAULT 'Y' NOT NULL,
  CONSTRAINT dpc_ddl_bkp_scope_pk    PRIMARY KEY (owner, object_type, name_pattern),
  CONSTRAINT dpc_ddl_bkp_scope_en_ck CHECK (enabled IN ('Y','N'))
);

-- ----------------------------------------------------------------------------
-- The DDL history. Insert-only: a new row (next version_no) is added only
-- when the generated DDL text differs from the latest stored version.
-- Old versions are never touched.
-- ----------------------------------------------------------------------------
CREATE TABLE dpc_ddl_bkp (
  owner         VARCHAR2(128) NOT NULL,
  object_type   VARCHAR2(30)  NOT NULL,
  object_name   VARCHAR2(128) NOT NULL,
  version_no    NUMBER        NOT NULL,
  change_type   VARCHAR2(10)  NOT NULL,   -- CREATED / MODIFIED / DROPPED
  ddl_text      CLOB,                     -- NULL when DROPPED
  last_ddl_time DATE,                     -- ALL_OBJECTS.LAST_DDL_TIME when captured
  captured_at   TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT dpc_ddl_bkp_pk    PRIMARY KEY (owner, object_type, object_name, version_no),
  CONSTRAINT dpc_ddl_bkp_ct_ck CHECK (change_type IN ('CREATED','MODIFIED','DROPPED'))
)
LOB (ddl_text) STORE AS SECUREFILE;

-- ----------------------------------------------------------------------------
-- Protect the history from updates and deletes.
-- (To purge on purpose, disable this trigger first, then re-enable it.)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER dpc_ddl_bkp_trg
BEFORE UPDATE OR DELETE ON dpc_ddl_bkp
BEGIN
  RAISE_APPLICATION_ERROR(-20001, 'DPC_DDL_BKP is insert-only');
END;
/

-- ----------------------------------------------------------------------------
-- Latest DDL per object (objects whose latest version is DROPPED are hidden).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW dpc_ddl_bkp_current_v AS
SELECT b.*
  FROM dpc_ddl_bkp b
 WHERE b.version_no = (SELECT MAX(x.version_no)
                         FROM dpc_ddl_bkp x
                        WHERE x.owner       = b.owner
                          AND x.object_type = b.object_type
                          AND x.object_name = b.object_name)
   AND b.change_type <> 'DROPPED';
