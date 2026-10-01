-- D1: one law engine + role tables, three index AMs.
CREATE EXTENSION d1laws;
\ir role_tables.sql
CREATE COLLATION ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);

CREATE TABLE samp AS SELECT
  '{-2147483648,-5,-1,0,1,2,3,100,1000,2147483647}'::int4[] AS i4,
  '{a,A,b,B,Straße,STRASSE,strasse,e,"",1}'::text[] AS txt,
  '{-1,0,0.0,1,1.0,1.00,2.5,NaN,Infinity,-Infinity}'::numeric[] AS num,
  '{-infinity,2000-02-28,2000-02-29,2000-03-01,2000-03-31,infinity}'::date[] AS dt,
  ARRAY['((0,0),(4,0),(0,4))', '((4,4),(1,4),(4,1))', '((10,10),(12,10),(10,12))',
        '((0,0),(1,0),(0,1))', '((2,2),(3,2),(3,3),(2,3))', '((-3,-3),(-1,-3),(-3,-1))']::polygon[] AS poly;

-- built-in opclasses: roles resolved, values, status
SELECT 'btree int4' c, law, kind, status, checked, roles, detail FROM samp, d1_check('int4_ops', 'btree', i4);
SELECT 'btree text C' c, law, kind, status, checked, detail FROM samp, d1_check('text_ops', 'btree', (SELECT array_agg(t COLLATE "C") FROM unnest(txt) t));
SELECT 'btree text ci' c, law, kind, status, checked, detail FROM samp, d1_check('text_ops', 'btree', (SELECT array_agg(t COLLATE ci) FROM unnest(txt) t));
SELECT 'btree numeric' c, law, kind, status, checked, detail FROM samp, d1_check('numeric_ops', 'btree', num);
SELECT 'btree date' c, law, kind, status, checked, detail FROM samp, d1_check('date_ops', 'btree', dt);
SELECT 'hash int4' c, law, kind, status, checked, roles, detail FROM samp, d1_check('int4_ops', 'hash', i4);
SELECT 'hash text ci' c, law, kind, status, checked, detail FROM samp, d1_check('text_ops', 'hash', (SELECT array_agg(t COLLATE ci) FROM unnest(txt) t));
SELECT 'gist poly' c, law, kind, status, checked, roles, detail FROM samp, d1_check('poly_ops', 'gist', poly);

-- Same laws through the btree-specific checker (opclass_laws): the
-- generic engine + btree role table must agree law by law.
CREATE EXTENSION opclass_laws;
CREATE FUNCTION agree(opc text, s anyarray) RETURNS TABLE(law text, d1 text, specific text, same bool)
LANGUAGE sql AS $$
  WITH a AS (SELECT d.law, string_agg(d.status, ',' ORDER BY d.status) st FROM d1_check(opc, 'btree', s) d
             WHERE d.law <> 'O8' GROUP BY 1),
       b AS (SELECT split_part(o.law, ' ', 1) law, string_agg(o.status, ',' ORDER BY o.status) st
             FROM opclass_laws_check(opc, s) o GROUP BY 1)
  SELECT a.law, a.st, b.st, a.st = b.st FROM a FULL JOIN b USING (law) ORDER BY 1
$$;
SELECT 'int4' c, a.* FROM samp, agree('int4_ops', i4) a;
SELECT 'text C' c, a.* FROM samp, agree('text_ops', (SELECT array_agg(t COLLATE "C") FROM unnest(txt) t)) a;
SELECT 'text ci' c, a.* FROM samp, agree('text_ops', (SELECT array_agg(t COLLATE ci) FROM unnest(txt) t)) a;
SELECT 'numeric' c, a.* FROM samp, agree('numeric_ops', num) a;
SELECT 'date' c, a.* FROM samp, agree('date_ops', dt) a;

-- Controls.  One fault changes one relation; the table shows which laws fail.

-- btree: the opclass_laws control opclass (ctl_opclass.so), one fault per law
LOAD 'ctl_opclass';
CREATE FUNCTION ctl_cmp(int4, int4) RETURNS int4 AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_lt(int4, int4) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_le(int4, int4) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_eq(int4, int4) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_ge(int4, int4) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_gt(int4, int4) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_sortsupport(internal) RETURNS void AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_equalimage(oid) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_inrange(int4, int4, int4, bool, bool) RETURNS bool AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION ctl_skipsupport(internal) RETURNS void AS '$libdir/ctl_opclass' LANGUAGE C IMMUTABLE STRICT;
CREATE OPERATOR #<  (LEFTARG = int4, RIGHTARG = int4, FUNCTION = ctl_lt);
CREATE OPERATOR #<= (LEFTARG = int4, RIGHTARG = int4, FUNCTION = ctl_le);
CREATE OPERATOR #=  (LEFTARG = int4, RIGHTARG = int4, FUNCTION = ctl_eq);
CREATE OPERATOR #>= (LEFTARG = int4, RIGHTARG = int4, FUNCTION = ctl_ge);
CREATE OPERATOR #>  (LEFTARG = int4, RIGHTARG = int4, FUNCTION = ctl_gt);
CREATE OPERATOR CLASS ctl_int4_ops FOR TYPE int4 USING btree AS
  OPERATOR 1 #<, OPERATOR 2 #<=, OPERATOR 3 #=, OPERATOR 4 #>=, OPERATOR 5 #>,
  FUNCTION 1 ctl_cmp(int4, int4), FUNCTION 2 ctl_sortsupport(internal),
  FUNCTION 3 (int4, int4) ctl_inrange(int4, int4, int4, bool, bool),
  FUNCTION 4 ctl_equalimage(oid), FUNCTION 6 ctl_skipsupport(internal);
CREATE TABLE ctl_samp AS SELECT '{-5,-4,-3,-2,-1,0,1,2,3,4,5,100,1000000,1000001,1000002,-1000,2500}'::int4[] AS v;

-- set the fault, then run: the order is explicit
CREATE FUNCTION failed_under(guc text, f text, opc text, am text, s anyarray) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config(guc, f, false);
  RETURN (SELECT coalesce(string_agg(DISTINCT law, ',' ORDER BY law), '-') FROM d1_check(opc, am, s) WHERE status = 'FAIL');
END $$;
CREATE FUNCTION specific_failed_under(f text, opc text, s int4[]) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('ctl_opclass.fault', f, false);
  RETURN (SELECT coalesce(string_agg(DISTINCT split_part(law, ' ', 1), ',' ORDER BY split_part(law, ' ', 1)), '-')
          FROM (SELECT law, status FROM opclass_laws_check(opc, s)
                UNION ALL SELECT law, status FROM opclass_laws_check_inrange(opc, s[1:11], '{0,1,3}')) o
          WHERE status = 'FAIL');
END $$;
SELECT f AS fault, failed_under('ctl_opclass.fault', f, 'ctl_int4_ops', 'btree', v) AS d1_failed,
       specific_failed_under(f, 'ctl_int4_ops', v) AS specific_failed
FROM ctl_samp, unnest(array['none', 'cmp_irreflexive', 'cmp_asymmetric', 'cmp_nontransitive', 'op_disagree',
                            'sortsupport', 'abbrev', 'equalimage', 'inrange', 'skip', 'skip_symmetric']) f;
RESET ctl_opclass.fault;

-- hash: equality "equal mod 1000", hash and extended hash of the residue
LOAD 'd1_ctl';
CREATE FUNCTION d1ctl_eq(int4, int4) RETURNS bool AS '$libdir/d1_ctl' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION d1ctl_hash(int4) RETURNS int4 AS '$libdir/d1_ctl' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION d1ctl_hashext(int4, int8) RETURNS int8 AS '$libdir/d1_ctl' LANGUAGE C IMMUTABLE STRICT;
CREATE OPERATOR #==# (LEFTARG = int4, RIGHTARG = int4, FUNCTION = d1ctl_eq);
CREATE OPERATOR CLASS ctl_hash_int4_ops FOR TYPE int4 USING hash AS
  OPERATOR 1 #==#, FUNCTION 1 d1ctl_hash(int4), FUNCTION 2 d1ctl_hashext(int4, int8);
SELECT f AS fault, failed_under('d1_ctl.fault', f, 'ctl_hash_int4_ops', 'hash', '{1,1001,2,2002,3,-997,999,5,6,7}'::int4[]) AS d1_failed
FROM unnest(array['none', 'eq_nontransitive', 'hash_congruence', 'hash_extended']) f;
RESET d1_ctl.fault;

-- btree K5: each half of in_range monotonicity has its own control
CREATE FUNCTION d1ctl_inrange(int4, int4, int4, bool, bool) RETURNS bool AS '$libdir/d1_ctl' LANGUAGE C IMMUTABLE STRICT;
CREATE OPERATOR CLASS ir_int4_ops FOR TYPE int4 USING btree AS
  OPERATOR 1 <, OPERATOR 2 <=, OPERATOR 3 =, OPERATOR 4 >=, OPERATOR 5 >,
  FUNCTION 1 btint4cmp(int4, int4), FUNCTION 3 (int4, int4) d1ctl_inrange(int4, int4, int4, bool, bool);
CREATE FUNCTION k5_under(f text) RETURNS TABLE(half text, status text, checked bigint, detail text)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('d1_ctl.fault', f, false);
  RETURN QUERY SELECT substring(d.roles from '\[(val|base)\]$'), d.status, d.checked, d.detail
    FROM d1_check('ir_int4_ops', 'btree', '{-1,0,1,2,3,4,5,10}'::int4[]) d WHERE d.law = 'O8';
END $$;
SELECT 'none' fault, k.* FROM k5_under('none') k;
SELECT 'inrange_val' fault, k.* FROM k5_under('inrange_val') k;
SELECT 'inrange_base' fault, k.* FROM k5_under('inrange_base') k;
RESET d1_ctl.fault;

-- GiST: a polygon family whose consistent wraps gist_poly_consistent.  The
-- role table is per family, so the family gets its own rows.
CREATE FUNCTION d1ctl_poly_consistent(internal, polygon, int2, oid, internal) RETURNS bool
  AS '$libdir/d1_ctl' LANGUAGE C IMMUTABLE STRICT;
CREATE OPERATOR CLASS ctl_poly_ops FOR TYPE polygon USING gist AS
  OPERATOR 1 <<, OPERATOR 2 &<, OPERATOR 3 &&, OPERATOR 4 &>, OPERATOR 5 >>, OPERATOR 6 ~=,
  OPERATOR 7 @>, OPERATOR 8 <@, OPERATOR 9 &<|, OPERATOR 10 <<|, OPERATOR 11 |>>, OPERATOR 12 |&>,
  FUNCTION 1 d1ctl_poly_consistent(internal, polygon, int2, oid, internal),
  FUNCTION 3 gist_poly_compress(internal);
INSERT INTO d1_role (am, family, role, source, number, protocol, attr, righttype)
  SELECT am, 'ctl_poly_ops', role, source, number, protocol, attr, righttype FROM d1_role WHERE family = 'poly_ops';
INSERT INTO d1_law SELECT am, 'ctl_poly_ops', law, kind, params FROM d1_law WHERE family = 'poly_ops';
CREATE FUNCTION check_under(f text, opc text, am text, s anyarray) RETURNS TABLE(law text, status text, detail text)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('d1_ctl.fault', f, false);
  RETURN QUERY SELECT d.law, d.status, d.detail FROM d1_check(opc, am, s) d;
END $$;
SELECT 'none' fault, k.* FROM samp, check_under('none', 'ctl_poly_ops', 'gist', poly) k;
SELECT 'consistent_exact' fault, k.* FROM samp, check_under('consistent_exact', 'ctl_poly_ops', 'gist', poly) k;
RESET d1_ctl.fault;

-- GIN: triConsistent through the same K3.  The sample is queries (tsquery);
-- each check vector over the query's keys, every completion of it, both strategies.
CREATE TABLE gin_samp AS SELECT
  '{a,"a & b","a | b","!a","a & !b","(a | b) & !c","a <-> b","a:A & b","a & !a","a | (b & !c) | d"}'::tsquery[] AS q;
SELECT 'gin tsvector' c, law, kind, status, checked, roles, detail FROM gin_samp, d1_check('tsvector_ops', 'gin', q);

-- control: triConsistent answers TRUE where the real one says MAYBE
CREATE FUNCTION d1ctl_tri(internal, int2, tsquery, int4, internal, internal, internal) RETURNS "char"
  AS '$libdir/d1_ctl' LANGUAGE C IMMUTABLE STRICT;
CREATE OPERATOR CLASS ctl_tsvector_ops FOR TYPE tsvector USING gin AS
  OPERATOR 1 @@ (tsvector, tsquery), OPERATOR 2 @@@ (tsvector, tsquery),
  FUNCTION 1 gin_cmp_tslexeme(text, text),
  FUNCTION 2 gin_extract_tsvector(tsvector, internal, internal),
  FUNCTION 3 gin_extract_tsquery(tsquery, internal, int2, internal, internal, internal, internal),
  FUNCTION 4 gin_tsquery_consistent(internal, int2, tsquery, int4, internal, internal, internal, internal),
  FUNCTION 6 d1ctl_tri(internal, int2, tsquery, int4, internal, internal, internal),
  STORAGE text;
SELECT 'none' fault, k.* FROM gin_samp, check_under('none', 'ctl_tsvector_ops', 'gin', q) k;
SELECT 'tri_overconfident' fault, k.* FROM gin_samp, check_under('tri_overconfident', 'ctl_tsvector_ops', 'gin', q) k;
-- only an uncertain reference (consistent: true with recheck) can expose this one
SELECT 'tri_exact_claim' fault, k.* FROM gin_samp, check_under('tri_exact_claim', 'ctl_tsvector_ops', 'gin', q) k;
-- answer agrees with the first completion of the input (every M read as F),
-- not with the others: only a check of every completion exposes it
SELECT 'tri_first_completion' fault, k.* FROM gin_samp, check_under('tri_first_completion', 'ctl_tsvector_ops', 'gin', q) k;
RESET d1_ctl.fault;

-- A role this opclass does not provide: n/a, not FAIL
CREATE OPERATOR CLASS bare_int4_ops FOR TYPE int4 USING btree AS
  OPERATOR 1 <, OPERATOR 2 <=, OPERATOR 3 =, OPERATOR 4 >=, OPERATOR 5 >, FUNCTION 1 btint4cmp(int4, int4);
SELECT law, status, detail FROM samp, d1_check('bare_int4_ops', 'btree', i4);
