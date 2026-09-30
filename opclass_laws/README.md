# opclass_laws

Checks BT-INV laws O1–O9 of a btree opclass on a sample of values.

    CREATE EXTENSION opclass_laws;
    SELECT * FROM opclass_laws_check('text_ops',
      (SELECT array_agg(col) FROM tbl TABLESAMPLE SYSTEM (1)));
    SELECT * FROM opclass_laws_check_inrange('date_ops', sample, '{1 day,1 month}');

Status: `pass`, `FAIL` (with one counterexample), `n/a` (support function
absent or declined), `empty` (nothing was checked).  Collation comes from
the sample; an indeterminate collation is an error.  Only the first
`max_n` values are used.

Tests:

- `control_opclass` — the evidence the checks are not vacuous: a test-only
  opclass (`ctl_opclass.so`, one injectable fault per law) fails exactly
  the targeted law under each fault and passes with none.
- `standard_types` — **observed** results for built-in opclasses on
  edge-value samples.  The expected file was taken from a run and reviewed
  by hand; it is not an independent reference.  It records current
  behaviour, including why dedup is unsafe for float8/numeric/interval/
  jsonb/nondeterministic text.
- `limits` — truncation, collation refusal, cancellation inside the loops.
