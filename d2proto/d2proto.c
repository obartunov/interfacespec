/*-------------------------------------------------------------------------
 *
 * d2proto.c
 *	  D2: a generic observer of the Index AM scan callbacks, and a driver
 *	  that calls them in a given order.
 *
 *	  The observer is a copy of the index's IndexAmRoutine whose scan
 *	  callbacks record what was called and what came back, then call the
 *	  real callback unchanged.  It is installed in the relcache entry of one
 *	  index for the duration of one SQL call (d2_run or d2_observe) and
 *	  knows only the Index AM ABI and IndexScanDesc, not any AM.
 *
 *	  Two things are configured from the protocol spec (d2_configure):
 *	  - which callbacks end the lifetime of returned index data
 *	    (xs_itup / xs_hitup): at the entry of such a callback the data
 *	    saved at return of the previous amgettuple is compared byte for
 *	    byte with what the returned pointer shows now;
 *	  - guards: caller obligations on callback arguments, checked before
 *	    the call is forwarded; a violating call is not forwarded.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/amapi.h"
#include "access/genam.h"
#include "access/relscan.h"
#include "access/table.h"
#include "access/tableam_indexscan.h"
#include "access/xact.h"
#include "catalog/pg_type.h"
#include "executor/instrument.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/resowner.h"
#include "utils/snapmgr.h"

#include "d2proto.h"

PG_MODULE_MAGIC;

/* callbacks the observer knows */
static const char *const cb_names[] = {
	"ambeginscan", "amrescan", "amgettuple", "amendscan", "ammarkpos", "amrestrpos"
};

static int
cb_lookup(const char *name)
{
	for (int i = 0; i < CB_COUNT; i++)
		if (strcmp(name, cb_names[i]) == 0)
			return i;
	return -1;
}

/* ---- configuration from the protocol spec ---- */
typedef struct Guard
{
	int			cb;				/* callback checked (its argument) */
	int			arg;			/* 0 = nkeys, 1 = norderbys */
	int			rel;			/* 0: <=, 1: = */
	int			refcb;			/* callback whose recorded argument bounds it */
	char		text[128];
} Guard;

static uint32 lifetime_ends;	/* bitmask of callbacks */
static Guard guards[8];
static int	nguards;

/* ---- per-call observer state ---- */
typedef struct ScanObs
{
	IndexScanDesc scan;
	char		label[16];
	int			args[CB_COUNT][2];	/* last nkeys/norderbys seen per callback */
	bool		live;			/* returned data outstanding */
	const char *ptr;
	Size		len;
	char	   *copy;
} ScanObs;

#define MAX_SCANS 16
static ScanObs scans[MAX_SCANS];
static int	nscans;
static int	scan_seq;
static const char *next_label;
static const IndexAmRoutine *fwd;	/* what the observer forwards to */
static IndexAmRoutine obs;
static MemoryContext d2cxt;
static StringInfo events;
static bool refuse_quietly;		/* driver: record and stop; observe: ERROR */
bool		d2_refused;

static ScanObs *
scan_find(IndexScanDesc scan)
{
	for (int i = 0; i < nscans; i++)
		if (scans[i].scan == scan)
			return &scans[i];
	elog(ERROR, "d2proto: callback on a scan the observer did not see begin");
	return NULL;
}

static void
ev_open(ScanObs *s, int cb)
{
	if (events->len > 1)
		appendStringInfoChar(events, ',');
	appendStringInfo(events, "{\"scan\":\"%s\",\"cb\":\"%s\"", s->label, cb_names[cb]);
}

/* lifetime of the previously returned data ends at this callback? */
static void
lifetime_check(ScanObs *s, int cb)
{
	if (!(lifetime_ends & (1 << cb)) || !s->live)
		return;
	appendStringInfo(events, ",\"life\":\"%s\"",
					 memcmp(s->ptr, s->copy, s->len) == 0 ? "ok" : "changed");
	s->live = false;
	pfree(s->copy);
	s->copy = NULL;
}

static bool
guards_pass(ScanObs *s, int cb, int nkeys, int norderbys)
{
	int			val[2] = {nkeys, norderbys};

	for (int i = 0; i < nguards; i++)
	{
		Guard	   *g = &guards[i];
		int			bound = s->args[g->refcb][g->arg];
		bool		ok;

		if (g->cb != cb)
			continue;
		ok = g->rel == 0 ? val[g->arg] <= bound : val[g->arg] == bound;
		if (!ok)
		{
			appendStringInfo(events, ",\"refused\":\"%s (%d vs %d)\"}", g->text, val[g->arg], bound);
			if (!refuse_quietly)
				ereport(ERROR,
						(errmsg("d2proto: caller obligation violated: %s (%d vs %d)",
								g->text, val[g->arg], bound),
						 errdetail("The callback was not called.")));
			d2_refused = true;
			return false;
		}
	}
	return true;
}

static IndexScanDesc
obs_beginscan(Relation rel, int nkeys, int norderbys)
{
	IndexScanDesc scan;
	ScanObs    *s;
	MemoryContext old;

	if (nscans >= MAX_SCANS)
		elog(ERROR, "d2proto: too many scans");
	scan = fwd->ambeginscan(rel, nkeys, norderbys);
	s = &scans[nscans++];
	memset(s, 0, sizeof(*s));
	s->scan = scan;
	old = MemoryContextSwitchTo(d2cxt);
	if (next_label)
		strlcpy(s->label, next_label, sizeof(s->label));
	else
		snprintf(s->label, sizeof(s->label), "s%d", ++scan_seq);
	next_label = NULL;
	s->args[CB_BEGIN][0] = nkeys;
	s->args[CB_BEGIN][1] = norderbys;
	ev_open(s, CB_BEGIN);
	appendStringInfo(events, ",\"nkeys\":%d,\"norderbys\":%d}", nkeys, norderbys);
	MemoryContextSwitchTo(old);
	return scan;
}

static void
obs_rescan(IndexScanDesc scan, ScanKey keys, int nkeys, ScanKey orderbys, int norderbys)
{
	ScanObs    *s = scan_find(scan);
	MemoryContext old = MemoryContextSwitchTo(d2cxt);

	ev_open(s, CB_RESCAN);
	appendStringInfo(events, ",\"nkeys\":%d,\"norderbys\":%d,\"keys\":%s",
					 nkeys, norderbys, keys ? "\"given\"" : "null");
	lifetime_check(s, CB_RESCAN);
	if (!guards_pass(s, CB_RESCAN, nkeys, norderbys))
	{
		MemoryContextSwitchTo(old);
		return;
	}
	appendStringInfoChar(events, '}');
	MemoryContextSwitchTo(old);
	s->args[CB_RESCAN][0] = nkeys;
	s->args[CB_RESCAN][1] = norderbys;
	fwd->amrescan(scan, keys, nkeys, orderbys, norderbys);
}

static bool
obs_gettuple(IndexScanDesc scan, ScanDirection dir)
{
	ScanObs    *s = scan_find(scan);
	MemoryContext old;
	bool		ret;

	old = MemoryContextSwitchTo(d2cxt);
	ev_open(s, CB_GET);
	appendStringInfo(events, ",\"dir\":\"%s\"",
					 ScanDirectionIsBackward(dir) ? "backward" : "forward");
	lifetime_check(s, CB_GET);
	MemoryContextSwitchTo(old);

	ret = fwd->amgettuple(scan, dir);

	old = MemoryContextSwitchTo(d2cxt);
	appendStringInfo(events, ",\"ret\":%s", ret ? "true" : "false");
	if (ret)
	{
		const char *what = NULL;

		appendStringInfo(events, ",\"tid\":\"(%u,%u)\"",
						 ItemPointerGetBlockNumberNoCheck(&scan->xs_heaptid),
						 ItemPointerGetOffsetNumberNoCheck(&scan->xs_heaptid));
		if (scan->xs_want_itup && scan->xs_hitup)
		{
			what = "hitup";
			s->ptr = (const char *) scan->xs_hitup->t_data;
			s->len = scan->xs_hitup->t_len;
		}
		else if (scan->xs_want_itup && scan->xs_itup)
		{
			what = "itup";
			s->ptr = (const char *) scan->xs_itup;
			s->len = IndexTupleSize(scan->xs_itup);
		}
		if (what)
		{
			s->copy = palloc(s->len);
			memcpy(s->copy, s->ptr, s->len);
			s->live = true;
			appendStringInfo(events, ",\"data\":\"%s\"", what);
		}
		else if (scan->xs_want_itup)
			appendStringInfoString(events, ",\"data\":null");
	}
	appendStringInfoChar(events, '}');
	MemoryContextSwitchTo(old);
	return ret;
}

static void
obs_simple(IndexScanDesc scan, int cb)
{
	ScanObs    *s = scan_find(scan);
	MemoryContext old = MemoryContextSwitchTo(d2cxt);

	ev_open(s, cb);
	lifetime_check(s, cb);
	appendStringInfoChar(events, '}');
	MemoryContextSwitchTo(old);
}

static void
obs_endscan(IndexScanDesc scan)
{
	ScanObs    *s = scan_find(scan);

	obs_simple(scan, CB_END);
	fwd->amendscan(scan);
	/* forget the scan */
	*s = scans[--nscans];
}

static void
obs_markpos(IndexScanDesc scan)
{
	obs_simple(scan, CB_MARK);
	fwd->ammarkpos(scan);
}

static void
obs_restrpos(IndexScanDesc scan)
{
	obs_simple(scan, CB_RESTR);
	fwd->amrestrpos(scan);
}

/* fresh observer state, in a context under parent */
static void
obs_fresh(MemoryContext parent, bool quiet)
{
	MemoryContext old;

	d2cxt = AllocSetContextCreate(parent, "d2proto", ALLOCSET_DEFAULT_SIZES);
	old = MemoryContextSwitchTo(d2cxt);
	events = makeStringInfo();
	MemoryContextSwitchTo(old);
	appendStringInfoChar(events, '[');
	nscans = 0;
	scan_seq = 0;
	next_label = NULL;
	refuse_quietly = quiet;
	d2_refused = false;
	d2ctl_reset();
}

/*
 * Put the observer (and any control layers) in front of rel's routine;
 * returns the original routine, to be put back by detach.
 */
static const IndexAmRoutine *
attach(Relation rel)
{
	const IndexAmRoutine *orig = rel->rd_indam;

	fwd = d2ctl_am_layer(orig);
	obs = *orig;
	obs.ambeginscan = obs_beginscan;
	obs.amrescan = obs_rescan;
	obs.amendscan = obs_endscan;
	if (orig->amgettuple)
		obs.amgettuple = obs_gettuple;
	if (orig->ammarkpos)
		obs.ammarkpos = obs_markpos;
	if (orig->amrestrpos)
		obs.amrestrpos = obs_restrpos;
	rel->rd_indam = d2ctl_caller_layer(&obs);
	return orig;
}

static void
detach(Relation rel, const IndexAmRoutine *orig)
{
	rel->rd_indam = orig;
}

static const IndexAmRoutine *
install(Relation rel, bool quiet)
{
	obs_fresh(CurrentMemoryContext, quiet);
	return attach(rel);
}

static void
uninstall(Relation rel, const IndexAmRoutine *orig)
{
	detach(rel, orig);
	d2ctl_reset();
}

static text *
events_text(void)
{
	appendStringInfoChar(events, ']');
	return cstring_to_text_with_len(events->data, events->len);
}

/* ---- d2_configure(lifetime_ends text[], guards text[]) ---- */
PG_FUNCTION_INFO_V1(d2_configure);
Datum
d2_configure(PG_FUNCTION_ARGS)
{
	Datum	   *d;
	bool	   *nulls;
	int			n;

	lifetime_ends = 0;
	deconstruct_array_builtin(PG_GETARG_ARRAYTYPE_P(0), TEXTOID, &d, &nulls, &n);
	for (int i = 0; i < n; i++)
	{
		char	   *name = TextDatumGetCString(d[i]);
		int			cb = cb_lookup(name);

		if (cb < 0)
			elog(ERROR, "d2proto: unknown callback \"%s\"", name);
		lifetime_ends |= 1 << cb;
	}

	nguards = 0;
	deconstruct_array_builtin(PG_GETARG_ARRAYTYPE_P(1), TEXTOID, &d, &nulls, &n);
	for (int i = 0; i < n; i++)
	{
		/* form: <callback>.<arg> <= | = <callback>.<arg> */
		char	   *g = TextDatumGetCString(d[i]);
		char		cb[64], arg[64], rel[4], refcb[64], refarg[64];
		Guard	   *gd;

		if (nguards >= lengthof(guards))
			elog(ERROR, "d2proto: too many guards");
		if (sscanf(g, "%63[a-z].%63[a-z] %3s %63[a-z].%63[a-z]", cb, arg, rel, refcb, refarg) != 5 ||
			strcmp(arg, refarg) != 0 ||
			(strcmp(arg, "nkeys") != 0 && strcmp(arg, "norderbys") != 0) ||
			(strcmp(rel, "<=") != 0 && strcmp(rel, "=") != 0) ||
			cb_lookup(cb) < 0 || cb_lookup(refcb) < 0)
			elog(ERROR, "d2proto: guard \"%s\" is not one the observer can check", g);
		gd = &guards[nguards++];
		gd->cb = cb_lookup(cb);
		gd->arg = strcmp(arg, "nkeys") == 0 ? 0 : 1;
		gd->rel = strcmp(rel, "<=") == 0 ? 0 : 1;
		gd->refcb = cb_lookup(refcb);
		strlcpy(gd->text, g, sizeof(gd->text));
	}
	PG_RETURN_VOID();
}

/* ---- d2_caps(index regclass) -> json ---- */
PG_FUNCTION_INFO_V1(d2_caps);
Datum
d2_caps(PG_FUNCTION_ARGS)
{
	Relation	rel = index_open(PG_GETARG_OID(0), AccessShareLock);
	const IndexAmRoutine *r = rel->rd_indam;
	StringInfoData s;

	initStringInfo(&s);
	appendStringInfo(&s, "{\"amcanorder\":%s,\"amcanbackward\":%s,\"amoptionalkey\":%s,"
					 "\"amgettuple\":%s,\"ammarkpos\":%s,\"amrestrpos\":%s,\"amcanreturn\":%s}",
					 r->amcanorder ? "true" : "false",
					 r->amcanbackward ? "true" : "false",
					 r->amoptionalkey ? "true" : "false",
					 r->amgettuple ? "true" : "false",
					 r->ammarkpos ? "true" : "false",
					 r->amrestrpos ? "true" : "false",
					 index_can_return(rel, 1) ? "true" : "false");
	index_close(rel, AccessShareLock);
	PG_RETURN_TEXT_P(cstring_to_text(s.data));
}

/*
 * ---- d2_run(index, opr, val, index_only, history text[]) -> json events ----
 * history steps: "<scan>.<callback>[:<arg>]"
 *   ambeginscan            nkeys = 1 if opr given, else 0; norderbys = 0
 *   amrescan[:nullkeys]    the key, or NULL keys (restart with previous keys)
 *   amgettuple:forward|backward
 *   ammarkpos, amrestrpos, amendscan
 * Calls go through indexam.c; the observer sees what the AM receives.
 * Scans still open at the end are ended.
 */
typedef struct DrvScan
{
	char		label[16];
	IndexScanDesc scan;
} DrvScan;

typedef struct Driver
{
	Relation	irel,
				hrel;
	bool		haskey;
	bool		index_only;
	ScanKeyData key;
	Snapshot	snap;
	DrvScan		drv[MAX_SCANS];
	int			ndrv;
} Driver;

static void
drv_open(Driver *dr, Oid indexoid, Oid opr, text *val, bool index_only)
{
	memset(dr, 0, sizeof(*dr));
	dr->irel = index_open(indexoid, AccessShareLock);
	dr->hrel = table_open(dr->irel->rd_index->indrelid, AccessShareLock);
	dr->index_only = index_only;
	dr->haskey = OidIsValid(opr);
	if (dr->haskey)
	{
		Oid			opfamily = dr->irel->rd_opfamily[0];
		int			strategy;
		Oid			lefttype,
					righttype,
					typinput,
					typioparam;

		get_op_opfamily_properties(opr, opfamily, false, &strategy, &lefttype, &righttype);
		getTypeInputInfo(righttype, &typinput, &typioparam);
		ScanKeyEntryInitialize(&dr->key, 0, 1, strategy, righttype, dr->irel->rd_indcollation[0],
							   get_opcode(opr),
							   OidInputFunctionCall(typinput, text_to_cstring(val),
													typioparam, -1));
	}
}

/* one step "<scan>.<callback>[:<arg>]" */
static void
drv_step(Driver *dr, const char *stepin)
{
	char	   *step = pstrdup(stepin);
	char	   *dot = strchr(step, '.');
	char	   *colon;
	char	   *argv = NULL;
	DrvScan    *d = NULL;

	if (!dot)
		elog(ERROR, "d2proto: bad step \"%s\"", step);
	*dot = '\0';
	colon = strchr(dot + 1, ':');
	if (colon)
	{
		*colon = '\0';
		argv = colon + 1;
	}
	for (int j = 0; j < dr->ndrv; j++)
		if (strcmp(dr->drv[j].label, step) == 0)
			d = &dr->drv[j];

	if (strcmp(dot + 1, "ambeginscan") == 0)
	{
		if (d)
			elog(ERROR, "d2proto: scan %s already begun", step);
		d = &dr->drv[dr->ndrv++];
		strlcpy(d->label, step, sizeof(d->label));
		next_label = d->label;
		d->scan = index_beginscan(dr->hrel, dr->irel, dr->index_only, dr->snap, NULL,
								  dr->haskey ? 1 : 0, 0, SO_NONE);
		return;
	}
	if (!d)
		elog(ERROR, "d2proto: scan %s not begun", step);
	if (strcmp(dot + 1, "amrescan") == 0)
		index_rescan(d->scan, argv && strcmp(argv, "nullkeys") == 0 ? NULL : (dr->haskey ? &dr->key : NULL),
					 dr->haskey ? 1 : 0, NULL, 0);
	else if (strcmp(dot + 1, "amgettuple") == 0)
		(void) tableam_index_getnext_tid(d->scan,
										 argv && strcmp(argv, "backward") == 0 ?
										 BackwardScanDirection : ForwardScanDirection);
	else if (strcmp(dot + 1, "ammarkpos") == 0)
		index_markpos(d->scan);
	else if (strcmp(dot + 1, "amrestrpos") == 0)
		index_restrpos(d->scan);
	else if (strcmp(dot + 1, "amendscan") == 0)
	{
		index_endscan(d->scan);
		*d = dr->drv[--dr->ndrv];
	}
	else
		elog(ERROR, "d2proto: unknown callback \"%s\"", dot + 1);
}

static void
drv_end_all(Driver *dr)
{
	while (dr->ndrv > 0)
		index_endscan(dr->drv[--dr->ndrv].scan);
}

static void
drv_close(Driver *dr)
{
	table_close(dr->hrel, AccessShareLock);
	index_close(dr->irel, AccessShareLock);
}

PG_FUNCTION_INFO_V1(d2_run);
Datum
d2_run(PG_FUNCTION_ARGS)
{
	Driver		dr;
	const IndexAmRoutine *orig;
	Datum	   *steps;
	bool	   *nulls;
	int			nsteps;
	text	   *result;

	deconstruct_array_builtin(PG_GETARG_ARRAYTYPE_P(4), TEXTOID, &steps, &nulls, &nsteps);
	drv_open(&dr, PG_GETARG_OID(0), PG_ARGISNULL(1) ? InvalidOid : PG_GETARG_OID(1),
			 PG_ARGISNULL(2) ? NULL : PG_GETARG_TEXT_PP(2), PG_GETARG_BOOL(3));
	dr.snap = RegisterSnapshot(GetTransactionSnapshot());
	orig = install(dr.irel, true);
	PG_TRY();
	{
		for (int i = 0; i < nsteps && !d2_refused; i++)
			drv_step(&dr, TextDatumGetCString(steps[i]));
		drv_end_all(&dr);
	}
	PG_FINALLY();
	{
		uninstall(dr.irel, orig);
	}
	PG_END_TRY();
	result = events_text();
	UnregisterSnapshot(dr.snap);
	drv_close(&dr);
	PG_RETURN_TEXT_P(result);
}

/*
 * ---- session driver: d2_open / d2_step / d2_close ----
 * Keeps scans open across SQL statements of one transaction, so that other
 * sessions can act between two callbacks of an open scan.  Scans, pins,
 * relation references and the snapshot belong to the top transaction's
 * resource owner; observer state lives in TopTransactionContext.  The
 * observer is attached only while a step runs.  d2_step returns the step's
 * events followed by {"buffers": n}, the shared buffers the step touched
 * (coverage only: whether the AM read a page).
 */
static Driver *sess;
static bool sess_xact_cb_registered;

static void
sess_xact_cb(XactEvent event, void *arg)
{
	if (event == XACT_EVENT_COMMIT || event == XACT_EVENT_ABORT ||
		event == XACT_EVENT_PARALLEL_COMMIT || event == XACT_EVENT_PARALLEL_ABORT ||
		event == XACT_EVENT_PREPARE)
		sess = NULL;
}

static text *
events_since(int from)
{
	StringInfoData s;

	initStringInfo(&s);
	appendStringInfoChar(&s, '[');
	if (events->len > from)
		appendBinaryStringInfo(&s, events->data + from + (events->data[from] == ',' ? 1 : 0),
							   events->len - from - (events->data[from] == ',' ? 1 : 0));
	appendStringInfoChar(&s, ']');
	return cstring_to_text_with_len(s.data, s.len);
}

PG_FUNCTION_INFO_V1(d2_open);
Datum
d2_open(PG_FUNCTION_ARGS)
{
	MemoryContext old;
	ResourceOwner saveowner;

	if (!IsTransactionBlock())
		elog(ERROR, "d2_open: must run inside a transaction block");
	if (sess)
		elog(ERROR, "d2_open: a session scan set is already open");
	if (!sess_xact_cb_registered)
	{
		RegisterXactCallback(sess_xact_cb, NULL);
		sess_xact_cb_registered = true;
	}
	old = MemoryContextSwitchTo(TopTransactionContext);
	obs_fresh(TopTransactionContext, true);
	sess = palloc(sizeof(Driver));
	saveowner = CurrentResourceOwner;
	CurrentResourceOwner = TopTransactionResourceOwner;
	PG_TRY();
	{
		drv_open(sess, PG_GETARG_OID(0), PG_ARGISNULL(1) ? InvalidOid : PG_GETARG_OID(1),
				 PG_ARGISNULL(2) ? NULL : PG_GETARG_TEXT_PP(2), PG_GETARG_BOOL(3));
		sess->snap = RegisterSnapshotOnOwner(GetTransactionSnapshot(), TopTransactionResourceOwner);
	}
	PG_FINALLY();
	{
		CurrentResourceOwner = saveowner;
		MemoryContextSwitchTo(old);
	}
	PG_END_TRY();
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(d2_step);
Datum
d2_step(PG_FUNCTION_ARGS)
{
	char	   *step = text_to_cstring(PG_GETARG_TEXT_PP(0));
	int			from;
	const IndexAmRoutine *orig;
	MemoryContext old;
	ResourceOwner saveowner;
	int64		bufs;
	text	   *res;
	StringInfoData out;

	if (!sess)
		elog(ERROR, "d2_step: no open session scan set");
	from = events->len;
	bufs = pgBufferUsage.shared_blks_hit + pgBufferUsage.shared_blks_read;
	old = MemoryContextSwitchTo(TopTransactionContext);
	saveowner = CurrentResourceOwner;
	CurrentResourceOwner = TopTransactionResourceOwner;
	orig = attach(sess->irel);
	PG_TRY();
	{
		if (!d2_refused)
			drv_step(sess, step);
	}
	PG_FINALLY();
	{
		detach(sess->irel, orig);
		CurrentResourceOwner = saveowner;
		MemoryContextSwitchTo(old);
	}
	PG_END_TRY();
	bufs = pgBufferUsage.shared_blks_hit + pgBufferUsage.shared_blks_read - bufs;

	/* the step's events, then the shared buffers it touched (coverage) */
	res = events_since(from);
	initStringInfo(&out);
	appendBinaryStringInfo(&out, VARDATA_ANY(res), VARSIZE_ANY_EXHDR(res) - 1);
	appendStringInfo(&out, "%s{\"buffers\":" INT64_FORMAT "}]",
					 VARSIZE_ANY_EXHDR(res) > 2 ? "," : "", bufs);
	PG_RETURN_TEXT_P(cstring_to_text_with_len(out.data, out.len));
}

PG_FUNCTION_INFO_V1(d2_close);
Datum
d2_close(PG_FUNCTION_ARGS)
{
	int			from;
	const IndexAmRoutine *orig;
	MemoryContext old;
	ResourceOwner saveowner;

	if (!sess)
		elog(ERROR, "d2_close: no open session scan set");
	from = events->len;
	old = MemoryContextSwitchTo(TopTransactionContext);
	saveowner = CurrentResourceOwner;
	CurrentResourceOwner = TopTransactionResourceOwner;
	orig = attach(sess->irel);
	PG_TRY();
	{
		drv_end_all(sess);
	}
	PG_FINALLY();
	{
		detach(sess->irel, orig);
		d2ctl_reset();
		UnregisterSnapshotFromOwner(sess->snap, TopTransactionResourceOwner);
		drv_close(sess);
		CurrentResourceOwner = saveowner;
		MemoryContextSwitchTo(old);
	}
	PG_END_TRY();
	sess = NULL;
	PG_RETURN_TEXT_P(events_since(from));
}

/*
 * ---- d2_observe(index, query) -> json events ----
 * Runs query with the observer on the index: the callbacks the executor
 * makes are recorded; a guard violation is an ERROR.
 */
PG_FUNCTION_INFO_V1(d2_observe);
Datum
d2_observe(PG_FUNCTION_ARGS)
{
	Relation	irel = index_open(PG_GETARG_OID(0), AccessShareLock);
	char	   *query = text_to_cstring(PG_GETARG_TEXT_PP(1));
	const IndexAmRoutine *orig;
	text	   *result;

	orig = install(irel, false);
	PG_TRY();
	{
		SPI_connect();
		if (SPI_execute(query, false, 0) < 0)
			elog(ERROR, "d2_observe: query failed");
		SPI_finish();
	}
	PG_FINALLY();
	{
		uninstall(irel, orig);
	}
	PG_END_TRY();
	result = events_text();
	index_close(irel, AccessShareLock);
	PG_RETURN_TEXT_P(result);
}

void
_PG_init(void)
{
	d2ctl_init();
}

/*
 * ---- d2_observe_cursor(index, query, fetches text[]) -> json events ----
 * Opens query as a scroll cursor (the portal path FETCH uses) and runs the
 * fetches: "forward N", "backward N", "absolute N" (N = all for all rows).
 */
PG_FUNCTION_INFO_V1(d2_observe_cursor);
Datum
d2_observe_cursor(PG_FUNCTION_ARGS)
{
	Relation	irel = index_open(PG_GETARG_OID(0), AccessShareLock);
	char	   *query = text_to_cstring(PG_GETARG_TEXT_PP(1));
	Datum	   *f;
	bool	   *nulls;
	int			nf;
	const IndexAmRoutine *orig;
	text	   *result;

	deconstruct_array_builtin(PG_GETARG_ARRAYTYPE_P(2), TEXTOID, &f, &nulls, &nf);
	orig = install(irel, false);
	PG_TRY();
	{
		SPIPlanPtr	plan;
		Portal		portal;

		SPI_connect();
		plan = SPI_prepare_cursor(query, 0, NULL, CURSOR_OPT_SCROLL);
		if (plan == NULL)
			elog(ERROR, "d2_observe_cursor: prepare failed");
		portal = SPI_cursor_open(NULL, plan, NULL, NULL, true);
		for (int i = 0; i < nf; i++)
		{
			char	   *s = TextDatumGetCString(f[i]);
			char		how[16], cnt[16];
			long		count;
			FetchDirection dir;

			if (sscanf(s, "%15s %15s", how, cnt) != 2)
				elog(ERROR, "d2_observe_cursor: bad fetch \"%s\"", s);
			count = strcmp(cnt, "all") == 0 ? FETCH_ALL : atol(cnt);
			if (strcmp(how, "forward") == 0)
				dir = FETCH_FORWARD;
			else if (strcmp(how, "backward") == 0)
				dir = FETCH_BACKWARD;
			else if (strcmp(how, "absolute") == 0)
				dir = FETCH_ABSOLUTE;
			else
				elog(ERROR, "d2_observe_cursor: bad fetch \"%s\"", s);
			SPI_scroll_cursor_fetch(portal, dir, count);
		}
		SPI_cursor_close(portal);
		SPI_finish();
	}
	PG_FINALLY();
	{
		uninstall(irel, orig);
	}
	PG_END_TRY();
	result = events_text();
	index_close(irel, AccessShareLock);
	PG_RETURN_TEXT_P(result);
}
