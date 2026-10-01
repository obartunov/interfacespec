\echo Use "CREATE EXTENSION d1laws" to load this file. \quit

-- D1 generic law engine.  Law kinds K1-K6 are written in terms of roles.
-- Which support function or strategy plays a role, and by which calling
-- protocol, lives only in d1_role (data, loaded separately).  This file
-- must name no index AM and no support/strategy number.

CREATE TYPE d1_approx AS (answer int, flag bool);

-- invocation by OID with the caller's collation
CREATE FUNCTION d1_invoke_int8(fn oid, VARIADIC "any") RETURNS int8
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
CREATE FUNCTION d1_invoke_bool(fn oid, VARIADIC "any") RETURNS bool
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
CREATE FUNCTION d1_invoke_guard(fn oid, collation_carrier anyelement, VARIADIC "any") RETURNS bool
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
CREATE FUNCTION d1_image_eq(anyelement, anyelement) RETURNS bool
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
-- protocol adapters (calling conventions of internal-typed support functions)
CREATE FUNCTION d1_sortsupport_cmp(proc oid, a anyelement, b anyelement) RETURNS int4
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
CREATE FUNCTION d1_abbrev_cmp(proc oid, aux oid, x anyelement, q "any", strategy int, subtype oid)
  RETURNS d1_approx AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
CREATE FUNCTION d1_entry_consistent(proc oid, aux oid, x anyelement, q "any", strategy int, subtype oid)
  RETURNS d1_approx AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
CREATE FUNCTION d1_skip_bound(proc oid, sample anyelement, which text) RETURNS anyelement
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
CREATE FUNCTION d1_skip_step(proc oid, a anyelement, dir text) RETURNS anyelement
  AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

-- Role vocabulary: shape of each role (what it returns / how it is used).
CREATE TABLE d1_role_vocab (role text PRIMARY KEY, shape text NOT NULL);
INSERT INTO d1_role_vocab VALUES
  ('comparator', 'cmp'), ('alternate_comparator', 'cmp'),
  ('equality', 'rel'), ('ordering_operator', 'rel'), ('reference_predicate', 'rel'),
  ('approximate_comparator', 'approx'), ('consistent', 'approx'),
  ('image_equivalence', 'guard'), ('range_predicate', 'range'),
  ('successor', 'succ'), ('hash', 'value'), ('extended_hash', 'value'),
  ('entry_transform', 'transform');

-- Protocol x operation -> SQL-callable function implementing the call.
CREATE TABLE d1_protocol (protocol text, operation text, func text,
                          PRIMARY KEY (protocol, operation));
INSERT INTO d1_protocol VALUES
  ('plain', 'cmp', 'd1_invoke_int8'), ('plain', 'value', 'd1_invoke_int8'),
  ('plain', 'rel', 'd1_invoke_bool'), ('plain', 'guard', 'd1_invoke_guard'),
  ('plain', 'range', 'd1_invoke_bool'), ('plain', 'transform', NULL),
  ('sortsupport', 'cmp', 'd1_sortsupport_cmp'),
  ('abbrev', 'approx', 'd1_abbrev_cmp'),
  ('entry_consistent', 'approx', 'd1_entry_consistent'),
  ('skipsupport', 'bound', 'd1_skip_bound'), ('skipsupport', 'step', 'd1_skip_step');

-- Role table: filled per AM (family NULL) or per operator family.
-- source 'proc': support function number; 'op': strategy number, or NULL
-- for every search operator of the family.  righttype: 'same' as the
-- opclass input type, or 'any'.
CREATE TABLE d1_role (am text NOT NULL, family text, role text NOT NULL REFERENCES d1_role_vocab,
                      source text NOT NULL CHECK (source IN ('proc', 'op')), number int,
                      protocol text NOT NULL DEFAULT 'plain', attr text,
                      righttype text NOT NULL DEFAULT 'same');

-- Law instances: kind + roles + parameters.
CREATE TABLE d1_law (am text NOT NULL, family text, law text NOT NULL,
                     kind text NOT NULL CHECK (kind IN ('K1','K2','K3','K4','K5','K6')),
                     params jsonb NOT NULL);

-- Resolve a role for an operator family and input type through the catalog.
CREATE FUNCTION d1_resolve(fam oid, typ oid, rolename text)
RETURNS TABLE(fn oid, protocol text, attr text, strategy int, subtype oid)
LANGUAGE sql STABLE AS $$
  SELECT CASE r.source WHEN 'proc' THEN p.amproc::oid ELSE o.oprcode::oid END,
         r.protocol, r.attr, coalesce(a.amopstrategy, 0)::int,
         coalesce(p.amprocrighttype, a.amoprighttype, 0)
  FROM d1_role r
  JOIN pg_opfamily f ON f.oid = fam
  JOIN pg_am m ON m.oid = f.opfmethod AND m.amname = r.am
  LEFT JOIN pg_amproc p ON r.source = 'proc' AND p.amprocfamily = fam
       AND p.amproclefttype = typ AND p.amprocnum = r.number
       AND (r.righttype = 'any' OR p.amprocrighttype = typ)
  LEFT JOIN pg_amop a ON r.source = 'op' AND a.amopfamily = fam AND a.amoppurpose = 's'
       AND a.amoplefttype = typ AND a.amoprighttype = typ
       AND (r.number IS NULL OR a.amopstrategy = r.number)
  LEFT JOIN pg_operator o ON o.oid = a.amopopr
  WHERE r.role = rolename AND (r.family IS NULL OR r.family = f.opfname)
    AND coalesce(p.amproc::oid, o.oprcode::oid) IS NOT NULL
  ORDER BY 4, 5
$$;

-- SQL text calling a resolved role: func(fn, args)
CREATE FUNCTION d1_call(protocol text, operation text, fn oid, args text) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  f text := (SELECT func FROM d1_protocol p WHERE p.protocol = d1_call.protocol AND p.operation = d1_call.operation);
BEGIN
  IF f IS NULL THEN
    RAISE EXCEPTION 'no % call for protocol %', operation, protocol;
  END IF;
  RETURN format('%s(%s::oid, %s)', f, fn, args);
END $$;

-- cmp-shaped role applied to (x, y), as sign
CREATE FUNCTION d1_cmp(r record, x text, y text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  RETURN format('sign(%s)::int', d1_call(r.protocol, 'cmp', r.fn, x || ', ' || y));
END $$;

-- Evaluate: every row of FROM must satisfy ok; returns count and one counterexample.
CREATE FUNCTION d1_eval(from_ text, ok text, show text, OUT checked bigint, OUT bad text)
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('SELECT count(*), (array_agg(%s) FILTER (WHERE NOT coalesce(%s, false)))[1] FROM %s',
                 show, ok, from_) INTO checked, bad;
END $$;

CREATE TYPE d1_out AS (roles text, status text, checked bigint, detail text);

CREATE FUNCTION d1_verdict(roles text, checked bigint, bad text) RETURNS d1_out
LANGUAGE sql IMMUTABLE AS $$
  SELECT (roles, CASE WHEN bad IS NOT NULL THEN 'FAIL' WHEN checked = 0 THEN 'empty' ELSE 'pass' END,
          checked, bad)::d1_out
$$;

CREATE FUNCTION d1_absent(role text) RETURNS d1_out LANGUAGE sql IMMUTABLE AS $$
  SELECT (format('%s: absent', role), 'n/a', 0::bigint, format('role %s not provided by this opclass', role))::d1_out
$$;

-- K1: property of a relation (cmp: reflexive/antisymmetric/transitive;
--     rel: reflexive/symmetric/transitive)
CREATE FUNCTION d1_k1(fam oid, typ oid, p jsonb) RETURNS d1_out LANGUAGE plpgsql AS $$
DECLARE
  r record;
  shape text := (SELECT shape FROM d1_role_vocab WHERE role = p->>'role');
  prop text := p->>'property';
  e record;
  c_ab text; c_ba text; c_bc text; c_ac text; c_aa text;
BEGIN
  SELECT * INTO r FROM d1_resolve(fam, typ, p->>'role') LIMIT 1;
  IF NOT FOUND THEN RETURN d1_absent(p->>'role'); END IF;
  IF shape = 'cmp' THEN
    c_aa := d1_cmp(r, 'a.v', 'a.v'); c_ab := d1_cmp(r, 'a.v', 'b.v'); c_ba := d1_cmp(r, 'b.v', 'a.v');
    c_bc := d1_cmp(r, 'b.v', 'c.v'); c_ac := d1_cmp(r, 'a.v', 'c.v');
    e := CASE prop
      WHEN 'reflexive' THEN d1_eval('d1_s a', c_aa || ' = 0', 'a.v::text')
      WHEN 'antisymmetric' THEN d1_eval('d1_s a, d1_s b WHERE a.i < b.i', format('%s = -%s', c_ab, c_ba), $x$format('a=%s b=%s', a.v, b.v)$x$)
      WHEN 'transitive' THEN d1_eval('d1_s a, d1_s b, d1_s c',
             format('NOT (%s <= 0 AND %s <= 0) OR %s <= 0', c_ab, c_bc, c_ac), $x$format('a=%s b=%s c=%s', a.v, b.v, c.v)$x$)
    END;
  ELSE
    c_aa := d1_call(r.protocol, 'rel', r.fn, 'a.v, a.v'); c_ab := d1_call(r.protocol, 'rel', r.fn, 'a.v, b.v');
    c_ba := d1_call(r.protocol, 'rel', r.fn, 'b.v, a.v'); c_bc := d1_call(r.protocol, 'rel', r.fn, 'b.v, c.v');
    c_ac := d1_call(r.protocol, 'rel', r.fn, 'a.v, c.v');
    e := CASE prop
      WHEN 'reflexive' THEN d1_eval('d1_s a', c_aa, 'a.v::text')
      WHEN 'symmetric' THEN d1_eval('d1_s a, d1_s b WHERE a.i < b.i', format('%s = %s', c_ab, c_ba), $x$format('a=%s b=%s', a.v, b.v)$x$)
      WHEN 'transitive' THEN d1_eval('d1_s a, d1_s b, d1_s c',
             format('NOT (%s AND %s) OR %s', c_ab, c_bc, c_ac), $x$format('a=%s b=%s c=%s', a.v, b.v, c.v)$x$)
    END;
  END IF;
  RETURN d1_verdict(format('%s -> %s', p->>'role', r.fn::regproc), e.checked, e.bad);
END $$;

-- K2: two implementations agree.
--   sign_matches_relation: cmp role A, rel roles B with attr lt/le/eq/ge/gt
--   same_sign: cmp roles A and B
--   low32_equal: value roles A(x) and B(x, seed)
CREATE FUNCTION d1_k2(fam oid, typ oid, p jsonb) RETURNS d1_out LANGUAGE plpgsql AS $$
DECLARE
  a record; b record;
  e record;
  checked bigint := 0; bad text; roles text;
  signop text;
BEGIN
  SELECT * INTO a FROM d1_resolve(fam, typ, p->>'a') LIMIT 1;
  IF NOT FOUND THEN RETURN d1_absent(p->>'a'); END IF;
  IF NOT EXISTS (SELECT 1 FROM d1_resolve(fam, typ, p->>'b')) THEN RETURN d1_absent(p->>'b'); END IF;
  roles := format('%s -> %s', p->>'a', a.fn::regproc);
  FOR b IN SELECT * FROM d1_resolve(fam, typ, p->>'b') LOOP
    roles := roles || format('; %s%s -> %s', p->>'b', coalesce('(' || b.attr || ')', ''), b.fn::regproc);
    CASE p->>'relation'
    WHEN 'sign_matches_relation' THEN
      signop := CASE b.attr WHEN 'lt' THEN '<' WHEN 'le' THEN '<=' WHEN 'eq' THEN '='
                            WHEN 'ge' THEN '>=' WHEN 'gt' THEN '>' END;
      e := d1_eval('d1_s x, d1_s y',
             format('%s = (%s %s 0)', d1_call(b.protocol, 'rel', b.fn, 'x.v, y.v'), d1_cmp(a, 'x.v', 'y.v'), signop),
             format($x$format('%s: x=%%s y=%%s', x.v, y.v)$x$, b.attr));
    WHEN 'same_sign' THEN
      e := d1_eval('d1_s x, d1_s y', format('%s = %s', d1_cmp(a, 'x.v', 'y.v'), d1_cmp(b, 'x.v', 'y.v')),
                   $x$format('x=%s y=%s', x.v, y.v)$x$);
    WHEN 'low32_equal' THEN
      e := d1_eval('d1_s x',
             format('(%s & 4294967295) = (%s & 4294967295)',
                    d1_call(a.protocol, 'value', a.fn, 'x.v'),
                    d1_call(b.protocol, 'value', b.fn, format('x.v, %s::int8', (p->>'seed')::int8))),
             'x.v::text');
    END CASE;
    checked := checked + e.checked;
    bad := coalesce(bad, e.bad);
  END LOOP;
  RETURN d1_verdict(roles, checked, bad);
END $$;

-- K3: one-sided approximation.  approx(x, q) -> (answer, flag); when the
-- answer is trusted it must equal the reference (sign for cmp, 0/1 for rel).
--   trusted: nonzero_answer | false_or_exact (answer = 0 or flag = false)
CREATE FUNCTION d1_k3(fam oid, typ oid, p jsonb) RETURNS d1_out LANGUAGE plpgsql AS $$
DECLARE
  ap record; aux record; ref record;
  refshape text := (SELECT shape FROM d1_role_vocab WHERE role = p->>'reference');
  trusted text := CASE p->>'trusted' WHEN 'nonzero_answer' THEN '(z.a).answer <> 0'
                                     WHEN 'false_or_exact' THEN '((z.a).answer = 0 OR NOT (z.a).flag)' END;
  auxfn oid := 0;
  e record;
  checked bigint := 0; bad text; ntrusted bigint := 0; n bigint; nt bigint;
  roles text;
  refexpr text;
  declined bool;
BEGIN
  SELECT * INTO ap FROM d1_resolve(fam, typ, p->>'approx') LIMIT 1;
  IF NOT FOUND THEN RETURN d1_absent(p->>'approx'); END IF;
  IF NOT EXISTS (SELECT 1 FROM d1_resolve(fam, typ, p->>'reference')) THEN RETURN d1_absent(p->>'reference'); END IF;
  roles := format('%s -> %s [%s]', p->>'approx', ap.fn::regproc, ap.protocol);
  IF p ? 'aux' THEN
    SELECT * INTO aux FROM d1_resolve(fam, typ, p->>'aux') LIMIT 1;
    IF FOUND THEN auxfn := aux.fn; roles := roles || format('; %s -> %s', p->>'aux', aux.fn::regproc); END IF;
  END IF;
  FOR ref IN SELECT * FROM d1_resolve(fam, typ, p->>'reference') LOOP
    refexpr := CASE refshape WHEN 'cmp' THEN d1_cmp(ref, 'x.v', 'q.v')
                             ELSE format('(%s)::int', d1_call(ref.protocol, 'rel', ref.fn, 'x.v, q.v')) END;
    EXECUTE format('SELECT bool_and(a IS NULL) FROM (SELECT %s a FROM d1_s x, d1_s q LIMIT 1) s',
                   d1_call(ap.protocol, 'approx', ap.fn, format('%s::oid, x.v, q.v, %s, %s::oid', auxfn, ref.strategy, ref.subtype)))
      INTO declined;
    IF declined THEN
      RETURN (roles, 'n/a', 0::bigint, 'approximation declined by the opclass')::d1_out;
    END IF;
    EXECUTE format($q$
      SELECT count(*), count(*) FILTER (WHERE %1$s),
             (array_agg(format('strategy %4$s: x=%%s q=%%s answer=%%s flag=%%s reference=%%s', x, q, (z.a).answer, (z.a).flag, ref))
                FILTER (WHERE %1$s AND (z.a).answer <> ref))[1]
      FROM (SELECT x.v x, q.v q, %2$s a, %3$s ref FROM d1_s x, d1_s q) z$q$,
      trusted,
      d1_call(ap.protocol, 'approx', ap.fn, format('%s::oid, x.v, q.v, %s, %s::oid', auxfn, ref.strategy, ref.subtype)),
      refexpr, ref.strategy)
      INTO n, nt, bad;
    checked := checked + n;
    ntrusted := ntrusted + nt;
    IF bad IS NOT NULL THEN EXIT; END IF;
    IF refshape = 'rel' THEN roles := roles || format('; %s(%s)', p->>'reference', ref.strategy); END IF;
  END LOOP;
  RETURN (roles, CASE WHEN bad IS NOT NULL THEN 'FAIL' WHEN ntrusted = 0 THEN 'empty' ELSE 'pass' END,
          checked, coalesce(bad, format('%s trusted of %s', ntrusted, checked)))::d1_out;
END $$;

-- K4: congruence.  premise(x, y) => consequence(x, y); optionally iff.
--   premise: a cmp role (= 0) or a rel role
--   consequence: 'image' (datum image equality) or a value role, with seed
--   guard: a role the opclass uses to claim the law (n/a if absent/false)
CREATE FUNCTION d1_k4(fam oid, typ oid, p jsonb) RETURNS d1_out LANGUAGE plpgsql AS $$
DECLARE
  pr record; cr record; gr record;
  pshape text := (SELECT shape FROM d1_role_vocab WHERE role = p->>'premise');
  prem text; cons text; ok text;
  e record; roles text; differ bigint;
BEGIN
  SELECT * INTO pr FROM d1_resolve(fam, typ, p->>'premise') LIMIT 1;
  IF NOT FOUND THEN RETURN d1_absent(p->>'premise'); END IF;
  roles := format('%s -> %s', p->>'premise', pr.fn::regproc);
  prem := CASE pshape WHEN 'cmp' THEN d1_cmp(pr, 'x.v', 'y.v') || ' = 0'
                      ELSE d1_call(pr.protocol, 'rel', pr.fn, 'x.v, y.v') END;
  IF p->>'consequence' = 'image' THEN
    cons := 'd1_image_eq(x.v, y.v)';
  ELSE
    SELECT * INTO cr FROM d1_resolve(fam, typ, p->>'consequence') LIMIT 1;
    IF NOT FOUND THEN RETURN d1_absent(p->>'consequence'); END IF;
    roles := roles || format('; %s -> %s', p->>'consequence', cr.fn::regproc);
    cons := format('%s = %s',
      d1_call(cr.protocol, 'value', cr.fn, 'x.v' || CASE WHEN p ? 'seed' THEN format(', %s::int8', (p->>'seed')::int8) ELSE '' END),
      d1_call(cr.protocol, 'value', cr.fn, 'y.v' || CASE WHEN p ? 'seed' THEN format(', %s::int8', (p->>'seed')::int8) ELSE '' END));
  END IF;
  IF p ? 'guard' THEN
    SELECT * INTO gr FROM d1_resolve(fam, typ, p->>'guard') LIMIT 1;
    IF NOT FOUND THEN
      EXECUTE format('SELECT count(*) FROM d1_s x, d1_s y WHERE x.i < y.i AND %s AND NOT %s', prem, cons) INTO differ;
      RETURN (roles || format('; %s: absent', p->>'guard'), 'n/a', 0::bigint,
              format('guard role %s absent; sample has %s premise-true consequence-false pairs', p->>'guard', differ))::d1_out;
    END IF;
    roles := roles || format('; %s -> %s', p->>'guard', gr.fn::regproc);
    -- a sample value carries the collation; it is not passed to the guard
    EXECUTE format('SELECT %s FROM d1_s LIMIT 1', d1_call(gr.protocol, 'guard', gr.fn, format('v, %s::oid', typ))) INTO ok;
    IF NOT ok::bool THEN
      EXECUTE format('SELECT count(*) FROM d1_s x, d1_s y WHERE x.i < y.i AND %s AND NOT %s', prem, cons) INTO differ;
      RETURN (roles, 'n/a', 0::bigint,
              format('guard returns false; sample has %s premise-true consequence-false pairs', differ))::d1_out;
    END IF;
  END IF;
  ok := format('NOT (%s) OR (%s)', prem, cons);
  IF (p->>'iff')::bool THEN ok := format('(%s) AND (NOT (%s) OR (%s))', ok, cons, prem); END IF;
  e := d1_eval('d1_s x, d1_s y WHERE x.i < y.i', ok, $x$format('x=%s y=%s', x.v, y.v)$x$);
  RETURN d1_verdict(roles, e.checked, e.bad);
END $$;

-- K5: a range predicate is monotone in val and in base, in the order of a
-- cmp role.  Offsets are values of the predicate's right type: taken from
-- the sample when the types match, or cast from it; otherwise BOUNDARY (G).
CREATE FUNCTION d1_k5(fam oid, typ oid, p jsonb, max_n int) RETURNS SETOF d1_out LANGUAGE plpgsql AS $$
DECLARE
  rp record; ord record;
  offs text[]; off text; cand text;
  sub bool; less bool;
  bad_val text; checked_val bigint;
  bad_base text; checked_base bigint;
  cv bigint; bv text; cbase bigint; bbase text;
  rt regtype;
  ok bool;
  roles text;
BEGIN
  SELECT * INTO ord FROM d1_resolve(fam, typ, p->>'order') LIMIT 1;
  IF NOT FOUND THEN RETURN NEXT d1_absent(p->>'order'); RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM d1_resolve(fam, typ, p->>'role')) THEN RETURN NEXT d1_absent(p->>'role'); RETURN; END IF;
  FOR rp IN SELECT * FROM d1_resolve(fam, typ, p->>'role') LOOP
    rt := rp.subtype;
    IF rp.subtype <> typ AND NOT EXISTS (SELECT 1 FROM pg_cast WHERE castsource = typ AND casttarget = rp.subtype) THEN
      RETURN NEXT (format('%s -> %s', p->>'role', rp.fn::regproc), 'BOUNDARY', 0::bigint,
        format('expected input: offsets of type %s; missing: G, a value source for that type; '
               'why: values come from the %s sample and no cast from %s to %s exists', rt, typ::regtype, typ::regtype, rt))::d1_out;
      CONTINUE;
    END IF;
    -- offsets: sample values the predicate accepts (it may reject, e.g. negative ones)
    offs := '{}';
    FOR cand IN SELECT v::text FROM d1_s ORDER BY i LOOP
      BEGIN
        EXECUTE format('SELECT %s FROM d1_s LIMIT 1', d1_call(rp.protocol, 'range', rp.fn,
                 format('v, v, %L::%s::%s, false, true', cand, typ::regtype, rt))) INTO ok;
        offs := offs || cand;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
      EXIT WHEN cardinality(offs) >= 3;
    END LOOP;
    IF cardinality(offs) = 0 THEN
      RETURN NEXT (format('%s -> %s', p->>'role', rp.fn::regproc), 'BOUNDARY', 0::bigint,
        'expected input: an accepted offset; missing: G; why: no sample value is accepted as an offset')::d1_out;
      CONTINUE;
    END IF;
    bad_val := NULL; checked_val := 0; bad_base := NULL; checked_base := 0;
    DROP TABLE IF EXISTS d1_c;
    EXECUTE format('CREATE TEMP TABLE d1_c AS SELECT x.i xi, y.i yi, %s s FROM d1_s x, d1_s y WHERE x.i <= %s AND y.i <= %s',
                   d1_cmp(ord, 'x.v', 'y.v'), max_n, max_n);
    FOREACH off IN ARRAY offs LOOP
      FOREACH sub IN ARRAY '{f,t}'::bool[] LOOP
        FOREACH less IN ARRAY '{f,t}'::bool[] LOOP
          DROP TABLE IF EXISTS d1_t;
          EXECUTE format('CREATE TEMP TABLE d1_t AS SELECT x.i vi, y.i bi, %s r FROM d1_s x, d1_s y WHERE x.i <= %s AND y.i <= %s',
                         d1_call(rp.protocol, 'range', rp.fn, format('x.v, y.v, %L::%s::%s, %L::bool, %L::bool', off, typ::regtype, rt, sub, less)),
                         max_n, max_n);
          -- val law (base z fixed): less: y true and x <= y => x true;  not less: x >= y
          -- base law (val z fixed): less: y true and x >= y => x true;  not less: x <= y
          -- the two halves are counted and reported separately
          EXECUTE format($q$
            SELECT count(*) FILTER (WHERE half = 'val'),
                   (array_agg(format('offset=%%s sub=%%s less=%%s: %%s', %L, %L, %L, w)) FILTER (WHERE half = 'val' AND NOT ok))[1],
                   count(*) FILTER (WHERE half = 'base'),
                   (array_agg(format('offset=%%s sub=%%s less=%%s: %%s', %L, %L, %L, w)) FILTER (WHERE half = 'base' AND NOT ok))[1]
            FROM (
              SELECT 'val' half, (NOT ty.r OR tx.r) ok, format('val #%%s true, val #%%s false, base #%%s (sample positions)', c.yi, c.xi, tx.bi) w
                FROM d1_c c JOIN d1_t ty ON ty.vi = c.yi JOIN d1_t tx ON tx.vi = c.xi AND tx.bi = ty.bi
               WHERE c.s %s 0
              UNION ALL
              SELECT 'base', (NOT ty.r OR tx.r), format('base #%%s true, base #%%s false, val #%%s (sample positions)', c.yi, c.xi, tx.vi)
                FROM d1_c c JOIN d1_t ty ON ty.bi = c.yi JOIN d1_t tx ON tx.bi = c.xi AND tx.vi = ty.vi
               WHERE c.s %s 0) z$q$,
            off, sub, less, off, sub, less, CASE WHEN less THEN '<=' ELSE '>=' END, CASE WHEN less THEN '>=' ELSE '<=' END)
            INTO cv, bv, cbase, bbase;
          checked_val := checked_val + cv;
          bad_val := coalesce(bad_val, bv);
          checked_base := checked_base + cbase;
          bad_base := coalesce(bad_base, bbase);
        END LOOP;
      END LOOP;
    END LOOP;
    roles := format('%s -> %s (offset %s); %s -> %s', p->>'role', rp.fn::regproc, rt, p->>'order', ord.fn::regproc);
    RETURN NEXT d1_verdict(roles || ' [val]', checked_val, bad_val);
    RETURN NEXT d1_verdict(roles || ' [base]', checked_base, bad_base);
  END LOOP;
END $$;

-- K6: successor enumerates the order of a cmp role: bounds hold every
-- value, step(a) is the next value (none in between), steps invert, and
-- stepping past a bound overflows.
CREATE FUNCTION d1_k6(fam oid, typ oid, p jsonb) RETURNS d1_out LANGUAGE plpgsql AS $$
DECLARE
  sr record; ord record;
  lo text; hi text;
  cn bigint; cb text; roles text;
  c text;
BEGIN
  SELECT * INTO sr FROM d1_resolve(fam, typ, p->>'role') LIMIT 1;
  IF NOT FOUND THEN RETURN d1_absent(p->>'role'); END IF;
  SELECT * INTO ord FROM d1_resolve(fam, typ, p->>'order') LIMIT 1;
  IF NOT FOUND THEN RETURN d1_absent(p->>'order'); END IF;
  roles := format('%s -> %s [%s]; %s -> %s', p->>'role', sr.fn::regproc, sr.protocol, p->>'order', ord.fn::regproc);
  lo := d1_call(sr.protocol, 'bound', sr.fn, $x$(SELECT v FROM d1_s LIMIT 1), 'low'$x$);
  hi := d1_call(sr.protocol, 'bound', sr.fn, $x$(SELECT v FROM d1_s LIMIT 1), 'high'$x$);
  DROP TABLE IF EXISTS d1_w;
  EXECUTE format('CREATE TEMP TABLE d1_w AS SELECT v FROM d1_s UNION ALL SELECT %s UNION ALL SELECT %s', lo, hi);
  c := d1_cmp(ord, '%1$s', '%2$s');
  -- outer values are qualified (s.v): inside NOT EXISTS, a bare v is y.v
  EXECUTE format($q$
    SELECT count(*), (array_agg(w) FILTER (WHERE NOT ok))[1] FROM (
      SELECT s.v::text w,
        -- bounds
        %1$s <= 0 AND %2$s >= 0
        -- up
        AND (%3$s = 0 AND s.up IS NULL
             OR %3$s <> 0 AND s.up IS NOT NULL AND %4$s > 0
                AND NOT EXISTS (SELECT 1 FROM d1_w y WHERE %5$s < 0 AND %6$s < 0)
                AND %7$s = 0)
        -- down
        AND (%8$s = 0 AND s.dn IS NULL
             OR %8$s <> 0 AND s.dn IS NOT NULL AND %9$s < 0
                AND NOT EXISTS (SELECT 1 FROM d1_w y WHERE %10$s < 0 AND %11$s < 0)) AS ok
      FROM (SELECT v, %12$s up, %13$s dn FROM d1_w) s) z$q$,
    format(c, lo, 's.v'), format(c, hi, 's.v'),
    format(c, 's.v', hi), format(c, 's.up', 's.v'), format(c, 's.v', 'y.v'), format(c, 'y.v', 's.up'),
    format(c, d1_call(sr.protocol, 'step', sr.fn, $x$s.up, 'down'$x$), 's.v'),
    format(c, 's.v', lo), format(c, 's.dn', 's.v'), format(c, 's.dn', 'y.v'), format(c, 'y.v', 's.v'),
    d1_call(sr.protocol, 'step', sr.fn, $x$v, 'up'$x$), d1_call(sr.protocol, 'step', sr.fn, $x$v, 'down'$x$))
    INTO cn, cb;
  RETURN d1_verdict(roles, cn, cb);
END $$;

/*
 * d1_check(opclass, am, sample): run every law instance of the AM (and of
 * this opclass's family) over the sample.  Collation comes from the sample.
 */
CREATE FUNCTION d1_check(opclass text, am text, sample anyarray, max_n int DEFAULT 30)
RETURNS TABLE(law text, kind text, roles text, values_n int, status text, checked bigint, detail text)
LANGUAGE plpgsql AS $$
DECLARE
  fam oid; typ oid; famname text;
  coll text;
  l record;
  o d1_out;
  n int;
BEGIN
  SELECT c.opcfamily, c.opcintype, f.opfname INTO fam, typ, famname
  FROM pg_opclass c JOIN pg_am m ON m.oid = c.opcmethod JOIN pg_opfamily f ON f.oid = c.opcfamily
  WHERE c.opcname = opclass COLLATE "C" AND m.amname = am COLLATE "C";
  IF fam IS NULL THEN RAISE EXCEPTION 'no opclass % for %', opclass, am; END IF;
  IF (SELECT typcollation <> 0 FROM pg_type WHERE oid = typ) THEN
    coll := pg_collation_for(sample);
  END IF;

  -- scratch tables are dropped and recreated per call; keep that quiet
  PERFORM set_config('client_min_messages', 'warning', true);
  DROP TABLE IF EXISTS d1_s;
  EXECUTE format('CREATE TEMP TABLE d1_s (i int, v %s %s)', typ::regtype,
                 CASE WHEN coll IS NOT NULL THEN 'COLLATE ' || coll ELSE '' END);
  EXECUTE format('INSERT INTO d1_s SELECT row_number() OVER (), v FROM unnest($1::%s[]) v WHERE v IS NOT NULL LIMIT %s',
                 typ::regtype, max_n) USING sample;
  SELECT count(*) INTO n FROM d1_s;

  FOR l IN SELECT * FROM d1_law d WHERE d.am = d1_check.am COLLATE "C" AND (d.family IS NULL OR d.family = famname) ORDER BY d.law LOOP
    IF l.kind = 'K5' THEN
      FOR o IN SELECT * FROM d1_k5(fam, typ, l.params, max_n) LOOP
        RETURN QUERY SELECT l.law, l.kind, o.roles, n, o.status, o.checked, o.detail;
      END LOOP;
      CONTINUE;
    END IF;
    o := CASE l.kind
      WHEN 'K1' THEN d1_k1(fam, typ, l.params)
      WHEN 'K2' THEN d1_k2(fam, typ, l.params)
      WHEN 'K3' THEN d1_k3(fam, typ, l.params)
      WHEN 'K4' THEN d1_k4(fam, typ, l.params)
      WHEN 'K6' THEN d1_k6(fam, typ, l.params)
    END;
    RETURN QUERY SELECT l.law, l.kind, o.roles, n, o.status, o.checked, o.detail;
  END LOOP;
END $$;
