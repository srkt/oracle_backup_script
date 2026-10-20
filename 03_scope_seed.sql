-- ============================================================================
-- 03_scope_seed.sql
-- Run as the same schema user (no DBA needed).
-- Uses USER as the owner, so it tracks objects in the schema you are logged
-- in as. To track another schema, run all the scripts there too.
-- ============================================================================
INSERT INTO dpc_ddl_bkp_scope (owner, object_type, name_pattern) VALUES (USER, 'TABLE',        'DPC\_COST%');
INSERT INTO dpc_ddl_bkp_scope (owner, object_type, name_pattern) VALUES (USER, 'PACKAGE',      'DPC\_COST%');
INSERT INTO dpc_ddl_bkp_scope (owner, object_type, name_pattern) VALUES (USER, 'PACKAGE BODY', 'DPC\_COST%');
INSERT INTO dpc_ddl_bkp_scope (owner, object_type, name_pattern) VALUES (USER, 'PROCEDURE',    'DPC\_COST%');
COMMIT;

-- Later, to add more: insert another row (for example FUNCTION, VIEW, TRIGGER).
-- To pause a row without deleting it:
--   UPDATE dpc_ddl_bkp_scope SET enabled = 'N' WHERE object_type = 'TABLE';
--   COMMIT;
