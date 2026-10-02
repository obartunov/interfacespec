# Provenance

InterfaceSpec is a research project led by Oleg Bartunov and developed
interactively with AI coding agents.  Commit metadata preserves the
authorship recorded during the experiments (author and committer
`Claude <noreply@anthropic.com>`, with `Co-Authored-By` trailers); the
history was not rewritten for publication.

This repository was extracted from the working branch in which the
experiments were done; that branch stays the source of provenance.

| | |
|---|---|
| source repository | local PostgreSQL clone (`origin` = https://github.com/postgres/postgres.git) |
| source branch | `btree-invariant-tests` |
| directory | `btree-invariant-work/interface-contracts/` |
| upstream base | `ad36e3608c8` (PostgreSQL master) |
| cut-off | `dcbed57` (D2 final); later work on the branch (D3) is not included |
| extraction | `git filter-repo --subdirectory-filter btree-invariant-work/interface-contracts` on a fresh clone of the branch at `dcbed57` |

The 13 commits between the upstream base and the cut-off touch only that
directory (`git diff --name-only ad36e3608c8 dcbed57` lists nothing else),
so no commit was dropped or merged by the extraction.  For each commit the
standalone tree is identical to the source subtree (tree hashes compared
for all 13).

Commit messages are unchanged and refer to the source repository's
commits and paths where they mention any.

| milestone | source commit | standalone commit | subject |
|---|---|---|---|
| inventory / invariants | `98f8c38` | `37bdeaf` | BT-INV: catalogue of btree Index AM contracts |
| inventory / invariants | `c86656e` | `e8483ff` | opclass_laws: check btree opclass laws on a sample of values |
| inventory / invariants | `87d9d40` | `16f000d` | InterfaceSpec: which BT-INV contracts are expressible without btree |
| inventory / invariants | `84c6d77` | `399c350` | InterfaceSpec: derivation map for contracts vanilla does not test |
| inventory / invariants | `e10c773` | `115d3e7` | InterfaceSpec: value-source input G; split S1/S9 into external and callback parts |
| D0 | `9594e55` | `13c844b` | d0gen: one D0 check generator run on btree, hash and GiST |
| D0 | `9c36958` | `653b713` | d0gen: negative examples for every D0 check; reference plan guard |
| D1 | `b37aae2` | `8d00444` | d1laws: one opclass law engine driven by role tables (btree, hash, GiST) |
| GIN / K3 | `f8e3865` | `29032c5` | d1laws: GIN triConsistent through the same K3 law |
| InterfaceSpec v0 | `e88eac6` | `bda147c` | interfacespec: v0 spec as data, loaded into the d1laws role tables |
| D2 | `d83c0f4` | `4df65ea` | d2proto: generic observer and driver for Index AM scan callbacks |
| D2 | `290829f` | `0dbad1c` | protocolspec: scan callback protocol as data, engine and D2 stand |
| D2 | `dcbed57` | `03fc266` | D2 inventory, protocol model and result |
