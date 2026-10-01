-- Role tables and law instances: the only place that knows which support
-- function number or strategy number plays which role.  Data for the D1
-- engine; not part of it.

-- btree: fixed numbers, so the table is per AM (family NULL)
INSERT INTO d1_role (am, family, role, source, number, protocol, attr, righttype) VALUES
  ('btree', NULL, 'comparator',             'proc', 1, 'plain',       NULL, 'same'),
  ('btree', NULL, 'alternate_comparator',   'proc', 2, 'sortsupport', NULL, 'same'),
  ('btree', NULL, 'approximate_comparator', 'proc', 2, 'abbrev',      NULL, 'same'),
  ('btree', NULL, 'range_predicate',        'proc', 3, 'plain',       NULL, 'any'),
  ('btree', NULL, 'image_equivalence',      'proc', 4, 'plain',       NULL, 'same'),
  ('btree', NULL, 'successor',              'proc', 6, 'skipsupport', NULL, 'same'),
  ('btree', NULL, 'ordering_operator',      'op',   1, 'plain', 'lt', 'same'),
  ('btree', NULL, 'ordering_operator',      'op',   2, 'plain', 'le', 'same'),
  ('btree', NULL, 'ordering_operator',      'op',   3, 'plain', 'eq', 'same'),
  ('btree', NULL, 'ordering_operator',      'op',   4, 'plain', 'ge', 'same'),
  ('btree', NULL, 'ordering_operator',      'op',   5, 'plain', 'gt', 'same');

INSERT INTO d1_law (am, family, law, kind, params) VALUES
  ('btree', NULL, 'O1', 'K1', '{"role": "comparator", "property": "reflexive"}'),
  ('btree', NULL, 'O2', 'K1', '{"role": "comparator", "property": "antisymmetric"}'),
  ('btree', NULL, 'O3', 'K1', '{"role": "comparator", "property": "transitive"}'),
  ('btree', NULL, 'O4', 'K2', '{"a": "comparator", "b": "ordering_operator", "relation": "sign_matches_relation"}'),
  ('btree', NULL, 'O5', 'K2', '{"a": "comparator", "b": "alternate_comparator", "relation": "same_sign"}'),
  ('btree', NULL, 'O6', 'K3', '{"approx": "approximate_comparator", "reference": "comparator", "trusted": "nonzero_answer"}'),
  ('btree', NULL, 'O7', 'K4', '{"premise": "comparator", "consequence": "image", "guard": "image_equivalence", "iff": true}'),
  ('btree', NULL, 'O8', 'K5', '{"role": "range_predicate", "order": "comparator"}'),
  ('btree', NULL, 'O9', 'K6', '{"role": "successor", "order": "comparator"}');

-- hash: fixed numbers, per AM
INSERT INTO d1_role (am, family, role, source, number, protocol, attr, righttype) VALUES
  ('hash', NULL, 'equality',      'op',   1, 'plain', NULL, 'same'),
  ('hash', NULL, 'hash',          'proc', 1, 'plain', NULL, 'same'),
  ('hash', NULL, 'extended_hash', 'proc', 2, 'plain', NULL, 'same');

INSERT INTO d1_law (am, family, law, kind, params) VALUES
  ('hash', NULL, 'H1', 'K1', '{"role": "equality", "property": "reflexive"}'),
  ('hash', NULL, 'H2', 'K1', '{"role": "equality", "property": "symmetric"}'),
  ('hash', NULL, 'H3', 'K1', '{"role": "equality", "property": "transitive"}'),
  ('hash', NULL, 'H4', 'K4', '{"premise": "equality", "consequence": "hash"}'),
  ('hash', NULL, 'H5', 'K4', '{"premise": "equality", "consequence": "extended_hash", "seed": 42}'),
  ('hash', NULL, 'H6', 'K2', '{"a": "hash", "b": "extended_hash", "relation": "low32_equal", "seed": 0}');

-- GiST: strategy meaning is per opclass, so the table is per family.
-- poly_ops: leaf entries are bounding boxes (compress), consistent is
-- evaluated on boxes and always asks for recheck (gistproc.c, gist_poly_consistent).
INSERT INTO d1_role (am, family, role, source, number, protocol, attr, righttype) VALUES
  ('gist', 'poly_ops', 'consistent',          'proc', 1,    'entry_consistent', NULL, 'same'),
  ('gist', 'poly_ops', 'entry_transform',     'proc', 3,    'plain',            NULL, 'same'),
  ('gist', 'poly_ops', 'reference_predicate', 'op',   NULL, 'plain',            NULL, 'same');

INSERT INTO d1_law (am, family, law, kind, params) VALUES
  ('gist', 'poly_ops', 'G1', 'K3', '{"approx": "consistent", "aux": "entry_transform", "reference": "reference_predicate", "trusted": "false_or_exact"}');

-- GIN: support numbers are fixed per AM, and this law needs no strategy
-- meaning (it enumerates every search strategy), so the table is per AM.
-- query_context gives the key count; consistent is the reference.
INSERT INTO d1_role (am, family, role, source, number, protocol, attr, righttype) VALUES
  ('gin', NULL, 'query_context',   'proc', 3,    'key_vector',      NULL, 'same'),
  ('gin', NULL, 'consistent',      'proc', 4,    'key_vector_bool', NULL, 'same'),
  ('gin', NULL, 'tri_consistent',  'proc', 6,    'key_vector_tri',  NULL, 'same'),
  ('gin', NULL, 'search_strategy', 'op',   NULL, 'plain',           NULL, 'any');

INSERT INTO d1_law (am, family, law, kind, params) VALUES
  ('gin', NULL, 'N1', 'K3', '{"approx": "tri_consistent", "aux": "query_context", "reference": "consistent", "trusted": "false_or_exact", "source": "ternary_completions", "arity": "query_context", "strategies": "search_strategy"}');
