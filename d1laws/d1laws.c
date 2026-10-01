/*-------------------------------------------------------------------------
 *
 * d1laws.c
 *	  Invocation for the D1 law engine.
 *
 * d1_invoke_*: call any function by OID with the caller's collation, so a
 * role is never re-resolved by name (in_range and friends are overloaded).
 *
 * Protocol adapters: support functions with an internal-typed signature
 * cannot be called from SQL.  Each adapter knows one calling convention
 * (SortSupport, abbreviated keys, SkipSupport, index-entry consistent);
 * it does not know which AM or opclass it serves.  The role table names
 * the protocol; the engine never does.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/gist.h"
#include "access/htup_details.h"
#include "fmgr.h"
#include "funcapi.h"
#include "storage/bufpage.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/lsyscache.h"
#include "utils/skipsupport.h"
#include "utils/sortsupport.h"

PG_MODULE_MAGIC;

/* ---- plain invocation by OID ---- */

/*
 * Call function PG_GETARG_OID(0) with arguments skip+1..; the skipped
 * arguments only carry the input collation (for functions whose own
 * arguments are not collatable, e.g. equalimage(oid)).
 */
static Datum
invoke(FunctionCallInfo fcinfo, int skip, Oid *rettype)
{
	Oid			fn = PG_GETARG_OID(0);
	int			nargs = PG_NARGS() - 1 - skip;
	FmgrInfo	flinfo;
	LOCAL_FCINFO(call, FUNC_MAX_ARGS);
	Datum		result;

	fmgr_info(fn, &flinfo);
	InitFunctionCallInfoData(*call, &flinfo, nargs, PG_GET_COLLATION(), NULL, NULL);
	for (int i = 0; i < nargs; i++)
	{
		call->args[i].value = PG_GETARG_DATUM(i + 1 + skip);
		call->args[i].isnull = PG_ARGISNULL(i + 1 + skip);
	}
	result = FunctionCallInvoke(call);
	if (call->isnull)
		elog(ERROR, "function %u returned NULL", fn);
	*rettype = get_func_rettype(fn);
	return result;
}

PG_FUNCTION_INFO_V1(d1_invoke_int8);
Datum
d1_invoke_int8(PG_FUNCTION_ARGS)
{
	Oid			rt;
	Datum		d = invoke(fcinfo, 0, &rt);

	switch (rt)
	{
		case INT2OID:
			PG_RETURN_INT64(DatumGetInt16(d));
		case INT4OID:
			PG_RETURN_INT64(DatumGetInt32(d));
		case INT8OID:
			PG_RETURN_INT64(DatumGetInt64(d));
		default:
			elog(ERROR, "d1_invoke_int8: unsupported return type %s", format_type_be(rt));
	}
	PG_RETURN_NULL();
}

static Datum
invoke_bool(FunctionCallInfo fcinfo, int skip)
{
	Oid			rt;
	Datum		d = invoke(fcinfo, skip, &rt);

	if (rt != BOOLOID)
		elog(ERROR, "d1_invoke_bool: function returns %s", format_type_be(rt));
	return d;
}

PG_FUNCTION_INFO_V1(d1_invoke_bool);
Datum
d1_invoke_bool(PG_FUNCTION_ARGS)
{
	return invoke_bool(fcinfo, 0);
}

/* d1_invoke_guard(fn, collation_carrier anyelement, VARIADIC args) */
PG_FUNCTION_INFO_V1(d1_invoke_guard);
Datum
d1_invoke_guard(PG_FUNCTION_ARGS)
{
	return invoke_bool(fcinfo, 1);
}

/* ---- image equality: not a role, a property of the datum ---- */

PG_FUNCTION_INFO_V1(d1_image_eq);
Datum
d1_image_eq(PG_FUNCTION_ARGS)
{
	Oid			t = get_fn_expr_argtype(fcinfo->flinfo, 0);
	int16		len;
	bool		byval;

	get_typlenbyval(t, &len, &byval);
	PG_RETURN_BOOL(datum_image_eq(PG_GETARG_DATUM(0), PG_GETARG_DATUM(1), byval, len));
}

/* ---- protocol: sortsupport (alternate comparator) ---- */

static void
init_ssup(SortSupport ssup, Oid proc, Oid coll, bool abbreviate)
{
	memset(ssup, 0, sizeof(SortSupportData));
	ssup->ssup_cxt = CurrentMemoryContext;
	ssup->ssup_collation = coll;
	ssup->abbreviate = abbreviate;
	OidFunctionCall1(proc, PointerGetDatum(ssup));
}

PG_FUNCTION_INFO_V1(d1_sortsupport_cmp);
Datum
d1_sortsupport_cmp(PG_FUNCTION_ARGS)
{
	SortSupportData ss;

	init_ssup(&ss, PG_GETARG_OID(0), PG_GET_COLLATION(), false);
	PG_RETURN_INT32(ss.comparator(PG_GETARG_DATUM(1), PG_GETARG_DATUM(2), &ss));
}

/* ---- protocol: abbreviated keys (approximate comparator) ----
 * Returns d1_approx(answer, flag): answer = sign of the abbreviated
 * comparison (0 = could not tell), flag unused (false).  NULL when the
 * opclass declines abbreviation.
 */
static Datum
approx_result(FunctionCallInfo fcinfo, int answer, bool flag)
{
	TupleDesc	td;
	Datum		values[2];
	bool		nulls[2] = {false, false};

	if (get_call_result_type(fcinfo, NULL, &td) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "d1_approx result type expected");
	td = BlessTupleDesc(td);
	values[0] = Int32GetDatum(answer);
	values[1] = BoolGetDatum(flag);
	return HeapTupleGetDatum(heap_form_tuple(td, values, nulls));
}

/*
 * Same signature as every approx adapter:
 * (proc oid, aux oid, x anyelement, q "any", strategy int, subtype oid);
 * aux, strategy and subtype are unused here.
 */
PG_FUNCTION_INFO_V1(d1_abbrev_cmp);
Datum
d1_abbrev_cmp(PG_FUNCTION_ARGS)
{
	SortSupportData ss;
	Datum		a,
				b;
	int			r;

	init_ssup(&ss, PG_GETARG_OID(0), PG_GET_COLLATION(), true);
	if (ss.abbrev_converter == NULL)
		PG_RETURN_NULL();
	a = ss.abbrev_converter(PG_GETARG_DATUM(2), &ss);
	b = ss.abbrev_converter(PG_GETARG_DATUM(3), &ss);
	r = ss.comparator(a, b, &ss);
	return approx_result(fcinfo, (r > 0) - (r < 0), false);
}

/* ---- protocol: skipsupport (successor) ---- */

static SkipSupport
get_skip(Oid proc)
{
	SkipSupport s = palloc0_object(SkipSupportData);

	OidFunctionCall1(proc, PointerGetDatum(s));
	return s;
}

PG_FUNCTION_INFO_V1(d1_skip_bound);
Datum
d1_skip_bound(PG_FUNCTION_ARGS)
{
	SkipSupport s = get_skip(PG_GETARG_OID(0));
	char	   *which = text_to_cstring(PG_GETARG_TEXT_PP(2));

	PG_RETURN_DATUM(strcmp(which, "low") == 0 ? s->low_elem : s->high_elem);
}

/* NULL when the step overflows the domain */
PG_FUNCTION_INFO_V1(d1_skip_step);
Datum
d1_skip_step(PG_FUNCTION_ARGS)
{
	SkipSupport s = get_skip(PG_GETARG_OID(0));
	char	   *dir = text_to_cstring(PG_GETARG_TEXT_PP(2));
	bool		overflow = false;
	Datum		r;

	/* rel is NULL: skipsupport.h does not promise it may be; built-ins ignore it */
	r = (strcmp(dir, "up") == 0 ? s->increment : s->decrement) (NULL, PG_GETARG_DATUM(1), &overflow);
	if (overflow)
		PG_RETURN_NULL();
	PG_RETURN_DATUM(r);
}

/* ---- protocol: index-entry consistent (with optional entry transform) ----
 * d1_entry_consistent(consistent oid, transform oid, x anyelement, q "any",
 *					   strategy int, subtype oid) RETURNS d1_approx
 * answer = consistent's result (0/1), flag = recheck.  x becomes a leaf
 * entry on a leaf page, passed through the transform (compress) if given.
 */
PG_FUNCTION_INFO_V1(d1_entry_consistent);
Datum
d1_entry_consistent(PG_FUNCTION_ARGS)
{
	Oid			consistent = PG_GETARG_OID(0);
	Oid			transform = PG_GETARG_OID(1);
	GISTENTRY	e;
	GISTENTRY  *entry = &e;
	Page		page = palloc0(BLCKSZ);
	bool		recheck = false;
	bool		res;

	/* a leaf page, so GIST_LEAF(entry) holds for consistent functions */
	PageInit(page, BLCKSZ, sizeof(GISTPageOpaqueData));
	GistPageGetOpaque(page)->flags = F_LEAF;

	gistentryinit(e, PG_GETARG_DATUM(2), NULL, page, 0, true);
	if (OidIsValid(transform))
	{
		entry = (GISTENTRY *) DatumGetPointer(OidFunctionCall1(transform, PointerGetDatum(&e)));
		entry->page = page;
	}
	res = DatumGetBool(OidFunctionCall5Coll(consistent, PG_GET_COLLATION(),
											PointerGetDatum(entry),
											PG_GETARG_DATUM(3),
											UInt16GetDatum((uint16) PG_GETARG_INT32(4)),
											ObjectIdGetDatum(PG_GETARG_OID(5)),
											PointerGetDatum(&recheck)));
	return approx_result(fcinfo, res ? 1 : 0, recheck);
}
