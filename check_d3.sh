#!/bin/sh
# D3 gate (S6), separate from the stable D0-D2 gates in check.sh.  Same
# prerequisites as check.sh, plus python3-psycopg2; d2proto must be built
# and installed (check.sh does that).
here=$(cd "$(dirname "$0")" && pwd)
PG_CONFIG=${PG_CONFIG:-pg_config}
export PATH="$($PG_CONFIG --bindir):$PATH"
log=$here/check_d3.log
if (cd "$here/d2proto" && make -s PG_CONFIG=$PG_CONFIG && make -s install PG_CONFIG=$PG_CONFIG) > "$log" 2>&1 &&
   sh "$here/protocolspec/run_d3.sh" >> "$log" 2>&1; then
    echo "InterfaceSpec D3 gate against $($PG_CONFIG --version):"
    sed 's/^/  /' "$log" | grep -E '^  (ok|FAILED)'
    echo "  scheduling-dependent counts: protocolspec/results/d3_evidence.txt"
    exit 0
fi
echo "InterfaceSpec D3 gate against $($PG_CONFIG --version):"
sed 's/^/  /' "$log" | grep -E '^  (ok|FAILED)'
echo "details: $log"
exit 1
