#!/bin/sh
# D3 (S6) stand: concurrencyspec + protocolspec -> histories with a second
# session acting between callbacks -> real callbacks, without and with each
# S6 control layer; plus the model-level controls (--selftest).
# Counts that depend on server scheduling go to results/d3_evidence.txt and
# are not compared.  Needs d2proto, python3 with psycopg2 and PyYAML.
set -e
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/results"
psql -X -q -f "$here/setup.sql" postgres > /dev/null 2>&1
: > "$here/results/d3_evidence.txt"
rc=0
check() {
  if diff -u "$here/expected/$1.out" "$here/results/$1.out" > "$here/results/$1.diff"; then
    echo "ok  $1"
  else
    echo "FAILED $1 (see results/$1.diff)"; rc=1
  fi
}
python3 "$here/d3.py" "$here/../protocolspec-v0.yaml" "$here/../concurrencyspec-v0.yaml" --selftest > "$here/results/d3_selftest.out"
check d3_selftest
for f in none skip_after_growth repeat_after_growth skip_invisible; do
  python3 "$here/d3.py" "$here/../protocolspec-v0.yaml" "$here/../concurrencyspec-v0.yaml" "$here/subjects_d3.yaml" \
    --fault $f --evidence "$here/results/d3_evidence.txt" > "$here/results/d3_$f.out"
  check d3_$f
done
exit $rc
