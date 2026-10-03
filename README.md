# InterfaceSpec

Executable behavioral contracts for PostgreSQL extensibility interfaces.

PostgreSQL extension interfaces describe how callbacks are called, but much
of their behavioral contract exists only in documentation, implementation
assumptions, and tests.  InterfaceSpec explores whether those contracts can
be made machine-readable and executable.  The first subject is the Index
Access Method interface (`IndexAmRoutine`, operator classes).

Research prototype.  PostgreSQL itself is the system under test and is not
part of this repository (POSTGRESQL.md).

## Layers

    metadata/reference          D0   what existing catalog/IndexAmRoutine metadata
            |                        already implies, checked against a seqscan
    semantic laws               D1   operator class laws
            |
    callback protocol           D2   order of callbacks, state, lifetime of results
            |
    concurrency                 D3   a second session between callbacks; allowed outcomes (S6)

D1: a check is generated, not written per AM:

    semantic law
    + role binding
    + call protocol
    + value source
    = generated check

D2:

    protocol spec
        -> state machine
        -> generated histories
        -> real PostgreSQL callbacks
        -> conformance result

## Status

Tested against PostgreSQL master `ad36e3608c8` (20devel).  Coverage differs
by layer; not every AM went through every layer.

| layer | btree | hash | GiST | GIN |
|---|---|---|---|---|
| D0 metadata + reference (`d0gen`) | yes | yes | yes | — |
| D1 laws (`d1laws`) | O1–O9, 5 opclasses/collations | H1–H6, 2 opclasses | G1, `poly_ops` | N1 (triConsistent via K3), `tsvector_ops` |
| D1 btree-specific checker (`opclass_laws`) | O1–O9 | — | — | — |
| D2 protocol (`protocolspec`) | S4, S5 (one session), S7, S8 | S4, S8 | S4 (forward only), S7, S8 | — (no `amgettuple`) |
| D3 concurrency (`concurrencyspec`, `check_d3.sh`) | S6 (plain and index-only scan) | S6 | S6 | — |
| D3 concurrent mark/restore (`check_d3_s5.sh`) | S5 + S6, plain and index-only | n/a | n/a | — |

Each layer has control variants that break one property and must be caught;
see the result documents.  Discrepancies between documentation and
implementation found so far are recorded as R1–R8 (BT-INV.md, D0-RESULT.md,
D2-INVENTORY.md, D2-RESULT.md); none of them changes a query result.

## Running

    ./check.sh     	# builds and installs the extensions, runs the D0–D2 gates
    ./check_d3.sh   	# D3 (S6); needs python3-psycopg2
    ./check_d3_s5.sh    # D3/S5 concurrent mark/restore

Prerequisites: POSTGRESQL.md.

## Where things are

| path | what |
|---|---|
| `BT-INV.md`, `INTERFACE-GENERALITY.md`, `DERIVATION-MAP.md` | contract catalogue (btree first), which contracts are expressible without btree, which layer can derive each |
| `ROLE-MODEL.md`, `PROTOCOL-MODEL.md`, `INTERFACESPEC-EVIDENCE.md` | the models and what the experiments actually required |
| `D0-RESULT.md`, `D1-RESULT.md`, `D1-GIN-RESULT.md`, `GIN-SOURCE.md`, `D2-INVENTORY.md`, `D2-RESULT.md` | experiment results |
| `interfacespec-v0.yaml`, `protocolspec-v0.yaml` | the specs |
| `interfacespec/` | v0 loader and round-trip check |
| `protocolspec/` | D2 engine, subjects, stand |
| `opclass_laws/`, `d0gen/`, `d1laws/`, `d2proto/` | PostgreSQL extensions (checkers, observer/driver, control opclasses and layers) |

## Authorship and license

InterfaceSpec is a research project led by Oleg Bartunov and developed
interactively with AI coding agents; commit metadata preserves the
authorship recorded during the experiments (PROVENANCE.md).  PostgreSQL
License (LICENSE).
