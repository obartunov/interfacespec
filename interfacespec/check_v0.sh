#!/bin/sh
# Round trip: interfacespec-v0.yaml -> load_v0.py -> d1_role/d1_law rows.
#  1. normalized comparison with the hand-written role_tables.sql
#     (and of role shapes / protocol names with the engine vocabulary);
#  2. the unchanged d1_laws regression test run on the generated rows,
#     compared with the unchanged expected output (the echoed text of
#     role_tables.sql excluded, since it is a different file).
# Needs: d1laws, d1_ctl, opclass_laws, ctl_opclass installed; server on PGPORT.
set -e
here=$(cd "$(dirname "$0")" && pwd)
d1=$here/../d1laws
work=${WORK:-$(mktemp -d)}
spec=${SPEC:-$here/../interfacespec-v0.yaml}
bindir=$(pg_config --bindir)
pgx=$(dirname "$(pg_config --pgxs)")/../test/regress/pg_regress
PSQL="psql -X -q -At -v ON_ERROR_STOP=1 -p ${PGPORT:-5433} -U ${PGUSER:-postgres}"

python3 "$here/load_v0.py" "$spec" > "$work/generated.sql"
python3 "$here/load_v0.py" "$spec" --vocab > "$work/generated_vocab.sql"

# 1. normalized table comparison (SKIP_TABLES=1: only part 2, for probes)
if [ -z "$SKIP_TABLES" ]; then
$PSQL -d postgres -c 'DROP DATABASE IF EXISTS isv0' -c 'CREATE DATABASE isv0'
dump="SELECT am, family, role, source, number, protocol, attr, righttype FROM d1_role ORDER BY 1,2,3,4,5,6,7,8;
      SELECT am, family, law, kind, params FROM d1_law ORDER BY 1,2,3;"
$PSQL -d isv0 -c 'CREATE EXTENSION d1laws' -f "$d1/role_tables.sql" -c "$dump" > "$work/hand.txt"
$PSQL -d isv0 -c 'TRUNCATE d1_role, d1_law' -f "$work/generated_vocab.sql" -c "$dump" > "$work/gen.txt"
$PSQL -d isv0 -f "$work/generated_vocab.sql" -c "TRUNCATE d1_role, d1_law" -c "
  SELECT 'role shape differs: ' || coalesce(a.role, b.role) FROM d1_role_vocab a FULL JOIN spec_role_vocab b USING (role)
   WHERE a.shape IS DISTINCT FROM b.shape
  UNION ALL
  SELECT 'protocol differs: ' || coalesce(a.protocol, b.protocol) FROM (SELECT DISTINCT protocol FROM d1_protocol) a
   FULL JOIN spec_protocol b USING (protocol) WHERE a.protocol IS NULL OR b.protocol IS NULL" > "$work/vocab.txt"
if diff -u "$work/hand.txt" "$work/gen.txt" && [ ! -s "$work/vocab.txt" ]; then
  echo "tables: same ($(grep -c . "$work/hand.txt") rows); vocabulary: same"
else
  cat "$work/vocab.txt"; echo "tables: DIFFER"; exit 1
fi
$PSQL -d postgres -c 'DROP DATABASE isv0'
fi

# 2. the same regression test on generated rows
mkdir -p "$work/run/sql" "$work/run/expected"
cp "$d1/sql/d1_laws.sql" "$work/run/sql/"
cp "$d1/expected/d1_laws.out" "$work/run/expected/"
# \ir in d1_laws.sql resolves against the working directory under pg_regress
{ echo '\set ECHO none'; cat "$work/generated.sql"; echo '\set ECHO all'; } > "$work/run/role_tables.sql"
(cd "$work/run" && "$pgx" --bindir="$bindir" --port=${PGPORT:-5433} --user=${PGUSER:-postgres} \
   --dbname=contrib_regression --inputdir=. d1_laws > pg_regress.log 2>&1) || true
# strip FILE OUT SKIPPED: drop the lines between "\ir role_tables.sql" and the next statement
strip() { awk -v sk="$3" '/^\\ir role_tables.sql$/ {print; skip=1; next} skip && /^CREATE COLLATION/ {skip=0} skip {print > sk; next} {print}' "$1" > "$2"; }
: > "$work/expected.skipped"; : > "$work/results.skipped"
strip "$d1/expected/d1_laws.out" "$work/expected.stripped" "$work/expected.skipped"
strip "$work/run/results/d1_laws.out" "$work/results.stripped" "$work/results.skipped"
# what is excluded must be exactly the echo of role_tables.sql, and only the ECHO switch on the generated side
grep -v '^$' "$d1/role_tables.sql" | cmp -s - "$work/expected.skipped" || { echo "excluded block is not role_tables.sql"; exit 1; }
printf '%s\n' '\set ECHO none' | cmp -s - "$work/results.skipped" || { cat "$work/results.skipped"; echo "generated side printed something while loading"; exit 1; }
if cmp -s "$work/expected.stripped" "$work/results.stripped"; then
  echo "d1_laws on generated rows: same output ($(wc -l < "$work/results.stripped") lines compared; $(wc -l < "$work/expected.skipped") echoed role_tables.sql lines excluded)"
else
  diff -u "$work/expected.stripped" "$work/results.stripped" | head -40; echo "d1_laws on generated rows: DIFFER"; exit 1
fi
