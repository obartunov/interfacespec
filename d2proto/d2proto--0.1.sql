\echo Use "CREATE EXTENSION d2proto" to load this file. \quit

-- configuration taken from the protocol spec
CREATE FUNCTION d2_configure(lifetime_ends text[], guards text[]) RETURNS void
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
-- capabilities of an index's AM (IndexAmRoutine), as JSON
CREATE FUNCTION d2_caps(idx regclass) RETURNS json
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
-- call scan callbacks in the given order; returns observed events
CREATE FUNCTION d2_run(idx regclass, opr regoperator, val text, index_only bool, history text[])
  RETURNS json AS 'MODULE_PATHNAME' LANGUAGE C;
-- run a query with the observer on idx; returns observed events
CREATE FUNCTION d2_observe(idx regclass, query text) RETURNS json
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
-- open query as a scroll cursor with the observer on idx, run the fetches
CREATE FUNCTION d2_observe_cursor(idx regclass, query text, fetches text[]) RETURNS json
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
-- session driver: scans stay open across statements of one transaction
CREATE FUNCTION d2_open(idx regclass, opr regoperator, val text, index_only bool) RETURNS void
  AS 'MODULE_PATHNAME' LANGUAGE C;
CREATE FUNCTION d2_step(step text) RETURNS json
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
CREATE FUNCTION d2_close() RETURNS json
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
-- put the control layer (d2_ctl.fault) in front of idx for the rest of
-- the transaction (the executor's own scans), without the observer
CREATE FUNCTION d2_ctl_install(idx regclass) RETURNS void
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
