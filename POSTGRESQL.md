# PostgreSQL dependency

PostgreSQL is the system under test; it is not vendored.

| | |
|---|---|
| tested upstream commit | `ad36e3608c8cb6f0848737ec81e548d4d3a0af3c` (master, "Fix tuple search during apply after concurrent index DDL.") |
| version | PostgreSQL 20devel |
| build | `--enable-cassert --enable-debug --with-icu` |

The InterfaceSpec branch in the source repository changed no PostgreSQL
file: `git diff --name-only ad36e3608c8 <D2 final>` outside the InterfaceSpec
directory is empty (PROVENANCE.md).  A plain upstream build at that commit
is what the gates ran against.

## From scratch

    git clone https://github.com/postgres/postgres.git
    cd postgres
    git checkout ad36e3608c8cb6f0848737ec81e548d4d3a0af3c
    ./configure --prefix=$HOME/pg-is --enable-cassert --enable-debug --with-icu
    make -j8 && make install

    $HOME/pg-is/bin/initdb -D $HOME/pg-is-data -U postgres
    $HOME/pg-is/bin/pg_ctl -D $HOME/pg-is-data -o '-p 5433' -l $HOME/pg-is.log start

    git clone <interfacespec>
    cd interfacespec
    PG_CONFIG=$HOME/pg-is/bin/pg_config PGHOST=/tmp PGPORT=5433 PGUSER=postgres ./check.sh

Needs ICU (`d1laws` uses a nondeterministic ICU collation), python3 with
PyYAML (`interfacespec/`, `protocolspec/`).  `--enable-cassert` matters:
the D2 notes rely on `index_rescan`'s assertion (R7), and the observer was
developed under it.
