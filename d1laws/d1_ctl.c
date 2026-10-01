/*-------------------------------------------------------------------------
 *
 * d1_ctl.c
 *	  Test-only control functions for D1: a hash opclass on int4 whose
 *	  equality is "equal modulo 1000", and a GiST polygon consistent
 *	  wrapper.  d1_ctl.fault changes exactly one relation:
 *
 *	  eq_nontransitive  equality becomes |a - b| <= 1 (mod 1000): not transitive
 *	  hash_congruence   hash ignores the modulo: equal values, different hashes
 *	  hash_extended     extended hash uses seed + 1: low 32 bits at seed 0 differ
 *	  consistent_exact  consistent reports recheck = false although lossy
 *	  inrange_val       in_range is false at val = 2: breaks only monotonicity in val
 *	  inrange_base      in_range is false at base = 3: breaks only monotonicity in base
 *	  (both only for less = true, sub = false)
 *	  tri_overconfident tsquery triConsistent answers TRUE where it would say MAYBE
 *	  tri_exact_claim   same, but only when no input key is MAYBE (it ignores recheck)
 *	  tri_first_completion  where it would say MAYBE and some input key is
 *	                    MAYBE, answers what it says with every MAYBE key
 *	                    read as absent (only the first completion is right)
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/gin.h"
#include "fmgr.h"
#include "utils/fmgrprotos.h"
#include "utils/guc.h"

PG_MODULE_MAGIC;

enum
{
	F_NONE, F_EQ_NONTRANSITIVE, F_HASH_CONGRUENCE, F_HASH_EXTENDED, F_CONSISTENT_EXACT,
	F_INRANGE_VAL, F_INRANGE_BASE, F_TRI_OVERCONFIDENT, F_TRI_EXACT_CLAIM,
	F_TRI_FIRST_COMPLETION
};

static const struct config_enum_entry fault_options[] = {
	{"none", F_NONE, false},
	{"eq_nontransitive", F_EQ_NONTRANSITIVE, false},
	{"hash_congruence", F_HASH_CONGRUENCE, false},
	{"hash_extended", F_HASH_EXTENDED, false},
	{"consistent_exact", F_CONSISTENT_EXACT, false},
	{"inrange_val", F_INRANGE_VAL, false},
	{"inrange_base", F_INRANGE_BASE, false},
	{"tri_overconfident", F_TRI_OVERCONFIDENT, false},
	{"tri_exact_claim", F_TRI_EXACT_CLAIM, false},
	{"tri_first_completion", F_TRI_FIRST_COMPLETION, false},
	{NULL, 0, false}
};

static int	fault = F_NONE;

void
_PG_init(void)
{
	DefineCustomEnumVariable("d1_ctl.fault", "Relation broken in the D1 control opclasses.",
							 NULL, &fault, F_NONE, fault_options, PGC_USERSET, 0,
							 NULL, NULL, NULL);
	MarkGUCPrefixReserved("d1_ctl");
}

static int32
mod1000(int32 a)
{
	return ((a % 1000) + 1000) % 1000;
}

PG_FUNCTION_INFO_V1(d1ctl_eq);
Datum
d1ctl_eq(PG_FUNCTION_ARGS)
{
	int32		a = mod1000(PG_GETARG_INT32(0));
	int32		b = mod1000(PG_GETARG_INT32(1));

	if (fault == F_EQ_NONTRANSITIVE)
		PG_RETURN_BOOL(abs(a - b) <= 1);
	PG_RETURN_BOOL(a == b);
}

PG_FUNCTION_INFO_V1(d1ctl_hash);
Datum
d1ctl_hash(PG_FUNCTION_ARGS)
{
	int32		a = PG_GETARG_INT32(0);

	return DirectFunctionCall1(hashint4, Int32GetDatum(fault == F_HASH_CONGRUENCE ? a : mod1000(a)));
}

PG_FUNCTION_INFO_V1(d1ctl_hashext);
Datum
d1ctl_hashext(PG_FUNCTION_ARGS)
{
	int32		a = PG_GETARG_INT32(0);
	int64		seed = PG_GETARG_INT64(1);

	return DirectFunctionCall2(hashint4extended, Int32GetDatum(mod1000(a)),
							   Int64GetDatum(fault == F_HASH_EXTENDED ? seed + 1 : seed));
}

PG_FUNCTION_INFO_V1(d1ctl_poly_consistent);
Datum
d1ctl_poly_consistent(PG_FUNCTION_ARGS)
{
	bool	   *recheck = (bool *) PG_GETARG_POINTER(4);
	Datum		r = DirectFunctionCall5(gist_poly_consistent,
										PG_GETARG_DATUM(0), PG_GETARG_DATUM(1),
										PG_GETARG_DATUM(2), PG_GETARG_DATUM(3),
										PointerGetDatum(recheck));

	if (fault == F_CONSISTENT_EXACT)
		*recheck = false;
	return r;
}

/* int4 in_range with an int4 offset; correct unless an inrange_* fault is set */
PG_FUNCTION_INFO_V1(d1ctl_inrange);
Datum
d1ctl_inrange(PG_FUNCTION_ARGS)
{
	int64		val = PG_GETARG_INT32(0);
	int64		base = PG_GETARG_INT32(1);
	int64		off = PG_GETARG_INT32(2);
	bool		sub = PG_GETARG_BOOL(3);
	bool		less = PG_GETARG_BOOL(4);
	int64		bound;
	bool		res;

	if (off < 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PRECEDING_OR_FOLLOWING_SIZE),
				 errmsg("invalid preceding or following size in window function")));
	bound = sub ? base - off : base + off;
	res = less ? val <= bound : val >= bound;
	if (less && !sub)
	{
		/* a constant hole in one argument leaves the other argument monotone */
		if (fault == F_INRANGE_VAL && val == 2)
			res = false;
		if (fault == F_INRANGE_BASE && base == 3)
			res = false;
	}
	PG_RETURN_BOOL(res);
}

/* wraps gin_tsquery_triconsistent (7 args) */
PG_FUNCTION_INFO_V1(d1ctl_tri);
Datum
d1ctl_tri(PG_FUNCTION_ARGS)
{
	GinTernaryValue r = DatumGetGinTernaryValue(
		DirectFunctionCall7Coll(gin_tsquery_triconsistent, PG_GET_COLLATION(),
								PG_GETARG_DATUM(0), PG_GETARG_DATUM(1), PG_GETARG_DATUM(2),
								PG_GETARG_DATUM(3), PG_GETARG_DATUM(4), PG_GETARG_DATUM(5),
								PG_GETARG_DATUM(6)));

	if (fault == F_TRI_OVERCONFIDENT && r == GIN_MAYBE)
		r = GIN_TRUE;
	if (fault == F_TRI_EXACT_CLAIM && r == GIN_MAYBE)
	{
		GinTernaryValue *check = (GinTernaryValue *) PG_GETARG_POINTER(0);
		bool		anymaybe = false;

		for (int i = 0; i < PG_GETARG_INT32(3); i++)
			anymaybe |= (check[i] == GIN_MAYBE);
		if (!anymaybe)
			r = GIN_TRUE;
	}
	if (fault == F_TRI_FIRST_COMPLETION && r == GIN_MAYBE)
	{
		GinTernaryValue *check = (GinTernaryValue *) PG_GETARG_POINTER(0);
		int32		nkeys = PG_GETARG_INT32(3);
		GinTernaryValue *first = palloc_array(GinTernaryValue, nkeys + 1);
		bool		anymaybe = false;
		GinTernaryValue r2;

		for (int i = 0; i < nkeys; i++)
		{
			anymaybe |= (check[i] == GIN_MAYBE);
			first[i] = check[i] == GIN_MAYBE ? GIN_FALSE : check[i];
		}
		r2 = DatumGetGinTernaryValue(
			DirectFunctionCall7Coll(gin_tsquery_triconsistent, PG_GET_COLLATION(),
									PointerGetDatum(first), PG_GETARG_DATUM(1), PG_GETARG_DATUM(2),
									PG_GETARG_DATUM(3), PG_GETARG_DATUM(4), PG_GETARG_DATUM(5),
									PG_GETARG_DATUM(6)));
		if (anymaybe && r2 != GIN_MAYBE)
			r = r2;
	}
	PG_RETURN_GIN_TERNARY_VALUE(r);
}
