/*-------------------------------------------------------------------------
 *
 * opclass_laws.c
 *	  Check btree opclass laws on a sample of values.
 *
 * The laws are the ones btree.sgml and sortsupport.h/skipsupport.h state
 * for opclass support functions.  btvalidate() checks only signatures and
 * presence; nothing in core checks behaviour.  Law identifiers (O1..O9)
 * match BT-INV.md.
 *
 * The sample is any array of the opclass input type, e.g. array_agg() over
 * a TABLESAMPLE of a real column, so the check runs against values and a
 * collation actually in use.  A passing result is a statement about that
 * sample only.  Pair laws cost O(n^2) comparator calls, transitivity and
 * in_range O(n^3), so only the first max_n values (max_triple_n for O3)
 * are used; truncation is reported in the detail column.
 *
 * Skip support callbacks are called with rel = NULL.  skipsupport.h does
 * not promise that is allowed; no built-in implementation uses rel.
 *
 * Not covered: cross-type laws within an opfamily (BT-INV O10), in_range
 * definition law (val <= base +/- offset; needs the type's arithmetic).
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "access/nbtree.h"
#include "catalog/pg_amproc.h"
#include "catalog/pg_opclass.h"
#include "catalog/pg_type.h"
#include "commands/defrem.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "parser/parse_coerce.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/catcache.h"
#include "utils/datum.h"
#include "utils/fmgroids.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/regproc.h"
#include "utils/skipsupport.h"
#include "utils/sortsupport.h"
#include "utils/syscache.h"
#include "utils/tuplestore.h"
#include "catalog/pg_am_d.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(opclass_laws_check);
PG_FUNCTION_INFO_V1(opclass_laws_check_inrange);

typedef struct Ctx
{
	Oid			opclass;
	Oid			opfamily;
	Oid			typid;			/* opcintype (may be polymorphic) */
	Oid			elemtype;		/* actual sample element type */
	Oid			collation;
	int16		typlen;
	bool		typbyval;
	FmgrInfo	cmp;
	FmgrInfo	typout;
	Datum	   *v;
	int			n;				/* values used */
	int			ntotal;			/* non-null values in the sample */
	Tuplestorestate *ts;
	TupleDesc	tupdesc;
} Ctx;

static void
emit(Ctx *c, const char *law, const char *status, int64 checked,
	 const char *detail)
{
	Datum		values[4];
	bool		nulls[4] = {false, false, false, detail == NULL};

	/* a law checked on nothing has not passed */
	if (checked == 0 && strcmp(status, "pass") == 0)
		status = "empty";
	if (detail == NULL && c->n < c->ntotal)
		detail = psprintf("first %d of %d values", c->n, c->ntotal);
	nulls[3] = (detail == NULL);

	values[0] = CStringGetTextDatum(law);
	values[1] = CStringGetTextDatum(status);
	values[2] = Int64GetDatum(checked);
	values[3] = detail ? CStringGetTextDatum(detail) : (Datum) 0;
	tuplestore_putvalues(c->ts, c->tupdesc, values, nulls);
}

static char *
show(Ctx *c, Datum d)
{
	return OutputFunctionCall(&c->typout, d);
}

static int
sgn(int x)
{
	return (x > 0) - (x < 0);
}

static int
cmp(Ctx *c, Datum a, Datum b)
{
	return DatumGetInt32(FunctionCall2Coll(&c->cmp, c->collation, a, b));
}

/*
 * Resolve opclass, check the sample type, deconstruct the sample
 * (NULL elements dropped: all laws are over non-null values).
 */
static void
setup(Ctx *c, FunctionCallInfo fcinfo, text *opcname, ArrayType *arr,
	  int max_n)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	HeapTuple	tp;
	Form_pg_opclass opcform;
	Oid			cmpproc;
	Oid			outfn;
	bool		isvarlena;
	bool	   *nulls;
	Datum	   *elems;
	int			nelems;
	char		align;

	InitMaterializedSRF(fcinfo, 0);
	c->ts = rsinfo->setResult;
	c->tupdesc = rsinfo->setDesc;

	c->opclass = get_opclass_oid(BTREE_AM_OID,
								 stringToQualifiedNameList(text_to_cstring(opcname), NULL),
								 false);
	tp = SearchSysCache1(CLAOID, ObjectIdGetDatum(c->opclass));
	if (!HeapTupleIsValid(tp))
		elog(ERROR, "cache lookup failed for opclass %u", c->opclass);
	opcform = (Form_pg_opclass) GETSTRUCT(tp);
	c->opfamily = opcform->opcfamily;
	c->typid = opcform->opcintype;
	ReleaseSysCache(tp);

	c->elemtype = ARR_ELEMTYPE(arr);
	if (c->elemtype != c->typid && !IsBinaryCoercible(c->elemtype, c->typid))
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("sample element type %s does not match opclass input type %s",
						format_type_be(c->elemtype), format_type_be(c->typid))));

	/*
	 * No fallback to the default collation: that would check the laws in a
	 * collation the caller did not ask for and report pass.
	 */
	c->collation = PG_GET_COLLATION();
	if (!OidIsValid(c->collation) && type_is_collatable(c->elemtype))
		ereport(ERROR,
				(errcode(ERRCODE_INDETERMINATE_COLLATION),
				 errmsg("could not determine which collation to use for opclass law check"),
				 errhint("Use the COLLATE clause to set the collation explicitly.")));

	if (max_n < 1)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("max_n must be positive")));

	cmpproc = get_opfamily_proc(c->opfamily, c->typid, c->typid, BTORDER_PROC);
	if (!OidIsValid(cmpproc))
		elog(ERROR, "opclass has no BTORDER_PROC");
	fmgr_info(cmpproc, &c->cmp);

	get_typlenbyvalalign(c->elemtype, &c->typlen, &c->typbyval, &align);
	getTypeOutputInfo(c->elemtype, &outfn, &isvarlena);
	fmgr_info(outfn, &c->typout);

	deconstruct_array(arr, c->elemtype, c->typlen, c->typbyval, align,
					  &elems, &nulls, &nelems);
	c->v = palloc_array(Datum, nelems);
	c->ntotal = 0;
	for (int i = 0; i < nelems; i++)
		if (!nulls[i])
			c->v[c->ntotal++] = elems[i];
	c->n = Min(c->ntotal, max_n);
}

/* O1 reflexivity, O2 antisymmetry, O3 transitivity of <= */
static void
check_order(Ctx *c, int max_triple_n)
{
	int64		n1 = 0,
				n2 = 0,
				n3 = 0;
	char	   *bad1 = NULL,
			   *bad2 = NULL,
			   *bad3 = NULL;
	int			tn = Min(c->n, max_triple_n);
	int		   *m;

	for (int i = 0; i < c->n; i++)
	{
		n1++;
		if (bad1 == NULL && cmp(c, c->v[i], c->v[i]) != 0)
			bad1 = psprintf("cmp(a,a)=%d for a=%s",
							cmp(c, c->v[i], c->v[i]), show(c, c->v[i]));
	}
	emit(c, "O1 cmp reflexive", bad1 ? "FAIL" : "pass", n1, bad1);

	for (int i = 0; i < c->n; i++)
	{
		CHECK_FOR_INTERRUPTS();
		for (int j = i + 1; j < c->n; j++)
		{
			int			ab = cmp(c, c->v[i], c->v[j]);
			int			ba = cmp(c, c->v[j], c->v[i]);

			n2++;
			if (bad2 == NULL && sgn(ab) != -sgn(ba))
				bad2 = psprintf("cmp(a,b)=%d cmp(b,a)=%d for a=%s b=%s",
								ab, ba, show(c, c->v[i]), show(c, c->v[j]));
		}
	}
	emit(c, "O2 cmp antisymmetric", bad2 ? "FAIL" : "pass", n2, bad2);

	/* precompute the tn x tn sign matrix, then all ordered triples */
	m = palloc_array(int, tn * tn);
	for (int i = 0; i < tn; i++)
	{
		CHECK_FOR_INTERRUPTS();
		for (int j = 0; j < tn; j++)
			m[i * tn + j] = sgn(cmp(c, c->v[i], c->v[j]));
	}
	for (int i = 0; i < tn && bad3 == NULL; i++)
		for (int j = 0; j < tn && bad3 == NULL; j++)
		{
			CHECK_FOR_INTERRUPTS();
			if (m[i * tn + j] > 0)
				continue;
			for (int k = 0; k < tn; k++)
			{
				n3++;
				if (m[j * tn + k] <= 0 && m[i * tn + k] > 0)
				{
					bad3 = psprintf("a<=b, b<=c, a>c for a=%s b=%s c=%s",
									show(c, c->v[i]), show(c, c->v[j]),
									show(c, c->v[k]));
					break;
				}
			}
		}
	pfree(m);
	emit(c, "O3 cmp transitive", bad3 ? "FAIL" : "pass", n3,
		 bad3 ? bad3 : (tn < c->ntotal ? psprintf("first %d of %d values", tn, c->ntotal) : NULL));
}

/* O4: strategy operators agree with cmp */
static void
check_operators(Ctx *c)
{
	static const char *names[] = {NULL, "<", "<=", "=", ">=", ">"};
	int64		n = 0;
	char	   *bad = NULL;
	int			missing = 0;

	for (int s = BTLessStrategyNumber; s <= BTGreaterStrategyNumber; s++)
	{
		Oid			opr = get_opfamily_member(c->opfamily, c->typid, c->typid, s);
		FmgrInfo	f;

		if (!OidIsValid(opr))
		{
			missing++;
			continue;
		}
		fmgr_info(get_opcode(opr), &f);
		for (int i = 0; i < c->n; i++)
		{
			CHECK_FOR_INTERRUPTS();
			for (int j = 0; j < c->n; j++)
			{
				int			r = sgn(cmp(c, c->v[i], c->v[j]));
				bool		want;
				bool		got;

				switch (s)
				{
					case BTLessStrategyNumber:
						want = r < 0;
						break;
					case BTLessEqualStrategyNumber:
						want = r <= 0;
						break;
					case BTEqualStrategyNumber:
						want = r == 0;
						break;
					case BTGreaterEqualStrategyNumber:
						want = r >= 0;
						break;
					default:
						want = r > 0;
						break;
				}
				got = DatumGetBool(FunctionCall2Coll(&f, c->collation,
													 c->v[i], c->v[j]));
				n++;
				if (bad == NULL && got != want)
					bad = psprintf("strategy %d (%s) returns %s, cmp=%d, for a=%s b=%s",
								   s, names[s], got ? "true" : "false", r,
								   show(c, c->v[i]), show(c, c->v[j]));
			}
		}
	}
	emit(c, "O4 operators agree with cmp", bad ? "FAIL" : "pass", n,
		 bad ? bad : (missing ? psprintf("%d strategies missing", missing) : NULL));
}

static void
init_ssup(Ctx *c, SortSupport ssup, bool abbreviate)
{
	memset(ssup, 0, sizeof(SortSupportData));
	ssup->ssup_cxt = CurrentMemoryContext;
	ssup->ssup_collation = c->collation;
	ssup->ssup_reverse = false;
	ssup->ssup_nulls_first = false;
	ssup->abbreviate = abbreviate;
}

/* O5 sortsupport comparator, O6 abbreviated keys */
static void
check_sortsupport(Ctx *c)
{
	Oid			proc = get_opfamily_proc(c->opfamily, c->typid, c->typid,
										 BTSORTSUPPORT_PROC);
	SortSupportData ss;
	SortSupportData sa;
	int64		n5 = 0,
				n6 = 0;
	char	   *bad5 = NULL,
			   *bad6 = NULL;
	Datum	   *ab;

	if (!OidIsValid(proc))
	{
		emit(c, "O5 sortsupport agrees with cmp", "n/a", 0, "no sortsupport proc");
		emit(c, "O6 abbreviated key agrees with cmp", "n/a", 0, "no sortsupport proc");
		return;
	}

	init_ssup(c, &ss, false);
	OidFunctionCall1(proc, PointerGetDatum(&ss));
	for (int i = 0; i < c->n; i++)
	{
		CHECK_FOR_INTERRUPTS();
		for (int j = 0; j < c->n; j++)
		{
			int			r = sgn(cmp(c, c->v[i], c->v[j]));
			int			s = sgn(ss.comparator(c->v[i], c->v[j], &ss));

			n5++;
			if (bad5 == NULL && r != s)
				bad5 = psprintf("sortsupport=%d cmp=%d for a=%s b=%s",
								s, r, show(c, c->v[i]), show(c, c->v[j]));
		}
	}
	emit(c, "O5 sortsupport agrees with cmp", bad5 ? "FAIL" : "pass", n5, bad5);

	init_ssup(c, &sa, true);
	OidFunctionCall1(proc, PointerGetDatum(&sa));
	if (sa.abbrev_converter == NULL)
	{
		emit(c, "O6 abbreviated key agrees with cmp", "n/a", 0,
			 "opclass declined abbreviation");
		return;
	}
	ab = palloc_array(Datum, c->n);
	for (int i = 0; i < c->n; i++)
		ab[i] = sa.abbrev_converter(c->v[i], &sa);
	for (int i = 0; i < c->n; i++)
	{
		CHECK_FOR_INTERRUPTS();
		for (int j = 0; j < c->n; j++)
		{
			int			r = sgn(cmp(c, c->v[i], c->v[j]));
			int			a = sgn(sa.comparator(ab[i], ab[j], &sa));
			int			f = sgn(sa.abbrev_full_comparator(c->v[i], c->v[j], &sa));

			n6++;
			if (bad6 == NULL && a != 0 && a != r)
				bad6 = psprintf("abbreviated=%d cmp=%d for a=%s b=%s",
								a, r, show(c, c->v[i]), show(c, c->v[j]));
			if (bad6 == NULL && f != r)
				bad6 = psprintf("abbrev_full_comparator=%d cmp=%d for a=%s b=%s",
								f, r, show(c, c->v[i]), show(c, c->v[j]));
		}
	}
	emit(c, "O6 abbreviated key agrees with cmp", bad6 ? "FAIL" : "pass", n6, bad6);
}

/*
 * O7: if equalimage returns true, cmp(a,b)=0 <=> datum_image_eq(a,b).
 * If it is absent or returns false, report what the sample shows: the
 * number of cmp-equal pairs whose images differ (why dedup is unsafe).
 */
static void
check_equalimage(Ctx *c)
{
	Oid			proc = get_opfamily_proc(c->opfamily, c->typid, c->typid,
										 BTEQUALIMAGE_PROC);
	bool		claimed = false;
	int64		n = 0,
				differ = 0;
	char	   *bad = NULL,
			   *example = NULL;

	if (OidIsValid(proc))
		claimed = DatumGetBool(OidFunctionCall1Coll(proc, c->collation,
													ObjectIdGetDatum(c->typid)));
	for (int i = 0; i < c->n; i++)
	{
		CHECK_FOR_INTERRUPTS();
		for (int j = i + 1; j < c->n; j++)
		{
			bool		ceq = cmp(c, c->v[i], c->v[j]) == 0;
			bool		ieq = datum_image_eq(c->v[i], c->v[j], c->typbyval, c->typlen);

			n++;
			if (ceq && !ieq)
			{
				differ++;
				if (example == NULL)
					example = psprintf("a=%s b=%s", show(c, c->v[i]), show(c, c->v[j]));
			}
			if (claimed && bad == NULL && ceq != ieq)
				bad = psprintf("equalimage=true but cmp %s and image %s for a=%s b=%s",
							   ceq ? "equal" : "differs", ieq ? "equal" : "differs",
							   show(c, c->v[i]), show(c, c->v[j]));
		}
	}
	if (claimed)
		emit(c, "O7 equalimage: cmp-equal <=> image-equal", bad ? "FAIL" : "pass", n, bad);
	else
		emit(c, "O7 equalimage: cmp-equal <=> image-equal", "n/a", n,
			 psprintf("%s; sample has " INT64_FORMAT " cmp-equal image-different pairs%s%s",
					  OidIsValid(proc) ? "equalimage returns false" : "no equalimage proc",
					  differ, example ? ", e.g. " : "", example ? example : ""));
}

/* O9: skip support */
static void
check_skipsupport(Ctx *c)
{
	SkipSupport sk = PrepareSkipSupportFromOpclass(c->opfamily, c->typid, false);
	int64		n = 0;
	char	   *bad = NULL;
	Datum	   *w;
	int			wn;

	if (sk == NULL)
	{
		emit(c, "O9 skip support", "n/a", 0, "no skip support proc");
		return;
	}

	/* the working set is the sample plus both domain bounds */
	w = palloc_array(Datum, c->n + 2);
	memcpy(w, c->v, sizeof(Datum) * c->n);
	w[c->n] = sk->low_elem;
	w[c->n + 1] = sk->high_elem;
	wn = c->n + 2;

	for (int i = 0; i < wn && bad == NULL; i++)
	{
		Datum		a = w[i];
		bool		ovf = false;

		CHECK_FOR_INTERRUPTS();
		n++;
		if (cmp(c, sk->low_elem, a) > 0)
			bad = psprintf("low_elem %s > sample value %s",
						   show(c, sk->low_elem), show(c, a));
		else if (cmp(c, sk->high_elem, a) < 0)
			bad = psprintf("high_elem %s < sample value %s",
						   show(c, sk->high_elem), show(c, a));
		if (bad)
			break;

		/* increment */
		if (cmp(c, a, sk->high_elem) == 0)
		{
			(void) sk->increment(NULL, a, &ovf);
			if (!ovf)
				bad = psprintf("increment(high_elem %s) did not set overflow", show(c, a));
		}
		else
		{
			Datum		up = sk->increment(NULL, a, &ovf);
			Datum		back;
			bool		ovf2 = false;

			if (ovf)
				bad = psprintf("increment(%s) set overflow below high_elem", show(c, a));
			else if (cmp(c, up, a) <= 0)
				bad = psprintf("increment(%s)=%s is not greater", show(c, a), show(c, up));
			else
			{
				for (int k = 0; k < wn; k++)
					if (cmp(c, a, w[k]) < 0 && cmp(c, w[k], up) < 0)
					{
						bad = psprintf("increment(%s)=%s skips over %s",
									   show(c, a), show(c, up), show(c, w[k]));
						break;
					}
				if (bad == NULL)
				{
					back = sk->decrement(NULL, up, &ovf2);
					if (ovf2 || cmp(c, back, a) != 0)
						bad = psprintf("decrement(increment(%s)) = %s", show(c, a),
									   ovf2 ? "overflow" : show(c, back));
				}
			}
		}
		if (bad)
			break;

		/* decrement */
		ovf = false;
		if (cmp(c, a, sk->low_elem) == 0)
		{
			(void) sk->decrement(NULL, a, &ovf);
			if (!ovf)
				bad = psprintf("decrement(low_elem %s) did not set overflow", show(c, a));
		}
		else
		{
			Datum		dn = sk->decrement(NULL, a, &ovf);

			if (ovf)
				bad = psprintf("decrement(%s) set overflow above low_elem", show(c, a));
			else if (cmp(c, dn, a) >= 0)
				bad = psprintf("decrement(%s)=%s is not less", show(c, a), show(c, dn));
			else
				for (int k = 0; k < wn; k++)
					if (cmp(c, dn, w[k]) < 0 && cmp(c, w[k], a) < 0)
					{
						bad = psprintf("decrement(%s)=%s skips over %s",
									   show(c, a), show(c, dn), show(c, w[k]));
						break;
					}
		}
	}
	emit(c, "O9 skip support", bad ? "FAIL" : "pass", n, bad);
}

/*
 * opclass_laws_check(opclass text, sample anyarray, max_n int,
 *					  max_triple_n int)
 *		RETURNS TABLE(law text, status text, checked bigint, detail text)
 */
Datum
opclass_laws_check(PG_FUNCTION_ARGS)
{
	Ctx			c;

	setup(&c, fcinfo, PG_GETARG_TEXT_PP(0), PG_GETARG_ARRAYTYPE_P(1),
		  PG_GETARG_INT32(2));
	check_order(&c, PG_GETARG_INT32(3));
	check_operators(&c);
	check_sortsupport(&c);
	check_equalimage(&c);
	check_skipsupport(&c);
	return (Datum) 0;
}

/*
 * O8: in_range monotonicity (btree.sgml, in_range support function).
 * For every in_range proc of the family with lefttype = opcintype, every
 * offset (text, converted by the offset type's input function) and every
 * (sub, less):
 *	 less=true:  true for val1 => true for every val2 <= val1 (same base)
 *				 true for base1 => true for every base2 >= base1 (same val)
 *	 less=false: inverted.
 * The two "false" laws of the documentation are contrapositives of these.
 */
Datum
opclass_laws_check_inrange(PG_FUNCTION_ARGS)
{
	Ctx			c;
	ArrayType  *offs = PG_GETARG_ARRAYTYPE_P(2);
	Datum	   *offtext;
	bool	   *offnull;
	int			noff;
	CatCList   *procs;
	int			nprocs = 0;

	setup(&c, fcinfo, PG_GETARG_TEXT_PP(0), PG_GETARG_ARRAYTYPE_P(1),
		  PG_GETARG_INT32(3));
	deconstruct_array_builtin(offs, TEXTOID, &offtext, &offnull, &noff);

	procs = SearchSysCacheList1(AMPROCNUM, ObjectIdGetDatum(c.opfamily));
	for (int p = 0; p < procs->n_members; p++)
	{
		Form_pg_amproc pf = (Form_pg_amproc) GETSTRUCT(&procs->members[p]->tuple);
		FmgrInfo	f;
		Oid			infn,
					ioparam;
		int64		n = 0;
		char	   *bad = NULL;
		char	   *law;
		bool	   *r;

		if (pf->amprocnum != BTINRANGE_PROC || pf->amproclefttype != c.typid)
			continue;
		nprocs++;
		fmgr_info(pf->amproc, &f);
		getTypeInputInfo(pf->amprocrighttype, &infn, &ioparam);
		r = palloc_array(bool, c.n * c.n);	/* r[val * n + base] */

		for (int o = 0; o < noff && bad == NULL; o++)
		{
			char	   *os;
			Datum		off;

			if (offnull[o])
				continue;
			os = TextDatumGetCString(offtext[o]);
			off = OidInputFunctionCall(infn, os, ioparam, -1);

			for (int sub = 0; sub <= 1 && bad == NULL; sub++)
				for (int less = 0; less <= 1 && bad == NULL; less++)
				{
					for (int vi = 0; vi < c.n; vi++)
					{
						CHECK_FOR_INTERRUPTS();
						for (int bi = 0; bi < c.n; bi++)
						{
							LOCAL_FCINFO(call, 5);

							InitFunctionCallInfoData(*call, &f, 5, c.collation, NULL, NULL);
							call->args[0].value = c.v[vi];
							call->args[0].isnull = false;
							call->args[1].value = c.v[bi];
							call->args[1].isnull = false;
							call->args[2].value = off;
							call->args[2].isnull = false;
							call->args[3].value = BoolGetDatum(sub);
							call->args[3].isnull = false;
							call->args[4].value = BoolGetDatum(less);
							call->args[4].isnull = false;
							r[vi * c.n + bi] = DatumGetBool(FunctionCallInvoke(call));
							if (call->isnull)
								elog(ERROR, "in_range returned NULL");
						}
					}

					for (int x = 0; x < c.n && bad == NULL; x++)
						for (int y = 0; y < c.n && bad == NULL; y++)
						{
							int			xy = sgn(cmp(&c, c.v[x], c.v[y]));
							/* for less=true, truth must propagate to smaller vals / larger bases */
							bool		valdir = less ? xy <= 0 : xy >= 0;
							bool		basedir = less ? xy >= 0 : xy <= 0;

							CHECK_FOR_INTERRUPTS();

							for (int z = 0; z < c.n; z++)
							{
								n++;
								/* val law: base z fixed, val y true => val x true */
								if (valdir && r[y * c.n + z] && !r[x * c.n + z])
								{
									bad = psprintf("offset=%s sub=%d less=%d: true for val=%s but false for val=%s, base=%s",
												   os, sub, less, show(&c, c.v[y]),
												   show(&c, c.v[x]), show(&c, c.v[z]));
									break;
								}
								/* base law: val z fixed, base y true => base x true */
								if (basedir && r[z * c.n + y] && !r[z * c.n + x])
								{
									bad = psprintf("offset=%s sub=%d less=%d: true for base=%s but false for base=%s, val=%s",
												   os, sub, less, show(&c, c.v[y]),
												   show(&c, c.v[x]), show(&c, c.v[z]));
									break;
								}
							}
						}
				}
		}
		law = psprintf("O8 in_range monotone (%s offset)",
					   format_type_be(pf->amprocrighttype));
		emit(&c, law, bad ? "FAIL" : "pass", n, bad);
	}
	ReleaseSysCacheList(procs);
	if (nprocs == 0)
		emit(&c, "O8 in_range monotone", "n/a", 0, "no in_range proc for opclass input type");
	return (Datum) 0;
}
