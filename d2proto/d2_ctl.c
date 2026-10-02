/*-------------------------------------------------------------------------
 *
 * d2_ctl.c
 *	  Test-only control layers for D2.  d2_ctl.fault breaks exactly one
 *	  protocol property; "none" installs nothing.
 *
 *	  Below the observer (a faulty AM):
 *	  itup_shared      returned index data is copied into one buffer shared
 *	                   by all scans: valid only until the next amgettuple of
 *	                   any scan, not of the same scan (S7)
 *	  dir_from_start   a change of direction restarts the scan in the new
 *	                   direction instead of moving from the last returned
 *	                   entry (S4)
 *	  restore_once     only the first amrestrpos after a mark restores (S5)
 *
 *	  Above the observer (a faulty caller):
 *	  caller_more_keys amrescan is called with one key more than
 *	                   ambeginscan announced (S8); the observer's guard
 *	                   must stop it before the AM sees it
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/relscan.h"
#include "utils/guc.h"
#include "utils/memutils.h"

#include "d2proto.h"

enum
{
	F_NONE, F_ITUP_SHARED, F_DIR_FROM_START, F_RESTORE_ONCE, F_CALLER_MORE_KEYS
};

static const struct config_enum_entry fault_options[] = {
	{"none", F_NONE, false},
	{"itup_shared", F_ITUP_SHARED, false},
	{"dir_from_start", F_DIR_FROM_START, false},
	{"restore_once", F_RESTORE_ONCE, false},
	{"caller_more_keys", F_CALLER_MORE_KEYS, false},
	{NULL, 0, false}
};

static int	fault = F_NONE;
static const IndexAmRoutine *real;
static const IndexAmRoutine *above;
static IndexAmRoutine am_layer;
static IndexAmRoutine caller_layer;

/* per-scan control state */
typedef struct CtlScan
{
	IndexScanDesc scan;
	int			lastdir;		/* 0 none, 1 forward, -1 backward (since rescan) */
	int			restores;		/* since last mark */
} CtlScan;

static CtlScan cscans[16];
static int	ncscans;

/* itup_shared: one buffer for every scan */
static char *shared_buf;
static HeapTupleData shared_htup;

void
d2ctl_init(void)
{
	DefineCustomEnumVariable("d2_ctl.fault", "Protocol property broken by the D2 control layer.",
							 NULL, &fault, F_NONE, fault_options, PGC_USERSET, 0,
							 NULL, NULL, NULL);
	MarkGUCPrefixReserved("d2_ctl");
}

void
d2ctl_reset(void)
{
	ncscans = 0;
}

static CtlScan *
cscan(IndexScanDesc scan)
{
	for (int i = 0; i < ncscans; i++)
		if (cscans[i].scan == scan)
			return &cscans[i];
	if (ncscans >= lengthof(cscans))
		elog(ERROR, "d2_ctl: too many scans");
	cscans[ncscans].scan = scan;
	cscans[ncscans].lastdir = 0;
	cscans[ncscans].restores = 0;
	return &cscans[ncscans++];
}

static void
ctl_rescan(IndexScanDesc scan, ScanKey keys, int nkeys, ScanKey orderbys, int norderbys)
{
	cscan(scan)->lastdir = 0;
	real->amrescan(scan, keys, nkeys, orderbys, norderbys);
}

static bool
ctl_gettuple(IndexScanDesc scan, ScanDirection dir)
{
	CtlScan    *c = cscan(scan);
	int			d = ScanDirectionIsBackward(dir) ? -1 : 1;
	bool		ret;

	if (fault == F_DIR_FROM_START && c->lastdir != 0 && c->lastdir != d)
	{
		/* restart with the keys the AM already holds */
		ScanKey		k = NULL;

		if (scan->numberOfKeys > 0)
		{
			k = palloc_array(ScanKeyData, scan->numberOfKeys);
			memcpy(k, scan->keyData, scan->numberOfKeys * sizeof(ScanKeyData));
		}
		real->amrescan(scan, k, scan->numberOfKeys, NULL, 0);
	}
	c->lastdir = d;
	ret = real->amgettuple(scan, dir);

	if (fault == F_ITUP_SHARED && ret && scan->xs_want_itup)
	{
		if (!shared_buf)
			shared_buf = MemoryContextAlloc(TopMemoryContext, BLCKSZ);
		if (scan->xs_hitup)
		{
			shared_htup = *scan->xs_hitup;
			memcpy(shared_buf, scan->xs_hitup->t_data, scan->xs_hitup->t_len);
			shared_htup.t_data = (HeapTupleHeader) shared_buf;
			scan->xs_hitup = &shared_htup;
		}
		else if (scan->xs_itup)
		{
			memcpy(shared_buf, scan->xs_itup, IndexTupleSize(scan->xs_itup));
			scan->xs_itup = (IndexTuple) shared_buf;
		}
	}
	return ret;
}

static void
ctl_markpos(IndexScanDesc scan)
{
	cscan(scan)->restores = 0;
	real->ammarkpos(scan);
}

static void
ctl_restrpos(IndexScanDesc scan)
{
	CtlScan    *c = cscan(scan);

	if (fault == F_RESTORE_ONCE && c->restores++ > 0)
		return;
	real->amrestrpos(scan);
}

const IndexAmRoutine *
d2ctl_am_layer(const IndexAmRoutine *r)
{
	real = r;
	ncscans = 0;
	if (fault == F_NONE || fault == F_CALLER_MORE_KEYS)
		return r;
	am_layer = *r;
	am_layer.amrescan = ctl_rescan;
	if (r->amgettuple)
		am_layer.amgettuple = ctl_gettuple;
	if (r->ammarkpos)
		am_layer.ammarkpos = ctl_markpos;
	if (r->amrestrpos)
		am_layer.amrestrpos = ctl_restrpos;
	return &am_layer;
}

static void
caller_rescan(IndexScanDesc scan, ScanKey keys, int nkeys, ScanKey orderbys, int norderbys)
{
	ScanKey		more = NULL;

	if (keys && nkeys > 0)
	{
		more = palloc_array(ScanKeyData, nkeys + 1);
		memcpy(more, keys, nkeys * sizeof(ScanKeyData));
		more[nkeys] = keys[nkeys - 1];
		keys = more;
		nkeys++;
	}
	above->amrescan(scan, keys, nkeys, orderbys, norderbys);
}

const IndexAmRoutine *
d2ctl_caller_layer(const IndexAmRoutine *observer)
{
	above = observer;
	if (fault != F_CALLER_MORE_KEYS)
		return observer;
	caller_layer = *observer;
	caller_layer.amrescan = caller_rescan;
	return &caller_layer;
}
