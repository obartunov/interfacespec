#!/bin/sh
# Build, install and run every stable InterfaceSpec gate (D0-D2) against a
# running PostgreSQL server.  Needs: pg_config of that server in PATH (or
# PG_CONFIG), write access to its install directories, a superuser
# connection through PGHOST/PGPORT/PGUSER, python3 with PyYAML.
# See POSTGRESQL.md.
here=$(cd "$(dirname "$0")" && pwd)
PG_CONFIG=${PG_CONFIG:-pg_config}
export PATH="$($PG_CONFIG --bindir):$PATH"
log=$here/check.log
: > "$log"
summary=""
rc=0

gate() {   # gate NAME COMMAND...
    name=$1; shift
    if (cd "$here" && "$@") >> "$log" 2>&1; then
        summary="$summary
  ok      $name"
    else
        summary="$summary
  FAILED  $name"
        rc=1
    fi
}

for ext in opclass_laws d0gen d1laws d2proto; do
    gate "build $ext" sh -c "cd $ext && make -s PG_CONFIG=$PG_CONFIG && make -s install PG_CONFIG=$PG_CONFIG"
done
gate "opclass_laws (btree opclass laws O1-O9)" sh -c "cd opclass_laws && make -s installcheck PG_CONFIG=$PG_CONFIG"
gate "d0gen (D0: btree, hash, GiST)" sh -c "cd d0gen && make -s installcheck PG_CONFIG=$PG_CONFIG"
gate "d1laws (D1: btree, hash, GiST, GIN)" sh -c "cd d1laws && make -s installcheck PG_CONFIG=$PG_CONFIG"
gate "interfacespec v0 round trip" sh interfacespec/check_v0.sh
gate "protocolspec D2 (btree, hash, GiST; 5 modes)" sh protocolspec/run_d2.sh

echo "InterfaceSpec gates against $($PG_CONFIG --version):$summary"
[ $rc -eq 0 ] || echo "details: $log"
exit $rc
