\echo Use "CREATE EXTENSION d0gen" to load this file. \quit

-- D0 generator: checks derived only from metadata PostgreSQL already has
-- (IndexAmRoutine, catalog, index/column properties), values taken from
-- the column itself, and a seqscan reference result.  This file must not
-- name any index AM.
--
-- Statuses: pass, FAIL (contract violated), empty (nothing checked),
-- n/a (flag/property says the contract does not apply), UNRESOLVED
-- (contract itself undecided), BOUNDARY (inputs insufficient),
-- METADATA (two metadata paths disagree; not a contract violation).

CREATE FUNCTION d0_am_routine(am text)
RETURNS TABLE(kind text, name text, value bool)
AS 'MODULE_PATHNAME', 'd0_am_routine' LANGUAGE C STRICT;

CREATE FUNCTION d0_translate_strategy(am text, opfamily oid, strategy int)
RETURNS int AS 'MODULE_PATHNAME', 'd0_translate_strategy' LANGUAGE C STRICT;

CREATE FUNCTION d0_default_opclass(am text, typ regtype)
RETURNS oid AS 'MODULE_PATHNAME', 'd0_default_opclass' LANGUAGE C STRICT;

CREATE FUNCTION d0_can_return(idx regclass, attno int)
RETURNS bool AS 'MODULE_PATHNAME', 'd0_can_return' LANGUAGE C STRICT;

-- Operator the parser picks for (lt OP rt), read back from a stored view.
CREATE FUNCTION d0_resolved_operator(opname text, lt regtype, rt regtype)
RETURNS oid LANGUAGE plpgsql AS $$
DECLARE
  r oid;
BEGIN
  EXECUTE format('CREATE TEMP VIEW d0_probe AS SELECT NULL::%s %s NULL::%s AS x', lt, opname, rt);
  SELECT substring(ev_action from ':opno ([0-9]+)')::oid INTO r
  FROM pg_rewrite WHERE ev_class = 'd0_probe'::regclass;
  DROP VIEW d0_probe;
  RETURN r;
EXCEPTION WHEN undefined_function OR ambiguous_function THEN
  RETURN NULL;
END $$;

CREATE FUNCTION d0_flag(am text, flag text) RETURNS bool
LANGUAGE sql STABLE AS $$
  SELECT value FROM d0_am_routine(am) WHERE name = flag
$$;

-- Planner switches for one access path; the reference path is 'seq'.
CREATE FUNCTION d0_set_mode(mode text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  seq bool := mode = 'seq';
BEGIN
  PERFORM set_config('enable_seqscan', CASE WHEN seq THEN 'on' ELSE 'off' END, true);
  -- enable_indexscan also gates index-only paths (planner.c)
  PERFORM set_config('enable_indexscan', CASE WHEN mode IN ('index', 'parallel', 'ios') THEN 'on' ELSE 'off' END, true);
  PERFORM set_config('enable_indexonlyscan', CASE WHEN mode = 'ios' THEN 'on' ELSE 'off' END, true);
  PERFORM set_config('enable_bitmapscan', CASE WHEN mode = 'bitmap' THEN 'on' ELSE 'off' END, true);
  PERFORM set_config('enable_sort', CASE WHEN mode IN ('index', 'ios') THEN 'off' ELSE 'on' END, true);
  PERFORM set_config('max_parallel_workers_per_gather', CASE WHEN mode = 'parallel' THEN '2' ELSE '0' END, true);
  PERFORM set_config('parallel_setup_cost', '0', true);
  PERFORM set_config('parallel_tuple_cost', '0', true);
  PERFORM set_config('min_parallel_table_scan_size', '0', true);
  PERFORM set_config('min_parallel_index_scan_size', '0', true);
END $$;

-- Does the plan of q under mode read index idx with the expected node?
CREATE FUNCTION d0_plan_uses(q text, mode text, idx text) RETURNS bool
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
  nodes text[] := CASE mode
    WHEN 'index' THEN '{Index Scan}'
    WHEN 'parallel' THEN '{Index Scan}'
    WHEN 'ios' THEN '{Index Only Scan}'
    WHEN 'bitmap' THEN '{Bitmap Index Scan}'
  END;
BEGIN
  PERFORM d0_set_mode(mode);
  EXECUTE 'EXPLAIN (FORMAT JSON) ' || q INTO plan;
  RETURN jsonb_path_exists(plan,
    '$.** ? (@."Index Name" == $idx && @."Node Type" == $nodes[*]
             && !(@."Disabled" == true)
             && ($par == false || @."Parallel Aware" == true))',
    jsonb_build_object('idx', idx, 'nodes', to_jsonb(nodes),
                       'par', mode = 'parallel'));
END $$;

-- Does the plan of q under mode read index idx at all?  Used to keep the
-- reference path off the index under test.
CREATE FUNCTION d0_plan_reads(q text, mode text, idx text) RETURNS bool
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
BEGIN
  PERFORM d0_set_mode(mode);
  EXECUTE 'EXPLAIN (FORMAT JSON) ' || q INTO plan;
  RETURN jsonb_path_exists(plan, '$.** ? (@."Index Name" == $idx)', jsonb_build_object('idx', idx));
END $$;

-- Result of q (a single column) under mode, as a sorted text multiset.
CREATE FUNCTION d0_result(q text, mode text) RETURNS text[]
LANGUAGE plpgsql AS $$
DECLARE
  r text[];
BEGIN
  PERFORM d0_set_mode(mode);
  EXECUTE format('SELECT coalesce(array_agg(x::text ORDER BY x::text), ''{}'') FROM (%s) s(x)', q) INTO r;
  RETURN r;
END $$;

-- Compare q under mode with the seqscan reference.
CREATE FUNCTION d0_compare(q text, mode text, idx text,
                           OUT status text, OUT detail text)
LANGUAGE plpgsql AS $$
DECLARE
  ref text[];
  got text[];
BEGIN
  IF NOT d0_plan_uses(q, mode, idx) THEN
    status := 'empty';
    detail := format('planner did not use %s path on %s: %s', mode, idx, q);
    RETURN;
  END IF;
  IF d0_plan_reads(q, 'seq', idx) THEN
    status := 'empty';
    detail := format('reference plan reads %s: %s', idx, q);
    RETURN;
  END IF;
  ref := d0_result(q, 'seq');
  got := d0_result(q, mode);
  IF cardinality(ref) = 0 AND cardinality(got) = 0 THEN
    status := 'empty';
    detail := 'reference has 0 rows';
  ELSIF ref = got THEN
    status := 'pass';
    detail := format('%s rows', cardinality(ref));
  ELSE
    status := 'FAIL';
    detail := format('%s: reference %s rows, %s %s rows; missing %s; extra %s',
      q, cardinality(ref), mode, cardinality(got),
      (SELECT array_agg(x) FROM (SELECT unnest(ref) EXCEPT ALL SELECT unnest(got)) m(x)),
      (SELECT array_agg(x) FROM (SELECT unnest(got) EXCEPT ALL SELECT unnest(ref)) e(x)));
  END IF;
END $$;

-- S3: is tids (the index's output order) monotone in the reference sort?
CREATE FUNCTION d0_order_ok(tbl regclass, col text, dir text, tids tid[],
                            OUT status text, OUT detail text)
LANGUAGE plpgsql AS $$
DECLARE
  ok bool;
  n int;
BEGIN
  IF upper(dir) NOT IN ('ASC', 'DESC') THEN
    RAISE EXCEPTION 'dir must be ASC or DESC';
  END IF;
  PERFORM d0_set_mode('seq');
  EXECUTE format($f$
    SELECT bool_and(ok), count(*) FROM (
      SELECT r >= lag(r) OVER (ORDER BY o) OR lag(r) OVER (ORDER BY o) IS NULL AS ok
      FROM unnest(%L::tid[]) WITH ORDINALITY u(t, o)
      JOIN (SELECT ctid, dense_rank() OVER (ORDER BY %I %s) r FROM %s) s ON s.ctid = u.t) z$f$,
    tids, col, dir, tbl) INTO ok, n;
  status := CASE WHEN n = 0 THEN 'empty' WHEN ok THEN 'pass' ELSE 'FAIL' END;
  detail := format('%s rows', n);
END $$;

-- S3 for an existing index idx on tbl(col)
CREATE FUNCTION d0_check_order(tbl regclass, col text, dir text, idx text,
                               OUT status text, OUT detail text)
LANGUAGE plpgsql AS $$
DECLARE
  q text := format('SELECT ctid FROM %s ORDER BY %I %s', tbl, col, dir);
  tids tid[] := '{}';
  r record;
BEGIN
  IF NOT d0_plan_uses(q, 'index', idx) THEN
    status := 'empty';
    detail := 'planner did not use the index';
    RETURN;
  END IF;
  PERFORM d0_set_mode('index');
  -- rows in the order the ordered SELECT delivers them
  FOR r IN EXECUTE q LOOP
    tids := tids || r.ctid;
  END LOOP;
  SELECT * INTO status, detail FROM d0_order_ok(tbl, col, dir, tids);
END $$;

-- A6: an unqualified index-only count over idx sees every row, NULLs included
CREATE FUNCTION d0_check_nulls_indexed(tbl regclass, col text, idx text,
                                       OUT status text, OUT detail text)
LANGUAGE plpgsql AS $$
DECLARE
  q text := format('SELECT count(*) FROM %s', tbl);
  ref bigint;
  got bigint;
  nulls bigint;
BEGIN
  IF NOT d0_plan_uses(q, 'ios', idx) THEN
    status := 'empty';
    detail := 'no index-only path for an unqualified scan';
    RETURN;
  END IF;
  IF d0_plan_reads(q, 'seq', idx) THEN
    status := 'empty';
    detail := 'reference plan reads the index';
    RETURN;
  END IF;
  ref := (d0_result(q, 'seq'))[1]::bigint;
  got := (d0_result(q, 'ios'))[1]::bigint;
  nulls := (d0_result(format('SELECT count(*) FROM %s WHERE %I IS NULL', tbl, col), 'seq'))[1]::bigint;
  status := CASE WHEN nulls = 0 THEN 'empty' WHEN ref = got THEN 'pass' ELSE 'FAIL' END;
  detail := format('reference %s rows (%s NULL), index-only %s', ref, nulls, got);
END $$;

-- A9: with a unique index on tbl(col), inserting an existing key val is
-- rejected, and after deleting it the key is accepted again
CREATE FUNCTION d0_check_unique(tbl regclass, col text, val text)
RETURNS TABLE(check_name text, status text, detail text)
LANGUAGE plpgsql AS $$
DECLARE
  typ regtype := (SELECT atttypid FROM pg_attribute WHERE attrelid = tbl AND attname = col);
BEGIN
  BEGIN
    EXECUTE format('INSERT INTO %s (%I) VALUES (%L::%s)', tbl, col, val, typ);
    RETURN QUERY SELECT 'duplicate rejected', 'FAIL', format('duplicate %s accepted', val);
  EXCEPTION WHEN unique_violation THEN
    RETURN QUERY SELECT 'duplicate rejected', 'pass', NULL::text;
  END;
  EXECUTE format('DELETE FROM %s WHERE %I = %L::%s', tbl, col, val, typ);
  BEGIN
    EXECUTE format('INSERT INTO %s (%I) VALUES (%L::%s)', tbl, col, val, typ);
    RETURN QUERY SELECT 'key accepted after delete', 'pass', NULL::text;
  EXCEPTION WHEN unique_violation THEN
    RETURN QUERY SELECT 'key accepted after delete', 'FAIL', format('%s rejected after delete', val);
  END;
END $$;

/*
 * d0_check: generate and run D0 checks for index AM am on tbl.col.
 * col2 (optional, same table) feeds the multicolumn and INCLUDE checks.
 */
CREATE FUNCTION d0_check(tbl regclass, col text, am text,
                         col2 text DEFAULT NULL, nconst int DEFAULT 3)
RETURNS TABLE(contract text, check_name text, status text, detail text)
LANGUAGE plpgsql AS $$
DECLARE
  coltype regtype;
  opc oid;
  opf oid;
  opcintype regtype;
  idx text := format('d0_%s_%s', am, col);
  qcol text := quote_ident(col);
  consts text[];
  op record;
  q text;
  cmpres record;
  ok bool;
  n int;
  bad int;
  tids tid[];
  req text[] := '{ambuild,ambuildempty,aminsert,ambulkdelete,amvacuumcleanup,amcostestimate,amoptions,amvalidate,ambeginscan,amrescan,amendscan}';
  searchops jsonb := '[]';
  saved jsonb;
  modes text[];
  m text;
BEGIN
  SELECT jsonb_object_agg(name, current_setting(name)) INTO saved
  FROM unnest('{enable_seqscan,enable_indexscan,enable_indexonlyscan,enable_bitmapscan,enable_sort,max_parallel_workers_per_gather,parallel_setup_cost,parallel_tuple_cost,min_parallel_table_scan_size,min_parallel_index_scan_size}'::text[]) name;

  SELECT atttypid INTO coltype FROM pg_attribute WHERE attrelid = tbl AND attname = col;
  opc := d0_default_opclass(am, coltype);
  IF opc = 0 THEN
    RETURN QUERY SELECT 'setup', 'default opclass', 'BOUNDARY',
      format('no default %s opclass for %s', am, coltype);
    RETURN;
  END IF;
  SELECT opcfamily, o.opcintype INTO opf, opcintype FROM pg_opclass o WHERE oid = opc;

  -- A1, A2: callback presence
  SELECT count(*) INTO n FROM d0_am_routine(am) r WHERE r.kind = 'callback' AND r.name = ANY(req) AND NOT r.value;
  RETURN QUERY SELECT 'A1', 'required callbacks', CASE WHEN n = 0 THEN 'pass' ELSE 'FAIL' END,
    format('%s of %s missing', n, cardinality(req));
  RETURN QUERY SELECT 'A2', 'amgettuple or amgetbitmap',
    CASE WHEN d0_flag(am, 'amgettuple') OR d0_flag(am, 'amgetbitmap') THEN 'pass' ELSE 'FAIL' END, NULL::text;
  RETURN QUERY SELECT 'A3', 'amcanorder => ammarkpos', 'UNRESOLVED', 'R1: doc or code defines the contract';
  RETURN QUERY SELECT 'A5', 'backward => amcanorder', 'UNRESOLVED', 'R3: doc or code defines the contract';

  -- A4: ordering AMs use strategy numbers equal to their CompareType
  IF d0_flag(am, 'amcanorder') THEN
    SELECT count(*), count(*) FILTER (WHERE d0_translate_strategy(am, opf, a.amopstrategy) <> a.amopstrategy)
      INTO n, bad FROM pg_amop a
      WHERE a.amopfamily = opf AND a.amoppurpose = 's' AND a.amopstrategy BETWEEN 1 AND 5;
    RETURN QUERY SELECT 'A4', 'strategy -> CompareType', CASE WHEN n = 0 THEN 'empty' WHEN bad = 0 THEN 'pass' ELSE 'FAIL' END,
      format('%s operators, %s mistranslated', n, bad);
  ELSE
    RETURN QUERY SELECT 'A4', 'strategy -> CompareType', 'n/a', 'amcanorder = false';
  END IF;

  EXECUTE format('CREATE INDEX %I ON %s USING %I (%I)', idx, tbl, am, col);

  -- constants from the column, evenly spaced in physical order
  EXECUTE format($f$SELECT array_agg(v ORDER BY first_rn) FROM (
      SELECT v, min(rn) first_rn FROM (
        SELECT %1$s::text v, row_number() OVER (ORDER BY ctid) rn, count(*) OVER () c
        FROM %2$s WHERE %1$s IS NOT NULL) s
      WHERE rn IN (SELECT DISTINCT greatest(1, (c * k / (%3$s + 1))::int) FROM generate_series(1, %3$s) k)
      GROUP BY v) d$f$,
    qcol, tbl, nconst) INTO consts;

  -- search operators whose constant can be taken from the column itself
  FOR op IN
    SELECT a.amopopr::regoperator AS opr, o.oprname, o.oprnamespace::regnamespace AS nsp,
           a.amoplefttype::regtype AS lt, a.amoprighttype::regtype AS rt, a.amopstrategy
    FROM pg_amop a JOIN pg_operator o ON o.oid = a.amopopr
    WHERE a.amopfamily = opf AND a.amoppurpose = 's' AND a.amoplefttype = opcintype
    ORDER BY a.amopstrategy, a.amoprighttype
  LOOP
    IF op.rt = op.lt OR op.rt = coltype THEN
      searchops := searchops || jsonb_build_object('op', format('OPERATOR(%s.%s)', op.nsp, op.oprname), 'cast', coltype::text, 'opr', op.opr::text);
    ELSIF EXISTS (SELECT 1 FROM pg_cast c JOIN pg_type t ON t.oid = c.casttarget
                  WHERE c.castsource = coltype AND c.casttarget = op.rt
                    AND c.castcontext IN ('i', 'a') AND t.typtype <> 'p') THEN
      searchops := searchops || jsonb_build_object('op', format('OPERATOR(%s.%s)', op.nsp, op.oprname), 'cast', op.rt::text, 'opr', op.opr::text);
    ELSE
      -- any cast from the column type whose target makes the parser pick this operator
      m := (SELECT c.casttarget::regtype::text FROM pg_cast c JOIN pg_type t ON t.oid = c.casttarget
            WHERE c.castsource = coltype AND t.typtype <> 'p'
              AND d0_resolved_operator(format('OPERATOR(%s.%s)', op.nsp, op.oprname), coltype, c.casttarget::regtype) = op.opr::oid
            ORDER BY c.casttarget LIMIT 1);
      IF m IS NOT NULL THEN
        searchops := searchops || jsonb_build_object('op', format('OPERATOR(%s.%s)', op.nsp, op.oprname), 'cast', m, 'opr', op.opr::text);
      ELSE
        RETURN QUERY SELECT 'S1-ext/S9-ext', format('constant for %s', op.opr), 'BOUNDARY',
          format('expected input: a constant of type %s for a %s column; missing: G, a value source for that type; '
                 'why: values come from the column, and no cast from %s (any context) makes the parser resolve to this operator',
                 op.rt, coltype, coltype);
      END IF;
    END IF;
  END LOOP;

  -- S1/S2 (index scan), S9 (bitmap), S13 (parallel): operator x constant vs reference
  modes := '{}';
  IF pg_index_has_property(idx::regclass, 'index_scan') THEN modes := modes || '{index}'::text[]; END IF;
  IF pg_index_has_property(idx::regclass, 'bitmap_scan') THEN modes := modes || '{bitmap}'::text[]; END IF;
  IF d0_flag(am, 'amcanparallel') THEN modes := modes || '{parallel}'::text[]; END IF;
  FOREACH m IN ARRAY modes LOOP
    FOR op IN SELECT * FROM jsonb_to_recordset(searchops) AS x(op text, "cast" text, opr text) LOOP
      FOR n IN 1 .. coalesce(cardinality(consts), 0) LOOP
        q := format('SELECT ctid FROM %s WHERE %s %s %L::%s::%s', tbl, qcol, op.op, consts[n], coltype, op."cast");
        cmpres := d0_compare(q, m, idx);
        -- external projections: execution result == reference.  The callback
        -- contracts (xs_recheck = false means exact; amgetbitmap == union of
        -- amgettuple) need callback-boundary observation and are not checked.
        RETURN QUERY SELECT CASE m WHEN 'index' THEN 'S1-ext/S2' WHEN 'bitmap' THEN 'S9-ext' ELSE 'S13' END,
          format('%s %s', op.opr, consts[n]), cmpres.status, cmpres.detail;
      END LOOP;
    END LOOP;
  END LOOP;

  -- A10: SAOP and NULL search, when the column property says the AM does it
  IF pg_index_column_has_property(idx::regclass, 1, 'search_array') THEN
    FOR op IN SELECT * FROM jsonb_to_recordset(searchops) AS x(op text, "cast" text, opr text) WHERE "cast" = coltype::text LOOP
      q := format('SELECT ctid FROM %s WHERE %s %s ANY (%L::%s[])', tbl, qcol, op.op, consts, coltype);
      cmpres := d0_compare(q, CASE WHEN 'index' = ANY(modes) THEN 'index' ELSE 'bitmap' END, idx);
      RETURN QUERY SELECT 'A10', format('%s ANY', op.opr), cmpres.status, cmpres.detail;
    END LOOP;
  ELSE
    RETURN QUERY SELECT 'A10', 'search_array', 'n/a', 'property false';
  END IF;
  IF pg_index_column_has_property(idx::regclass, 1, 'search_nulls') THEN
    FOREACH q IN ARRAY ARRAY[format('SELECT ctid FROM %s WHERE %s IS NULL', tbl, qcol),
                             format('SELECT ctid FROM %s WHERE %s IS NOT NULL', tbl, qcol)] LOOP
      cmpres := d0_compare(q, CASE WHEN 'index' = ANY(modes) THEN 'index' ELSE 'bitmap' END, idx);
      RETURN QUERY SELECT 'A10', substring(q from 'WHERE (.*)$'), cmpres.status, cmpres.detail;
    END LOOP;
  ELSE
    RETURN QUERY SELECT 'A10', 'search_nulls', 'n/a', 'property false';
  END IF;

  -- S3: ordered output (ascending, and descending if backward scan is possible)
  IF pg_indexam_has_property((SELECT oid FROM pg_am WHERE amname = am), 'can_order') THEN
    FOREACH m IN ARRAY CASE WHEN pg_index_has_property(idx::regclass, 'backward_scan')
                            THEN '{ASC,DESC}'::text[] ELSE '{ASC}'::text[] END LOOP
      cmpres := d0_check_order(tbl, col, m, idx);
      RETURN QUERY SELECT 'S3', format('ORDER BY %s', m), cmpres.status, cmpres.detail;
    END LOOP;
  ELSE
    RETURN QUERY SELECT 'S3', 'ordered scan', 'n/a', 'can_order = false';
  END IF;

  -- A6: amoptionalkey => NULLs are in the index (unqualified index-only count)
  IF d0_flag(am, 'amoptionalkey') THEN
    cmpres := d0_check_nulls_indexed(tbl, col, idx);
    RETURN QUERY SELECT 'A6', 'unqualified scan sees NULLs', cmpres.status, cmpres.detail;
  ELSE
    RETURN QUERY SELECT 'A6', 'unqualified scan sees NULLs', 'n/a', 'amoptionalkey = false';
  END IF;

  -- metadata agreement for the key column as well (see A7 for INCLUDE)
  RETURN QUERY SELECT 'A7', 'returnable property agrees with amcanreturn (key)',
    CASE WHEN pg_index_column_has_property(idx::regclass, 1, 'returnable')
              IS NOT DISTINCT FROM d0_can_return(idx::regclass, 1) THEN 'pass' ELSE 'METADATA' END,
    format('property %s, amcanreturn %s',
           coalesce(pg_index_column_has_property(idx::regclass, 1, 'returnable')::text, 'NULL'),
           d0_can_return(idx::regclass, 1));

  EXECUTE format('DROP INDEX %I', idx);

  -- A6 (multicolumn) and A7 (INCLUDE): NULLs in a non-first / included column.
  -- Pick the first operator/constant whose reference result contains rows
  -- with col2 IS NULL, so the check cannot pass on nothing.
  IF col2 IS NOT NULL THEN
    q := NULL;
    FOR op IN SELECT * FROM jsonb_to_recordset(searchops) AS x(op text, "cast" text, opr text) LOOP
      FOR n IN 1 .. coalesce(cardinality(consts), 0) LOOP
        PERFORM d0_set_mode('seq');
        EXECUTE format('SELECT count(*) FROM %s WHERE %s %s %L::%s::%s AND %I IS NULL',
                       tbl, qcol, op.op, consts[n], coltype, op."cast", col2) INTO bad;
        IF bad > 0 THEN
          q := format('%s %s %L::%s::%s', qcol, op.op, consts[n], coltype, op."cast");
          EXIT;
        END IF;
      END LOOP;
      EXIT WHEN q IS NOT NULL;
    END LOOP;

    IF q IS NULL THEN
      RETURN QUERY SELECT 'A6/A7', 'qualifier hitting NULL second column', 'empty', 'no operator/constant selects such rows';
    ELSE
      IF d0_flag(am, 'amcanmulticol') THEN
        EXECUTE format('CREATE INDEX %I ON %s USING %I (%I, %I)', idx, tbl, am, col, col2);
        cmpres := d0_compare(format('SELECT ctid FROM %s WHERE %s', tbl, q),
                             CASE WHEN 'index' = ANY(modes) THEN 'index' ELSE 'bitmap' END, idx);
        RETURN QUERY SELECT 'A6', format('multicol: NULL in %s', col2), cmpres.status, cmpres.detail;
        EXECUTE format('DROP INDEX %I', idx);
      ELSE
        RETURN QUERY SELECT 'A6', 'multicol', 'n/a', 'amcanmulticol = false';
      END IF;

      IF d0_flag(am, 'amcaninclude') THEN
        EXECUTE format('CREATE INDEX %I ON %s USING %I (%I) INCLUDE (%I)', idx, tbl, am, col, col2);
        RETURN QUERY SELECT 'A7', 'amcanreturn(INCLUDE column)',
          CASE WHEN d0_can_return(idx::regclass, 2) THEN 'pass' ELSE 'FAIL' END, NULL::text;
        -- two metadata paths answering the same question; disagreement is
        -- METADATA, not a contract violation
        RETURN QUERY SELECT 'A7', 'returnable property agrees with amcanreturn',
          CASE WHEN pg_index_column_has_property(idx::regclass, 2, 'returnable')
                    IS NOT DISTINCT FROM d0_can_return(idx::regclass, 2) THEN 'pass' ELSE 'METADATA' END,
          format('property %s, amcanreturn %s',
                 coalesce(pg_index_column_has_property(idx::regclass, 2, 'returnable')::text, 'NULL'),
                 d0_can_return(idx::regclass, 2));
        IF d0_can_return(idx::regclass, 1) THEN
          cmpres := d0_compare(format('SELECT (%s, %I) FROM %s WHERE %s', qcol, col2, tbl, q), 'ios', idx);
          RETURN QUERY SELECT 'A7', 'index-only with NULL included values', cmpres.status, cmpres.detail;
        ELSE
          RETURN QUERY SELECT 'A7', 'index-only with NULL included values', 'n/a', 'key column not returnable';
        END IF;
        EXECUTE format('DROP INDEX %I', idx);
      ELSE
        RETURN QUERY SELECT 'A7', 'INCLUDE', 'n/a', 'amcaninclude = false';
      END IF;
    END IF;
  END IF;

  -- A9: amcanunique => a unique index rejects a duplicate and accepts a new key
  IF d0_flag(am, 'amcanunique') THEN
    EXECUTE format('CREATE TEMP TABLE d0_u AS SELECT DISTINCT %s AS k FROM %s WHERE %s IS NOT NULL', qcol, tbl, qcol);
    EXECUTE format('CREATE UNIQUE INDEX d0_u_idx ON d0_u USING %I (k)', am);
    RETURN QUERY SELECT 'A9', u.check_name, u.status, u.detail FROM d0_check_unique('d0_u', 'k', consts[1]) u;
    DROP TABLE d0_u;
  ELSE
    RETURN QUERY SELECT 'A9', 'unique', 'n/a', 'amcanunique = false';
  END IF;

  FOR q IN SELECT key FROM jsonb_object_keys(saved) key LOOP
    PERFORM set_config(q, saved->>q, true);
  END LOOP;
END $$;
