-- Opclass laws for built-in btree opclasses on edge-value samples.
CREATE EXTENSION IF NOT EXISTS opclass_laws;

SELECT law, status, checked, detail FROM opclass_laws_check('int2_ops',
  '{-32768,-1,0,1,2,32767}'::int2[]);
SELECT law, status, checked, detail FROM opclass_laws_check('int8_ops',
  '{-9223372036854775808,-1,0,1,2,9223372036854775807}'::int8[]);
-- in_range across int2/int4/int8 offsets; base +/- offset overflows at the edges
SELECT law, status, checked, detail FROM opclass_laws_check_inrange('int4_ops',
  '{-2147483648,-5,-1,0,1,5,2147483647}'::int4[], '{0,1,32767}');
SELECT law, status, checked, detail FROM opclass_laws_check('bool_ops', '{false,true}'::bool[]);

SELECT law, status, checked, detail FROM opclass_laws_check('float8_ops',
  '{-Infinity,-1.5,-0,0,1e-300,1,Infinity,NaN}'::float8[]);
SELECT law, status, checked, detail FROM opclass_laws_check_inrange('float8_ops',
  '{-Infinity,-1.5,-0,0,1,Infinity,NaN}'::float8[], '{0,1,Infinity}');

SELECT law, status, checked, detail FROM opclass_laws_check('numeric_ops',
  '{-Infinity,-1,0,0.0,1,1.0,1.00,1e10,Infinity,NaN}'::numeric[]);
SELECT law, status, checked, detail FROM opclass_laws_check_inrange('numeric_ops',
  '{-Infinity,-1,0,1,1.00,Infinity,NaN}'::numeric[], '{0,0.5,Infinity}');

SELECT law, status, checked, detail FROM opclass_laws_check('date_ops',
  '{-infinity,4713-01-01 BC,2000-02-28,2000-02-29,2000-03-01,5874897-12-31,infinity}'::date[]);
SELECT law, status, checked, detail FROM opclass_laws_check_inrange('date_ops',
  '{-infinity,2000-02-28,2000-02-29,2000-03-01,2000-03-31,infinity}'::date[],
  '{0,1 day,1 month,1 year}');

SELECT law, status, checked, detail FROM opclass_laws_check('timestamptz_ops',
  '{-infinity,2000-01-01 00:00:00+00,2000-01-01 00:00:00.000001+00,2000-01-31 00:00:00+00,infinity}'::timestamptz[]);

SELECT law, status, checked, detail FROM opclass_laws_check('interval_ops',
  '{-infinity,0,1 day,24 hours,30 days,1 month,1 year,12 months,infinity}'::interval[]);

SELECT law, status, checked, detail FROM opclass_laws_check('uuid_ops',
  '{00000000-0000-0000-0000-000000000000,00000000-0000-0000-0000-000000000001,ffffffff-ffff-ffff-ffff-ffffffffffff}'::uuid[]);

SELECT law, status, checked, detail FROM opclass_laws_check('jsonb_ops',
  ARRAY['1', '1.0', '"a"', 'null', '[]', '{}', '[1]', '[1.0]', '{"a":1}']::jsonb[]);

-- text under several collations; the sample is the same, the laws are
-- per (opclass, collation)
CREATE TEMP TABLE words(w text);
INSERT INTO words VALUES (''), ('a'), ('A'), ('b'), ('B'), ('ab'), ('Ab'),
  ('a b'), ('1'), ('10'), ('9'), ('Straße'), ('STRASSE'), ('strasse'),
  (U&'\00E9'), (U&'e\0301'), ('e'), ('f');
CREATE COLLATION ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);

SELECT 'C' AS coll, law, status, detail FROM opclass_laws_check('text_ops',
  (SELECT array_agg(w COLLATE "C") FROM words));
SELECT 'und-x-icu' AS coll, law, status, detail FROM opclass_laws_check('text_ops',
  (SELECT array_agg(w COLLATE "und-x-icu") FROM words));
SELECT 'pg_unicode_fast' AS coll, law, status, detail FROM opclass_laws_check('text_ops',
  (SELECT array_agg(w COLLATE pg_unicode_fast) FROM words));
SELECT 'ci' AS coll, law, status, detail FROM opclass_laws_check('text_ops',
  (SELECT array_agg(w COLLATE ci) FROM words));

-- a law checked on no pairs is reported as empty, not pass
SELECT law, status FROM opclass_laws_check('int4_ops', '{42}'::int4[]) WHERE law LIKE 'O2%';

-- type mismatch is refused
SELECT * FROM opclass_laws_check('int4_ops', '{1,2}'::int8[]);
