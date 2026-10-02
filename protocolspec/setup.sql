-- D2 test data.  bt: 9 btree entries of ~2.6 kB (storage plain), 3 per
-- leaf page, so short histories cross pages.  ht: 4 duplicates in one hash
-- bucket.  gt: points for GiST.  o: outer side with duplicate keys.
DROP DATABASE IF EXISTS d2t;
CREATE DATABASE d2t;
\c d2t
CREATE EXTENSION d2proto;
CREATE TABLE bt (k text);
ALTER TABLE bt ALTER k SET STORAGE PLAIN;
INSERT INTO bt SELECT 'k' || lpad(i::text, 2, '0') || repeat('x', 2600) FROM generate_series(1, 9) i;
CREATE INDEX bt_k ON bt (k);
CREATE TABLE ht (k int4);
INSERT INTO ht SELECT i % 5 FROM generate_series(1, 20) i;
CREATE INDEX ht_k ON ht USING hash (k);
CREATE TABLE gt (p point);
INSERT INTO gt SELECT point(i, i) FROM generate_series(1, 9) i;
CREATE INDEX gt_p ON gt USING gist (p);
CREATE TABLE o (k text, i int4);
INSERT INTO o SELECT k, 1 FROM bt UNION ALL SELECT k, 2 FROM bt;
INSERT INTO o SELECT NULL, i % 5 FROM generate_series(1, 6) i;
VACUUM ANALYZE bt, ht, gt, o;
