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
 *	  skip_after_growth   once the index has grown since amrescan (a
 *	                   concurrent insert split a page), one entry is skipped
 *	                   (S6: an entry not being inserted or deleted is missed)
 *	  repeat_after_growth  once the index has grown since amrescan, the
 *	                   previous entry is returned once more (S6: multiplied)
 *	  skip_invisible   entries whose heap tuple the scan's snapshot cannot
 *	                   see are skipped although they are still in the index
 *	                   (S6: an entry of a deleted row disappears from the
 *	                   scan without having been removed from the index)
 *	  restore_shift_on_growth  if the index has grown since ammarkpos,
 *	                   amrestrpos lands one entry past the mark: the next
 *	                   forward entry is consumed (S5-concurrent: restore to
 *	                   the wrong place)
 *	  restore_lost_on_growth  if the index has grown since ammarkpos,
 *	                   amrestrpos restarts the scan instead (S5-concurrent:
 *	                   the mark is lost)
 *	  collect_all      the first amgettuple after amrescan reads every
 *	                   matching entry (TID, returned data, recheck) and
 *	                   the scan then returns them from memory: the AM holds
 *	                   nothing in the index while returning them, as an AM
 *	                   without the scan/VACUUM interlock would (V5: forward
 *	                   scans only)
 *
 *	  Above the observer (a faulty caller):
 *	  caller_more_keys amrescan is called with one key more than
 *	                   ambeginscan announced (S8); the observer's guard
 *	                   must stop it before the AM sees it
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/htup_details.h"
#include "access/itup.h"
#include "access/relscan.h"
#include "access/tableam.h"
#include "access/xact.h"
#include "fmgr.h"
#include "storage/bufmgr.h"
#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/resowner.h"

#include "d2proto.h"

enum
{
	F_NONE, F_ITUP_SHARED, F_DIR_FROM_START, F_RESTORE_ONCE, F_CALLER_MORE_KEYS,
	F_SKIP_AFTER_GROWTH, F_REPEAT_AFTER_GROWTH, F_SKIP_INVISIBLE,
	F_RESTORE_SHIFT_ON_GROWTH, F_RESTORE_LOST_ON_GROWTH, F_COLLECT_ALL
};

static const struct config_enum_entry fault_options[] = {
	{"none", F_NONE, false},
	{"itup_shared", F_ITUP_SHARED, false},
	{"dir_from_start", F_DIR_FROM_START, false},
	{"restore_once", F_RESTORE_ONCE, false},
	{"caller_more_keys", F_CALLER_MORE_KEYS, false},
	{"skip_after_growth", F_SKIP_AFTER_GROWTH, false},
	{"repeat_after_growth", F_REPEAT_AFTER_GROWTH, false},
	{"skip_invisible", F_SKIP_INVISIBLE, false},
	{"restore_shift_on_growth", F_RESTORE_SHIFT_ON_GROWTH, false},
	{"restore_lost_on_growth", F_RESTORE_LOST_ON_GROWTH, false},
	{"collect_all", F_COLLECT_ALL, false},
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
	BlockNumber nblocks;		/* index size at amrescan */
	bool		fired;			/* growth fault applied (once per rescan) */
	BlockNumber mark_nblocks;	/* index size at ammarkpos */
	ItemPointerData last;		/* previous returned TID */
	bool		haslast;
	/* collect_all: what the first amgettuple read */
	bool		collected;
	int			ncoll;
	int			next;
	ItemPointerData *tids;
	IndexTuple *itups;
	HeapTuple  *hitups;
	bool	   *rechecks;
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
	cscans[ncscans].nblocks = InvalidBlockNumber;
	cscans[ncscans].fired = false;
	cscans[ncscans].mark_nblocks = InvalidBlockNumber;
	cscans[ncscans].haslast = false;
	cscans[ncscans].collected = false;
	return &cscans[ncscans++];
}

static void
ctl_rescan(IndexScanDesc scan, ScanKey keys, int nkeys, ScanKey orderbys, int norderbys)
{
	CtlScan    *c = cscan(scan);

	c->lastdir = 0;
	c->nblocks = RelationGetNumberOfBlocks(scan->indexRelation);
	c->fired = false;
	c->haslast = false;
	c->mark_nblocks = InvalidBlockNumber;
	c->collected = false;
	real->amrescan(scan, keys, nkeys, orderbys, norderbys);
}

/* collect_all: read everything at the first call, then return from memory */
static bool
collect_gettuple(IndexScanDesc scan, CtlScan *c, ScanDirection dir)
{
	int			i;

	if (ScanDirectionIsBackward(dir))
		elog(ERROR, "d2_ctl: collect_all supports forward scans only");
	if (!c->collected)
	{
		MemoryContext old = MemoryContextSwitchTo(TopTransactionContext);
		int			cap = 64;

		c->ncoll = 0;
		c->next = 0;
		c->tids = palloc_array(ItemPointerData, cap);
		c->itups = palloc_array(IndexTuple, cap);
		c->hitups = palloc_array(HeapTuple, cap);
		c->rechecks = palloc_array(bool, cap);
		while (real->amgettuple(scan, dir))
		{
			if (c->ncoll == cap)
			{
				cap *= 2;
				c->tids = repalloc_array(c->tids, ItemPointerData, cap);
				c->itups = repalloc_array(c->itups, IndexTuple, cap);
				c->hitups = repalloc_array(c->hitups, HeapTuple, cap);
				c->rechecks = repalloc_array(c->rechecks, bool, cap);
			}
			c->tids[c->ncoll] = scan->xs_heaptid;
			c->itups[c->ncoll] = scan->xs_itup ? CopyIndexTuple(scan->xs_itup) : NULL;
			c->hitups[c->ncoll] = scan->xs_hitup ? heap_copytuple(scan->xs_hitup) : NULL;
			c->rechecks[c->ncoll] = scan->xs_recheck;
			c->ncoll++;
		}
		MemoryContextSwitchTo(old);
		c->collected = true;
	}
	if (c->next >= c->ncoll)
		return false;
	i = c->next++;
	scan->xs_heaptid = c->tids[i];
	scan->xs_itup = c->itups[i];
	scan->xs_hitup = c->hitups[i];
	scan->xs_recheck = c->rechecks[i];
	return true;
}

static bool
ctl_gettuple(IndexScanDesc scan, ScanDirection dir)
{
	CtlScan    *c = cscan(scan);
	int			d = ScanDirectionIsBackward(dir) ? -1 : 1;
	bool		ret;

	if (fault == F_COLLECT_ALL)
		return collect_gettuple(scan, c, dir);

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

	while (fault == F_SKIP_INVISIBLE && ret && scan->heapRelation)
	{
		ItemPointerData tid = scan->xs_heaptid;

		if (table_fetch_tid(scan->heapRelation, &tid, scan->xs_snapshot, NULL))
			break;
		ret = real->amgettuple(scan, dir);
	}

	if ((fault == F_SKIP_AFTER_GROWTH || fault == F_REPEAT_AFTER_GROWTH) && ret && !c->fired &&
		c->nblocks != InvalidBlockNumber &&
		RelationGetNumberOfBlocks(scan->indexRelation) > c->nblocks)
	{
		c->fired = true;
		if (fault == F_SKIP_AFTER_GROWTH)
			ret = real->amgettuple(scan, dir);
		else if (c->haslast)
			scan->xs_heaptid = c->last;
	}
	if (ret)
	{
		c->last = scan->xs_heaptid;
		c->haslast = true;
	}

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
	cscan(scan)->mark_nblocks = RelationGetNumberOfBlocks(scan->indexRelation);
	real->ammarkpos(scan);
}

static void
ctl_restrpos(IndexScanDesc scan)
{
	CtlScan    *c = cscan(scan);
	bool		grown;

	if (fault == F_RESTORE_ONCE && c->restores++ > 0)
		return;
	grown = c->mark_nblocks != InvalidBlockNumber &&
		RelationGetNumberOfBlocks(scan->indexRelation) > c->mark_nblocks;
	if (fault == F_RESTORE_LOST_ON_GROWTH && grown)
	{
		/* restart with the keys the AM already holds */
		ScanKey		k = NULL;

		if (scan->numberOfKeys > 0)
		{
			k = palloc_array(ScanKeyData, scan->numberOfKeys);
			memcpy(k, scan->keyData, scan->numberOfKeys * sizeof(ScanKeyData));
		}
		real->amrescan(scan, k, scan->numberOfKeys, NULL, 0);
		return;
	}
	real->amrestrpos(scan);
	if (fault == F_RESTORE_SHIFT_ON_GROWTH && grown)
		(void) real->amgettuple(scan, ForwardScanDirection);
}

const IndexAmRoutine *
d2ctl_am_layer(const IndexAmRoutine *r)
{
	real = r;
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

/*
 * ---- d2_ctl_install(index) ----
 * Put the AM control layer (d2_ctl.fault) in front of the index's routine
 * for the rest of the transaction, so that the executor's own scans of it
 * (a cursor) go through the layer.  No observer.  The index stays open
 * until the transaction ends, when the routine is put back.
 */
static Relation inst_rel;
static const IndexAmRoutine *inst_orig;
static bool inst_cb_registered;

static void
inst_xact_cb(XactEvent event, void *arg)
{
	if (!inst_rel)
		return;
	if (event == XACT_EVENT_PRE_COMMIT || event == XACT_EVENT_PARALLEL_PRE_COMMIT ||
		event == XACT_EVENT_PRE_PREPARE)
	{
		inst_rel->rd_indam = inst_orig;
		index_close(inst_rel, NoLock);
		inst_rel = NULL;
		d2ctl_reset();
	}
	else if (event == XACT_EVENT_ABORT || event == XACT_EVENT_PARALLEL_ABORT)
	{
		/* the resource owner drops the reference */
		inst_rel->rd_indam = inst_orig;
		inst_rel = NULL;
		d2ctl_reset();
	}
}

PG_FUNCTION_INFO_V1(d2_ctl_install);
Datum
d2_ctl_install(PG_FUNCTION_ARGS)
{
	ResourceOwner saveowner;

	if (!IsTransactionBlock())
		elog(ERROR, "d2_ctl_install: must run inside a transaction block");
	if (inst_rel)
		elog(ERROR, "d2_ctl_install: a layer is already installed");
	if (!inst_cb_registered)
	{
		RegisterXactCallback(inst_xact_cb, NULL);
		inst_cb_registered = true;
	}
	saveowner = CurrentResourceOwner;
	CurrentResourceOwner = TopTransactionResourceOwner;
	inst_rel = index_open(PG_GETARG_OID(0), AccessShareLock);
	CurrentResourceOwner = saveowner;
	inst_orig = inst_rel->rd_indam;
	d2ctl_reset();
	inst_rel->rd_indam = d2ctl_am_layer(inst_orig);
	PG_RETURN_VOID();
}
