-- Control opclass: every law check must fail on its injected fault and
-- pass with fault = none.  btvalidate() accepts the opclass in all modes.
CREATE EXTENSION IF NOT EXISTS opclass_laws;
LOAD 'ctl_opclass';

CREATE FUNCTION ctl_cmp(int4, int4) RETURNS int4
  AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_lt(int4, int4) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_le(int4, int4) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_eq(int4, int4) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_ge(int4, int4) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_gt(int4, int4) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_sortsupport(internal) RETURNS void
  AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_equalimage(oid) RETURNS bool
  AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_inrange(int4, int4, int4, bool, bool) RETURNS bool
  AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_skipsupport(internal) RETURNS void
  AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;

CREATE OPERATOR #<  (LEFTARG = int4, RIGHTARG = int4, FUNCTION = ctl_lt);
CREATE OPERATOR #<= (LEFTARG = int4, RIGHTARG = int4, FUNCTION = ctl_le);
CREATE OPERATOR #=  (LEFTARG = int4, RIGHTARG = int4, FUNCTION = ctl_eq);
CREATE OPERATOR #>= (LEFTARG = int4, RIGHTARG = int4, FUNCTION = ctl_ge);
CREATE OPERATOR #>  (LEFTARG = int4, RIGHTARG = int4, FUNCTION = ctl_gt);

CREATE OPERATOR CLASS ctl_int4_ops FOR TYPE int4 USING btree AS
  OPERATOR 1 #<, OPERATOR 2 #<=, OPERATOR 3 #=, OPERATOR 4 #>=, OPERATOR 5 #>,
  FUNCTION 1 ctl_cmp(int4, int4),
  FUNCTION 2 ctl_sortsupport(internal),
  FUNCTION 3 (int4, int4) ctl_inrange(int4, int4, int4, bool, bool),
  FUNCTION 4 ctl_equalimage(oid),
  FUNCTION 6 ctl_skipsupport(internal);

-- the catalog-level validator has nothing to object to
SELECT amvalidate(oid) FROM pg_opclass WHERE opcname = 'ctl_int4_ops';

CREATE TABLE ctl_sample AS
  SELECT array_agg(x ORDER BY x) AS big,
         array_agg(x ORDER BY x) FILTER (WHERE x BETWEEN -5 AND 5) AS small
  FROM (SELECT generate_series(-5, 5) AS x
        UNION ALL VALUES (100), (101), (102), (-1000), (2500),
                         (1000000), (1000001), (1000002),
                         (2147483647), (-2147483648)) s;

-- baseline: all laws hold
SET ctl_opclass.fault = 'none';
SELECT law, status, detail FROM opclass_laws_check('ctl_int4_ops', (SELECT big FROM ctl_sample));
SELECT law, status, detail FROM opclass_laws_check_inrange('ctl_int4_ops', (SELECT small FROM ctl_sample), '{0,1,3}');

-- fault matrix: which laws fail under each injected fault
CREATE FUNCTION ctl_failed(f text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  PERFORM set_config('ctl_opclass.fault', f, false);
  SELECT string_agg(split_part(law, ' ', 1), ',' ORDER BY law) INTO r
  FROM (SELECT law, status FROM opclass_laws_check('ctl_int4_ops', (SELECT big FROM ctl_sample))
        UNION ALL
        SELECT law, status FROM opclass_laws_check_inrange('ctl_int4_ops', (SELECT small FROM ctl_sample), '{0,1,3}')) s
  WHERE status = 'FAIL';
  RETURN coalesce(r, '-');
END $$;

SELECT f AS fault, ctl_failed(f) AS failed_laws
FROM unnest(array['none', 'cmp_irreflexive', 'cmp_asymmetric', 'cmp_nontransitive',
                  'op_disagree', 'sortsupport', 'abbrev', 'equalimage',
                  'inrange', 'skip', 'skip_symmetric']) AS f;

-- counterexamples for the targeted law of each fault
SET ctl_opclass.fault = 'cmp_nontransitive';
SELECT law, detail FROM opclass_laws_check('ctl_int4_ops', (SELECT big FROM ctl_sample)) WHERE law LIKE 'O3%';
SET ctl_opclass.fault = 'equalimage';
SELECT law, detail FROM opclass_laws_check('ctl_int4_ops', (SELECT big FROM ctl_sample)) WHERE law LIKE 'O7%';
SET ctl_opclass.fault = 'abbrev';
SELECT law, detail FROM opclass_laws_check('ctl_int4_ops', (SELECT big FROM ctl_sample)) WHERE law LIKE 'O6%';
SET ctl_opclass.fault = 'inrange';
SELECT law, detail FROM opclass_laws_check_inrange('ctl_int4_ops', (SELECT small FROM ctl_sample), '{0,1,3}');
SET ctl_opclass.fault = 'skip';
SELECT law, detail FROM opclass_laws_check('ctl_int4_ops', (SELECT big FROM ctl_sample)) WHERE law LIKE 'O9%';
-- dec(inc(a)) = a holds here; only the skipped-over value shows the fault
SET ctl_opclass.fault = 'skip_symmetric';
SELECT law, detail FROM opclass_laws_check('ctl_int4_ops', (SELECT big FROM ctl_sample)) WHERE law LIKE 'O9%';
RESET ctl_opclass.fault;
