-- Sample limits, collation resolution, cancellation.
CREATE EXTENSION IF NOT EXISTS opclass_laws;

-- only the first max_n values are used, and that is reported
SELECT law, status, checked, detail FROM opclass_laws_check('int4_ops',
  '{5,4,3,2,1,0,-1,-2,-3,-4}'::int4[], max_n => 3, max_triple_n => 2)
WHERE law ~ '^O[123] ';
SELECT * FROM opclass_laws_check('int4_ops', '{1}'::int4[], max_n => 0);

-- two different implicit collations: refuse rather than use the default
CREATE TEMP TABLE lt(opc text COLLATE "en-x-icu", arr text[] COLLATE "C");
INSERT INTO lt VALUES ('text_ops', '{a,B}');
SELECT law FROM lt, opclass_laws_check(opc, arr);
-- an explicit collation resolves it
SELECT law, status FROM lt, opclass_laws_check(opc, arr COLLATE "C") WHERE law LIKE 'O1%';

-- the loops are cancellable: the full run takes tens of seconds; the
-- cancel must land inside the loops, not after the function returns
SET statement_timeout = '200ms';
DO $$
DECLARE
  t0 timestamptz := clock_timestamp();
BEGIN
  PERFORM count(*) FROM opclass_laws_check('int4_ops',
    (SELECT array_agg(g) FROM generate_series(1, 20000) g), max_n => 20000);
  RAISE NOTICE 'not cancelled';
EXCEPTION WHEN query_canceled THEN
  RAISE NOTICE 'cancelled within 5s: %', clock_timestamp() - t0 < interval '5s';
END $$;
RESET statement_timeout;
