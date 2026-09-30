/*-------------------------------------------------------------------------
 *
 * d0gen.c
 *	  Read-only access to IndexAmRoutine for the D0 generator.
 *
 * Exposes what PostgreSQL already knows about an index AM at runtime:
 * every flag and whether each callback is present, plus strategy ->
 * CompareType translation.  Nothing here knows any AM by name.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/amapi.h"
#include "access/genam.h"
#include "utils/rel.h"
#include "commands/defrem.h"
#include "fmgr.h"
#include "funcapi.h"
#include "utils/builtins.h"
#include "utils/tuplestore.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(d0_am_routine);
PG_FUNCTION_INFO_V1(d0_translate_strategy);
PG_FUNCTION_INFO_V1(d0_default_opclass);
PG_FUNCTION_INFO_V1(d0_can_return);

static void
put(Tuplestorestate *ts, TupleDesc td, const char *kind, const char *name,
	bool value)
{
	Datum		values[3];
	bool		nulls[3] = {false, false, false};

	values[0] = CStringGetTextDatum(kind);
	values[1] = CStringGetTextDatum(name);
	values[2] = BoolGetDatum(value);
	tuplestore_putvalues(ts, td, values, nulls);
}

/*
 * d0_am_routine(amname text) RETURNS TABLE(kind text, name text, value bool)
 */
Datum
d0_am_routine(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	Oid			amoid = get_index_am_oid(text_to_cstring(PG_GETARG_TEXT_PP(0)), false);
	const IndexAmRoutine *r = GetIndexAmRoutineByAmId(amoid, false);
	Tuplestorestate *ts;
	TupleDesc	td;

	InitMaterializedSRF(fcinfo, 0);
	ts = rsinfo->setResult;
	td = rsinfo->setDesc;

#define FLAG(f) put(ts, td, "flag", #f, r->f)
#define CB(f) put(ts, td, "callback", #f, r->f != NULL)
	FLAG(amcanorder);
	FLAG(amcanorderbyop);
	FLAG(amcanhash);
	FLAG(amconsistentequality);
	FLAG(amconsistentordering);
	FLAG(amcanbackward);
	FLAG(amcanunique);
	FLAG(amcanmulticol);
	FLAG(amoptionalkey);
	FLAG(amsearcharray);
	FLAG(amsearchnulls);
	FLAG(amstorage);
	FLAG(amclusterable);
	FLAG(ampredlocks);
	FLAG(amcanparallel);
	FLAG(amcanbuildparallel);
	FLAG(amcaninclude);
	FLAG(amusemaintenanceworkmem);
	FLAG(amsummarizing);
	CB(ambuild);
	CB(ambuildempty);
	CB(aminsert);
	CB(aminsertcleanup);
	CB(ambulkdelete);
	CB(amvacuumcleanup);
	CB(amcanreturn);
	CB(amcostestimate);
	CB(amgettreeheight);
	CB(amoptions);
	CB(amproperty);
	CB(ambuildphasename);
	CB(amvalidate);
	CB(amadjustmembers);
	CB(ambeginscan);
	CB(amrescan);
	CB(amgettuple);
	CB(amgetbitmap);
	CB(amendscan);
	CB(ammarkpos);
	CB(amrestrpos);
	CB(amestimateparallelscan);
	CB(aminitparallelscan);
	CB(amparallelrescan);
	CB(amtranslatestrategy);
	CB(amtranslatecmptype);
	return (Datum) 0;
}

/*
 * d0_translate_strategy(amname text, opfamily oid, strategy int) RETURNS int
 * CompareType of a strategy number, 0 (COMPARE_INVALID) if the AM cannot say.
 */
Datum
d0_translate_strategy(PG_FUNCTION_ARGS)
{
	Oid			amoid = get_index_am_oid(text_to_cstring(PG_GETARG_TEXT_PP(0)), false);

	PG_RETURN_INT32((int) IndexAmTranslateStrategy((StrategyNumber) PG_GETARG_INT32(2),
												   amoid, PG_GETARG_OID(1), true));
}

/*
 * d0_default_opclass(amname text, typ regtype) RETURNS oid
 * The opclass CREATE INDEX would pick for this type, InvalidOid if none.
 */
Datum
d0_default_opclass(PG_FUNCTION_ARGS)
{
	Oid			amoid = get_index_am_oid(text_to_cstring(PG_GETARG_TEXT_PP(0)), false);

	PG_RETURN_OID(GetDefaultOpClass(PG_GETARG_OID(1), amoid));
}

/*
 * d0_can_return(index regclass, attno int) RETURNS bool
 * The AM's own answer (amcanreturn), not the amproperty path.
 */
Datum
d0_can_return(PG_FUNCTION_ARGS)
{
	Relation	rel = index_open(PG_GETARG_OID(0), AccessShareLock);
	bool		res = index_can_return(rel, PG_GETARG_INT32(1));

	index_close(rel, AccessShareLock);
	PG_RETURN_BOOL(res);
}
