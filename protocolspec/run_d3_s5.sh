#!/bin/sh
# D3 (S5-concurrent) stand: the s5_concurrent profile of concurrencyspec ->
# histories with mark, restore and a second session acting between
# callbacks -> real callbacks, without and with each S5-concurrent control
# layer; plus the model-level controls (--selftest).  Subjects whose AM has
# no ammarkpos/amrestrpos are reported n/a.  Counts that depend on server
# scheduling go to results/d3_s5_evidence.txt and are not compared.
set -e
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/results"
psql -X -q -f "$here/setup.sql" postgres > /dev/null 2>&1 || { echo "FAILED setup (is the server running?)"; exit 1; }
: > "$here/results/d3_s5_evidence.txt"
rc=0
check() {
  if diff -u "$here/expected/$1.out" "$here/results/$1.out" > "$here/results/$1.diff"; then
    echo "ok  $1"
  else
    echo "FAILED $1 (see results/$1.diff)"; rc=1
  fi
}
d3() {
  python3 "$here/d3.py" "$here/../protocolspec-v0.yaml" "$here/../concurrencyspec-v0.yaml" "$@" --profile s5_concurrent
}
d3 --selftest > "$here/results/d3s5_selftest.out"
check d3s5_selftest
for f in none restore_shift_on_growth restore_lost_on_growth; do
  d3 "$here/subjects_d3.yaml" --fault $f --evidence "$here/results/d3_s5_evidence.txt" > "$here/results/d3s5_$f.out"
  check d3s5_$f
done
exit $rc
