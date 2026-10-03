#!/bin/sh
# D3 (V5) stand: an executor scan of the index (a cursor, A2) with a second
# session acting between its FETCHes; A2's rows are compared with the same
# query by a sequential scan under A2's snapshot.  Without and with the
# control layer collect_all (an AM without the scan/VACUUM interlock).
# Subjects marked evidence (a real AM outside this slice) and counts that
# depend on server scheduling go to results/d3_v5_evidence.txt and are not
# compared.  Needs d2proto, python3 with psycopg2 and PyYAML.
set -e
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/results"
psql -X -q -f "$here/setup.sql" postgres > /dev/null 2>&1
: > "$here/results/d3_v5_evidence.txt"
rc=0
check() {
  if diff -u "$here/expected/$1.out" "$here/results/$1.out" > "$here/results/$1.diff"; then
    echo "ok  $1"
  else
    echo "FAILED $1 (see results/$1.diff)"; rc=1
  fi
}
for f in none collect_all; do
  python3 "$here/d3.py" "$here/../protocolspec-v0.yaml" "$here/../concurrencyspec-v0.yaml" "$here/subjects_v5.yaml" \
    --fault $f --evidence "$here/results/d3_v5_evidence.txt" --profile v5 > "$here/results/d3v5_$f.out"
  check d3v5_$f
done
exit $rc
