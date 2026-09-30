/*-------------------------------------------------------------------------
 *
 * ctl_opclass.c
 *	  Test-only control opclass on int4 with injectable law violations.
 *
 * One opclass, ctl_int4_ops, whose support functions and operators obey
 * every btree opclass law when ctl_opclass.fault = 'none' and break a
 * chosen law otherwise.  It exists to show that each check in
 * opclass_laws is not vacuous.  Never build an index on it.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>

#include "fmgr.h"
#include "utils/guc.h"
#include "utils/skipsupport.h"
#include "utils/sortsupport.h"

PG_MODULE_MAGIC;

typedef enum
{
	F_NONE,
	F_CMP_IRREFLEXIVE,
	F_CMP_ASYMMETRIC,
	F_CMP_NONTRANSITIVE,
	F_OP_DISAGREE,
	F_SORTSUPPORT,
	F_ABBREV,
	F_EQUALIMAGE,
	F_INRANGE,
	F_SKIP,
	F_SKIP_SYMMETRIC,
} CtlFault;

static const struct config_enum_entry fault_options[] = {
	{"none", F_NONE, false},
	{"cmp_irreflexive", F_CMP_IRREFLEXIVE, false},
	{"cmp_asymmetric", F_CMP_ASYMMETRIC, false},
	{"cmp_nontransitive", F_CMP_NONTRANSITIVE, false},
	{"op_disagree", F_OP_DISAGREE, false},
	{"sortsupport", F_SORTSUPPORT, false},
	{"abbrev", F_ABBREV, false},
	{"equalimage", F_EQUALIMAGE, false},
	{"inrange", F_INRANGE, false},
	{"skip", F_SKIP, false},
	{"skip_symmetric", F_SKIP_SYMMETRIC, false},
	{NULL, 0, false}
};

static int	fault = F_NONE;

void
_PG_init(void)
{
	DefineCustomEnumVariable("ctl_opclass.fault",
							 "Law violation injected into ctl_int4_ops.",
							 NULL, &fault, F_NONE, fault_options,
							 PGC_USERSET, 0, NULL, NULL, NULL);
	MarkGUCPrefixReserved("ctl_opclass");
}

#define COLLAPSED	1000001		/* compares equal to 1000000 under F_EQUALIMAGE */

static int32
key(int32 x)
{
	return (fault == F_EQUALIMAGE && x == COLLAPSED) ? COLLAPSED - 1 : x;
}

static int
sgn64(int64 x)
{
	return (x > 0) - (x < 0);
}

static int
core_cmp(int32 a, int32 b)
{
	switch (fault)
	{
		case F_CMP_IRREFLEXIVE:
			if (a == b && (a & 1))
				return -1;
			break;
		case F_CMP_ASYMMETRIC:
			if (a != b && a < 0 && b < 0)
				return -1;
			break;
		case F_CMP_NONTRANSITIVE:
			{
				int			ra = ((a % 3) + 3) % 3;
				int			rb = ((b % 3) + 3) % 3;

				if (ra != rb)	/* rock-paper-scissors on residues */
					return ((rb - ra + 3) % 3 == 1) ? -1 : 1;
				break;
			}
		default:
			break;
	}
	return sgn64((int64) key(a) - (int64) key(b));
}

PG_FUNCTION_INFO_V1(ctl_cmp);
Datum
ctl_cmp(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(core_cmp(PG_GETARG_INT32(0), PG_GETARG_INT32(1)));
}

#define CTL_OP(name, expr) \
PG_FUNCTION_INFO_V1(name); \
Datum \
name(PG_FUNCTION_ARGS) \
{ \
	int32 a = PG_GETARG_INT32(0); \
	int r = core_cmp(a, PG_GETARG_INT32(1)); \
	bool res = (expr); \
	if (fault == F_OP_DISAGREE && a == 0) \
		res = !res; \
	PG_RETURN_BOOL(res); \
}

CTL_OP(ctl_lt, r < 0)
CTL_OP(ctl_le, r <= 0)
CTL_OP(ctl_eq, r == 0)
CTL_OP(ctl_ge, r >= 0)
CTL_OP(ctl_gt, r > 0)

static int
ss_cmp(Datum x, Datum y, SortSupport ssup)
{
	int32		a = DatumGetInt32(x);
	int32		b = DatumGetInt32(y);
	int			r = core_cmp(a, b);

	if (fault == F_SORTSUPPORT && a < 0 && b < 0)
		r = -r;
	return r;
}

static Datum
abbrev_convert(Datum original, SortSupport ssup)
{
	int32		a = DatumGetInt32(original);

	return Int32GetDatum(fault == F_ABBREV ? a % 1000 : a);
}

static int
abbrev_cmp(Datum x, Datum y, SortSupport ssup)
{
	return sgn64((int64) DatumGetInt32(x) - (int64) DatumGetInt32(y));
}

static bool
abbrev_abort(int memtupcount, SortSupport ssup)
{
	return false;
}

PG_FUNCTION_INFO_V1(ctl_sortsupport);
Datum
ctl_sortsupport(PG_FUNCTION_ARGS)
{
	SortSupport ssup = (SortSupport) PG_GETARG_POINTER(0);

	ssup->comparator = ss_cmp;
	/* abbreviation is order-preserving only while the order is plain int4 */
	if (ssup->abbreviate && (fault == F_NONE || fault == F_ABBREV))
	{
		ssup->comparator = abbrev_cmp;
		ssup->abbrev_converter = abbrev_convert;
		ssup->abbrev_abort = abbrev_abort;
		ssup->abbrev_full_comparator = ss_cmp;
	}
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(ctl_equalimage);
Datum
ctl_equalimage(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(true);
}

PG_FUNCTION_INFO_V1(ctl_inrange);
Datum
ctl_inrange(PG_FUNCTION_ARGS)
{
	int64		val = key(PG_GETARG_INT32(0));
	int64		base = key(PG_GETARG_INT32(1));
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
	if (fault == F_INRANGE && less && !sub && val == bound + 2)
		res = true;
	PG_RETURN_BOOL(res);
}

static Datum
ctl_increment(Relation rel, Datum existing, bool *overflow)
{
	int32		a = key(DatumGetInt32(existing));
	int32		r;

	if (a == INT_MAX)
	{
		*overflow = true;
		return (Datum) 0;
	}
	r = ((fault == F_SKIP || fault == F_SKIP_SYMMETRIC) && a < INT_MAX - 1) ? a + 2 : a + 1;
	if (fault == F_EQUALIMAGE && r == COLLAPSED)
		r++;
	return Int32GetDatum(r);
}

static Datum
ctl_decrement(Relation rel, Datum existing, bool *overflow)
{
	int32		a = key(DatumGetInt32(existing));
	int32		r;

	if (a == INT_MIN)
	{
		*overflow = true;
		return (Datum) 0;
	}
	/* F_SKIP_SYMMETRIC: dec(inc(a)) = a still holds, only the gap shows */
	r = (fault == F_SKIP_SYMMETRIC && a > INT_MIN + 1) ? a - 2 : a - 1;
	if (fault == F_EQUALIMAGE && r == COLLAPSED)
		r--;
	return Int32GetDatum(r);
}

PG_FUNCTION_INFO_V1(ctl_skipsupport);
Datum
ctl_skipsupport(PG_FUNCTION_ARGS)
{
	SkipSupport sksup = (SkipSupport) PG_GETARG_POINTER(0);

	sksup->decrement = ctl_decrement;
	sksup->increment = ctl_increment;
	sksup->low_elem = Int32GetDatum(INT_MIN);
	sksup->high_elem = Int32GetDatum(INT_MAX);
	PG_RETURN_VOID();
}
