-- One D0 generator, three index AMs.  The AM name is data here only.
CREATE EXTENSION d0gen;

CREATE TABLE t_int AS
  SELECT CASE WHEN i % 50 = 0 THEN NULL ELSE i % 500 END::int4 AS a,
         CASE WHEN i % 3 = 0 THEN NULL ELSE i END::int4 AS b
  FROM generate_series(1, 3000) i;
CREATE TABLE t_rng AS
  SELECT CASE WHEN i % 50 = 0 THEN NULL
              WHEN i % 97 = 0 THEN 'empty'::int4range
              ELSE int4range(i % 400, i % 400 + 1 + i % 7) END AS a,
         CASE WHEN i % 3 = 0 THEN NULL ELSE int4range(i, i + 10) END AS b
  FROM generate_series(1, 3000) i;
ANALYZE t_int, t_rng;

CREATE TABLE runs(am text, tbl text, contract text, check_name text, status text, detail text);
INSERT INTO runs SELECT 'btree', 't_int', * FROM d0_check('t_int', 'a', 'btree', 'b');
INSERT INTO runs SELECT 'hash',  't_int', * FROM d0_check('t_int', 'a', 'hash', 'b');
INSERT INTO runs SELECT 'gist',  't_rng', * FROM d0_check('t_rng', 'a', 'gist', 'b');

-- summary: contract x status per AM
SELECT am, contract, status, count(*) FROM runs GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
-- everything that is not a plain pass / n/a / unresolved, except the
-- planner declining a parallel path
SELECT am, contract, check_name, status, detail FROM runs
WHERE status NOT IN ('pass', 'n/a', 'UNRESOLVED')
  AND NOT (contract = 'S13' AND status = 'empty')
ORDER BY 1, 2, 3;

-- The comparison can fail: an index that misses rows inserted while it
-- was not ready.  Same check, each AM.
CREATE TABLE t_stale(a int4);
INSERT INTO t_stale SELECT i FROM generate_series(1, 1000) i;
CREATE FUNCTION stale_check(am text) RETURNS TABLE(status text, detail text)
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('CREATE INDEX stale_%s ON t_stale USING %I (a)', am, am);
  UPDATE pg_index SET indisready = false WHERE indexrelid = format('stale_%s', am)::regclass;
  INSERT INTO t_stale SELECT 2000 + i FROM generate_series(1, 5) i;
  UPDATE pg_index SET indisready = true WHERE indexrelid = format('stale_%s', am)::regclass;
  RETURN QUERY SELECT c.status, regexp_replace(c.detail, '\([0-9]+,[0-9]+\)', '(b,o)', 'g')
    FROM d0_compare('SELECT ctid FROM t_stale WHERE a = 2003',
                    CASE WHEN pg_index_has_property(format('stale_%s', am)::regclass, 'index_scan')
                         THEN 'index' ELSE 'bitmap' END,
                    format('stale_%s', am)) c;
  EXECUTE format('DROP INDEX stale_%s', am);
  DELETE FROM t_stale WHERE a > 2000;
END $$;
SELECT 'btree' am, * FROM stale_check('btree')
UNION ALL SELECT 'hash', * FROM stale_check('hash');
