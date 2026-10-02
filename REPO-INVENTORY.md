# Repository inventory

Every file of the source directory at the cut-off `dcbed57` (D2 final) is
kept: each one is either a document of the experiments, a spec, an engine,
or a PostgreSQL extension/test the gates need.  Nothing was added from the
PostgreSQL tree; nothing from after the cut-off (D3) is included.

Paths are kept as they were for the first standalone build (the gates use
relative paths between these directories).  "Proposed later" is the layout
for a separate commit after the standalone build is accepted.

| current path (`btree-invariant-work/interface-contracts/…`) | keep? | path now | proposed later | purpose | first commit (source) |
|---|---|---|---|---|---|
| `BT-INV.md` | yes | same | `docs/BT-INV.md` | catalogue of btree Index AM contracts, vanilla coverage, R1–R5 | `98f8c38` |
| `D0-RESULT.md` | yes | same | `experiments/D0-RESULT.md` | D0 result, R6 | `9594e55` |
| `D1-GIN-RESULT.md` | yes | same | `experiments/D1-GIN-RESULT.md` | D1 GIN result | `f8e3865` |
| `D1-RESULT.md` | yes | same | `experiments/D1-RESULT.md` | D1 result (btree, hash, GiST) | `b37aae2` |
| `D2-INVENTORY.md` | yes | same | `experiments/D2-INVENTORY.md` | D2 contracts against source, R7 | `dcbed57` |
| `D2-RESULT.md` | yes | same | `experiments/D2-RESULT.md` | D2 result, R8 | `dcbed57` |
| `DERIVATION-MAP.md` | yes | same | `docs/DERIVATION-MAP.md` | D0–D3 class of each contract | `84c6d77` |
| `GIN-SOURCE.md` | yes | same | `experiments/GIN-SOURCE.md` | GIN source analysis behind D1-GIN-RESULT | `f8e3865` |
| `INTERFACE-GENERALITY.md` | yes | same | `docs/INTERFACE-GENERALITY.md` | which contracts are expressible without btree | `87d9d40` |
| `INTERFACESPEC-EVIDENCE.md` | yes | same | `docs/INTERFACESPEC-EVIDENCE.md` | what D0/D1 required; v0 boundaries | `e88eac6` |
| `PROTOCOL-MODEL.md` | yes | same | `docs/PROTOCOL-MODEL.md` | D2 model: state, obligation, domain, lifetime | `dcbed57` |
| `ROLE-MODEL.md` | yes | same | `docs/ROLE-MODEL.md` | D1 model: roles, laws K1–K6, protocols | `b37aae2` |
| `interfacespec-v0.yaml` | yes | same | `spec/interfacespec-v0.yaml` | InterfaceSpec v0 (D0 capabilities, D1 roles/laws) | `e88eac6` |
| `protocolspec-v0.yaml` | yes | same | `spec/protocolspec-v0.yaml` | D2 scan protocol spec | `290829f` |
| `d0gen/` (7 files) | yes | same | `postgres/d0gen/` | D0 generator extension + regression test | `9594e55` |
| `d1laws/` (9 files) | yes | same | `postgres/d1laws/` | D1 law engine extension, role tables, control opclasses (d1_ctl), regression test | `b37aae2` |
| `d2proto/` (6 files) | yes | same | `postgres/d2proto/` | D2 observer/driver extension, control layers (d2_ctl) | `d83c0f4` |
| `opclass_laws/` (13 files) | yes | same | `postgres/opclass_laws/` | btree opclass law checker + control opclass (ctl_opclass); also needed by the d1laws test | `c86656e` |
| `interfacespec/` (2 files) | yes | same | `engine/interfacespec/` | v0 loader and round-trip check | `e88eac6` |
| `protocolspec/` (10 files) | yes | same | `engine/protocolspec/` | D2 engine, subjects, setup, stand, expected outputs | `290829f` |
| — | new | `README.md`, `POSTGRESQL.md`, `PROVENANCE.md`, `REPO-INVENTORY.md`, `check.sh`, `.gitignore` | same | standalone repo files | — |

Not included: the PostgreSQL source tree (POSTGRESQL.md); D3 files added on
the source branch after `dcbed57` (`concurrencyspec-v0.yaml`,
`protocolspec/d3.py`, `run_d3.sh`, `subjects_d3.yaml`, D3 expected
outputs, D3 tables in `protocolspec/setup.sql`, `D3-S6-RESULT.md`,
`D3-S5-RESULT.md`, the session driver and S6/S5 control layers in
`d2proto/`).
