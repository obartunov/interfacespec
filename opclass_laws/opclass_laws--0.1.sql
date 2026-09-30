\echo Use "CREATE EXTENSION opclass_laws" to load this file. \quit

-- Laws O1-O7, O9 of BT-INV.md over a sample of the opclass input type.
-- Collation is taken from the sample expression (use COLLATE on it).
-- Only the first max_n values are used (pair laws cost O(n^2)), and the
-- first max_triple_n for transitivity (O(n^3)).
CREATE FUNCTION opclass_laws_check(opclass text, sample anyarray,
                                   max_n int DEFAULT 1000,
                                   max_triple_n int DEFAULT 200)
RETURNS TABLE(law text, status text, checked bigint, detail text)
AS 'MODULE_PATHNAME', 'opclass_laws_check'
LANGUAGE C STRICT;

-- Law O8 for every in_range proc of the family; offsets as text in the
-- offset type's input syntax.
-- O(n^3) per offset and (sub, less): max_n defaults low.
CREATE FUNCTION opclass_laws_check_inrange(opclass text, sample anyarray,
                                           offsets text[],
                                           max_n int DEFAULT 50)
RETURNS TABLE(law text, status text, checked bigint, detail text)
AS 'MODULE_PATHNAME', 'opclass_laws_check_inrange'
LANGUAGE C STRICT;
