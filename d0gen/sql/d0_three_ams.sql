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

-- Negative examples: every check below must FAIL.  They call the same
-- functions d0_check uses, on deliberately wrong input.

-- An index made stale: rows inserted while indisready = false are missing
-- from it.  Test harness only (catalog update needs superuser).
CREATE FUNCTION make_stale(idx regclass, ins text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE pg_index SET indisready = false WHERE indexrelid = idx;
  EXECUTE ins;
  UPDATE pg_index SET indisready = true WHERE indexrelid = idx;
END $$;

-- S1-ext/S9-ext comparison, all three AMs
CREATE TABLE t_stale(a int4);
INSERT INTO t_stale SELECT i FROM generate_series(1, 1000) i;
CREATE TABLE t_stale_r(a int4range);
INSERT INTO t_stale_r SELECT int4range(i, i + 1) FROM generate_series(1, 1000) i;
CREATE FUNCTION stale_compare(am text, tbl text, ins text, q text)
RETURNS TABLE(status text, detail text)
LANGUAGE plpgsql AS $$
DECLARE
  idx text := format('stale_%s', am);
BEGIN
  EXECUTE format('CREATE INDEX %I ON %s USING %I (a)', idx, tbl, am);
  PERFORM make_stale(idx::regclass, ins);
  RETURN QUERY SELECT c.status, regexp_replace(c.detail, '\([0-9]+,[0-9]+\)', '(b,o)', 'g')
    FROM d0_compare(q, CASE WHEN pg_index_has_property(idx::regclass, 'index_scan')
                            THEN 'index' ELSE 'bitmap' END, idx) c;
  EXECUTE format('DROP INDEX %I', idx);
END $$;
SELECT 'btree' am, * FROM stale_compare('btree', 't_stale',
  'INSERT INTO t_stale VALUES (2003)', 'SELECT ctid FROM t_stale WHERE a = 2003')
UNION ALL
SELECT 'hash', * FROM stale_compare('hash', 't_stale',
  'INSERT INTO t_stale VALUES (2004)', 'SELECT ctid FROM t_stale WHERE a = 2004')
UNION ALL
SELECT 'gist', * FROM stale_compare('gist', 't_stale_r',
  'INSERT INTO t_stale_r VALUES (''[2003,2004)'')', 'SELECT ctid FROM t_stale_r WHERE a && ''[2003,2004)''');

-- A6: NULL rows missing from the index
CREATE TABLE t_nulls(a int4);
INSERT INTO t_nulls SELECT CASE WHEN i % 10 = 0 THEN NULL ELSE i END FROM generate_series(1, 1000) i;
CREATE INDEX t_nulls_a ON t_nulls USING btree (a);
SELECT make_stale('t_nulls_a', 'INSERT INTO t_nulls SELECT NULL FROM generate_series(1, 5)');
VACUUM (ANALYZE) t_nulls;
SELECT * FROM d0_check_nulls_indexed('t_nulls', 'a', 't_nulls_a');

-- A9: the unique index missed a key, so a duplicate of it gets in
CREATE TABLE t_uniq(k int4);
INSERT INTO t_uniq SELECT i FROM generate_series(1, 100) i;
CREATE UNIQUE INDEX t_uniq_k ON t_uniq USING btree (k);
SELECT make_stale('t_uniq_k', 'INSERT INTO t_uniq VALUES (500)');
SELECT * FROM d0_check_unique('t_uniq', 'k', '500');
-- ... and the reinsert branch: a delete that removes nothing (trigger)
-- leaves the key in place, so re-inserting it must be reported
CREATE TABLE t_uniq2(k int4 UNIQUE);
INSERT INTO t_uniq2 SELECT i FROM generate_series(1, 10) i;
CREATE FUNCTION keep_row() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$;
CREATE TRIGGER t_uniq2_keep BEFORE DELETE ON t_uniq2 FOR EACH ROW EXECUTE FUNCTION keep_row();
SELECT * FROM d0_check_unique('t_uniq2', 'k', '5');

-- S3: an order that is not monotone in the reference sort
SELECT * FROM d0_order_ok('t_int', 'a', 'ASC',
  (SELECT array_agg(ctid ORDER BY a DESC NULLS LAST, ctid) FROM t_int));
SELECT * FROM d0_order_ok('t_int', 'a', 'DESC',
  (SELECT array_agg(ctid ORDER BY a ASC NULLS FIRST, ctid) FROM t_int));

-- The reference guard: the seq path must not read the index, the index path must.
CREATE INDEX t_stale_a ON t_stale USING btree (a);
SELECT d0_plan_reads('SELECT ctid FROM t_stale WHERE a = 5', 'seq', 't_stale_a') AS seq_reads_index,
       d0_plan_reads('SELECT ctid FROM t_stale WHERE a = 5', 'index', 't_stale_a') AS index_reads_index;
