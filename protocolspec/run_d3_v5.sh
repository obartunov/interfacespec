#!/bin/sh
# D3 (V5) stand: an executor scan of the index (a cursor, A2) with a second
# session acting between its FETCHes; A2's rows are compared with the same
# query by a sequential scan under A2's snapshot.  Without and with the
# control layer collect_all (an AM without the scan/VACUUM interlock).
# The compared output holds invariants only; counts, counterexamples and
# whatever depends on what VACUUM could clean up go to
# results/d3_v5_evidence.txt.  d3v5_gist_known_violation: a real AM that
# fails the oracle (subjects_v5_known.yaml); it checks that the violation
# still reproduces.  Needs d2proto, python3 with psycopg2 and PyYAML.
set -e
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/results"
psql -X -q -f "$here/setup.sql" postgres > /dev/null 2>&1 || { echo "FAILED setup (is the server running?)"; exit 1; }
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
python3 "$here/d3.py" "$here/../protocolspec-v0.yaml" "$here/../concurrencyspec-v0.yaml" "$here/subjects_v5_known.yaml" \
  --evidence "$here/results/d3_v5_evidence.txt" --profile v5 > "$here/results/d3v5_gist_known_violation.out"
check d3v5_gist_known_violation
exit $rc
