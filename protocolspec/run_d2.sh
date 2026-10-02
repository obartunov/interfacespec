#!/bin/sh
# D2 stand: protocolspec-v0.yaml -> engine -> real callbacks, without and
# with each control layer.  Needs d2proto installed; server on PGPORT.
set -e
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/results"
psql -X -q -f "$here/setup.sql" postgres > /dev/null 2>&1
rc=0
for f in none itup_shared dir_from_start restore_once caller_more_keys; do
  PGDATABASE=d2t python3 "$here/engine.py" "$here/../protocolspec-v0.yaml" "$here/subjects.yaml" --fault $f > "$here/results/d2_$f.out"
  if diff -u "$here/expected/d2_$f.out" "$here/results/d2_$f.out" > "$here/results/d2_$f.diff"; then
    echo "ok  $f"
  else
    echo "FAILED $f (see results/d2_$f.diff)"; rc=1
  fi
done
exit $rc
