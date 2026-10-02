/*
 * d2proto.h
 *	  Shared between the observer (d2proto.c) and the test-only control
 *	  layers (d2_ctl.c).
 */
#ifndef D2PROTO_H
#define D2PROTO_H

#include "access/amapi.h"

enum
{
	CB_BEGIN, CB_RESCAN, CB_GET, CB_END, CB_MARK, CB_RESTR, CB_COUNT
};

/* control layers: return the routine to use, possibly a faulty wrapper */
extern const IndexAmRoutine *d2ctl_am_layer(const IndexAmRoutine *real);
extern const IndexAmRoutine *d2ctl_caller_layer(const IndexAmRoutine *observer);
extern void d2ctl_reset(void);
extern void d2ctl_init(void);

#endif
