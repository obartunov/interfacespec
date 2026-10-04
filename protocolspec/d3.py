#!/usr/bin/env python3
"""D3 engine (S6, S5-concurrent): concurrencyspec + protocolspec -> histories
in which a second session acts between callbacks of an open scan -> allowed
outcome sets -> conformance result.

Uses the protocolspec model (engine.Protocol) unchanged.  Knows no AM: the
data each actor uses comes from the subjects file.

usage: d3.py PROTOCOLSPEC CONCURRENCYSPEC SUBJECTS [--profile s6|s5_concurrent]
             [--fault NAME] [--depth N]
"""
import argparse
import itertools
import json
import select
import sys

import psycopg2
import psycopg2.extensions
import yaml

import engine


def connect(async_=False):
    return psycopg2.connect(dbname='d2t', host='/tmp', port=engine_port(), user=engine_user(),
                            async_=1 if async_ else 0)


def engine_port():
    import os
    return int(os.environ.get('PGPORT', 5432))


def engine_user():
    import os
    return os.environ.get('PGUSER', 'postgres')


def wait(conn, timeout=None):
    """Poll an async connection; returns True when idle, False on timeout."""
    while True:
        state = conn.poll()
        if state == psycopg2.extensions.POLL_OK:
            return True
        r, w = ([conn.fileno()], []) if state == psycopg2.extensions.POLL_READ else ([], [conn.fileno()])
        rr, ww, _ = select.select(r, w, [], timeout)
        if not rr and not ww:
            return False


class B:
    """The second actor: an async autocommit session.  Whether its running
    statement has completed or waits for another backend is read from the
    server (pg_stat_activity of B through a monitor session), never from
    elapsed time; EMERGENCY only stops a hung stand."""
    WAITS_FOR_OTHERS = ('Lock', 'Buffer', 'BufferPin')     # wait_event_type
    EMERGENCY = 60.0                                         # seconds

    def __init__(self):
        self.conn = connect(async_=True)
        wait(self.conn)
        self.cur = self.conn.cursor()
        self.cur.execute("SELECT pg_backend_pid()")
        wait(self.conn)
        self.pid = self.cur.fetchone()[0]
        self.mon = connect()
        self.mon.autocommit = True
        self.running = None
        self.was_blocked = False

    def run(self, sql):
        self.finish()
        self.cur.execute(sql)
        wait(self.conn)
        return self.cur.fetchall() if self.cur.description else []

    def start(self, sql):
        """Start sql; returns its state once it is settled (settle())."""
        self.finish()
        self.cur.execute(sql)
        self.running = sql
        self.was_blocked = False
        return self.settle()

    def settle(self):
        """Wait until B's statement has completed or waits for another
        backend.  Returns ('completed' | 'blocked', wait event or None)."""
        if not self.running:
            return 'completed', None
        m = self.mon.cursor()
        waited = 0.0
        while not wait(self.conn, 0.02):
            waited += 0.02
            m.execute("SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = %s", (self.pid,))
            row = m.fetchone()
            if row and row[0] in self.WAITS_FOR_OTHERS:
                self.was_blocked = True
                return 'blocked', f"{row[0]}/{row[1]}"
            if waited > self.EMERGENCY:
                raise RuntimeError(f"stand hung: B ({self.running}) neither completed nor waits after {self.EMERGENCY}s")
        self.running = None
        return 'completed', None

    def present(self, index, opr, val, n):
        """The entries the index holds now, by a fresh forward scan from the
        monitor session (the AM without control layers)."""
        return set(self.contents(index, opr, val, n))

    def contents(self, index, opr, val, n):
        """The same, in the order of that forward scan."""
        m = self.mon.cursor()
        hist = ['R.ambeginscan', 'R.amrescan:given'] + ['R.amgettuple:forward'] * (n + 1)
        m.execute("SET d2_ctl.fault = 'none'")
        m.execute("SELECT d2_run(%s, %s, %s, false, %s)", (index, opr, val, hist))
        ev = m.fetchone()[0]
        return [e['tid'] for e in ev if e['cb'] == 'amgettuple' and e['ret']]

    def leaves(self, index, opr, val, n):
        """Coverage only: a forward pass through the session driver from
        the monitor session; an entry starts a new group when its
        amgettuple touched a shared buffer (the AM read another page).
        Returns {tid: group}."""
        m = self.mon.cursor()
        m.execute("SET d2_ctl.fault = 'none'")
        m.execute("BEGIN")
        m.execute("SELECT d2_open(%s, %s, %s, false)", (index, opr, val))
        for st in ('A.ambeginscan', 'A.amrescan:given'):
            m.execute("SELECT d2_step(%s)", (st,))
        group, out = -1, {}
        for _ in range(n + 1):
            m.execute("SELECT d2_step('A.amgettuple:forward')")
            ev = m.fetchone()[0]
            if not ev[0].get('ret'):
                break
            group += 1 if ev[-1].get('buffers') or group < 0 else 0
            out[ev[0]['tid']] = group
        m.execute("SELECT d2_close()")
        m.execute("COMMIT")
        return out

    def finish(self):
        if self.running:
            wait(self.conn)
            self.running = None


class Checker:
    """S6 outcome check of A's amgettuple observations against the
    protocolspec model (engine.Protocol, unchanged).

    must:  reference entries L; in L's order if amcanorder, otherwise in
           the order A first returns them ('*' = any not yet returned).
    may:   inserted entries (never in L): A stays between the same must
           entries (gap); removed entries: entries of rows deleted before A
           began that are observed gone from the index (set_removed)
           (optional: may be returned in their place, or skipped).
    must_not: anything else.

    mark/restore (S5-concurrent): the mark is the protocolspec mark (an
    index into the must sequence) plus the gap flag; restore puts both
    back.  A removed marked entry returned again as the first outcome
    after restore is not said by the interface: self.domain, no verdict.
    """
    def __init__(self, proto, cap, L, deleted):
        self.proto = proto
        self.L = list(L)
        self.ordered = bool(cap.get('amcanorder'))
        self.seq = list(L) if self.ordered else []
        self.unseen = set(L)
        self.deleted = set(deleted)
        self.optional = set()
        self.inserted = set()
        self.gap = False
        self.skipped = set()            # removed entries the scan passed over
        self.mark_gap = False
        self.mark_entry = None          # the marked must entry (None: marked in a gap)
        self.restored = False           # no outcome yet since restore
        self.domain = None
        self.state = proto.initial()

    def set_removed(self, removed):
        """Entries observed gone from the index; removal is monotonic, so
        an entry still present then was present during the whole step."""
        self.optional = set(removed) & self.deleted

    def _view(self, stars=True):
        return self.seq + (['*'] * len(self.unseen) if stars and not self.ordered else [])

    def _probe(self, fwd):
        st = self.state
        if self.gap and not fwd:
            st = engine.NS(st)
            st['pos'] = st.pos + 1
        return st

    def admit(self, name, arg):
        """Obligation/domain of A's next operation on the observed state."""
        view = self._view()
        status, _, _, _ = self.proto.step(self._probe(arg.get('direction') == 'forward'), name, arg, view, len(view))
        return status

    def apply(self, name, arg):
        """An operation without an outcome (mark, restore): its protocolspec
        effect; the mark also keeps the gap flag and the marked entry."""
        view = self._view()
        _, _, new, _ = self.proto.step(self.state, name, arg, view, len(view))
        cb = self.proto.ops[name]['callback']
        if cb == 'ammarkpos':
            self.mark_gap = self.gap
            pos = self.state.pos
            self.mark_entry = None if self.gap or pos is None or not 0 <= pos < len(view) else view[pos]
        elif cb == 'amrestrpos':
            self.gap = self.mark_gap
            self.restored = True
        self.state = new

    def observe(self, name, arg, o):
        """Returns None or a failure text; updates the model."""
        fwd = arg.get('direction') == 'forward'
        just_restored, self.restored = self.restored, False
        got = o['tid'] if o.get('ret') else 'false'
        if o.get('ret') and o['tid'] in self.inserted:
            st = engine.NS(self.state)
            if not self.gap:
                if st.pos is None:
                    st['pos'] = -1 if fwd else len(self._view()) - 1
                elif not fwd:
                    st['pos'] = st.pos - 1
                self.gap = True
            st['first'] = st.first or arg.get('direction')
            st['positioned'] = True
            st['ran_off'] = None
            self.state = st
            return None
        if o.get('ret') and o['tid'] not in self.L:
            return f"must_not: {got} was never in the index during the scan"
        # walk the model: every optional entry on the way may come, or be skipped
        st = self._probe(fwd)
        accept = {}
        passed = {}                     # outcome -> optional entries passed over to reach it
        walked = []
        while True:
            view = self._view()
            _, expect, new, _ = self.proto.step(st, name, arg, view, len(view))
            nxt = expect['tid'] if expect.get('ret') else 'false'
            if nxt == '*':
                if o.get('ret') and o['tid'] in self.unseen:
                    self.seq.append(o['tid'])
                    view = self._view()
                    _, _, new, _ = self.proto.step(st, name, arg, view, len(view))
                    accept[got] = new
                elif not o.get('ret') and self.unseen <= self.optional:
                    _, _, new, _ = self.proto.step(st, name, arg, self.seq, len(self.seq))
                    accept['false'] = new
                break
            accept[nxt] = new
            passed[nxt] = list(walked)
            if nxt in self.optional:
                walked.append(nxt)
                st = new
                continue
            break
        if got not in accept:
            if just_restored and got == self.mark_entry and got in self.optional:
                self.domain = f"the removed marked entry {got} returned again right after restore"
                return None
            want = ' or '.join(k if k != '*' else 'a stable entry not yet returned' for k in accept) \
                or f"one of the {len(self.unseen - self.optional)} stable entries not yet returned"
            return f"expected {want}, observed {got}"
        self.state = accept[got]
        self.skipped |= set(passed.get(got, []))
        self.gap = False
        if o.get('ret'):
            self.unseen.discard(o['tid'])
        return None


def tid_reuse(initial_tids, inserted_tids):
    """The observer identifies an index entry by heap TID.  An inserted row
    that got the TID of an entry present when the scan began would be
    indistinguishable from it: such a history is outside the experiment
    (BOUNDARY), whatever the scan returns."""
    return set(inserted_tids) & set(initial_tids)


def selftest(pspec, profile='s6'):
    """Model-level controls, no database: each case must give the stated
    verdict, so a change of the outcome rules shows up here."""
    def run(cap, L, deleted, script, remove_at=None, removed=(), inserted=()):
        proto = engine.Protocol(pspec, cap)
        c = Checker(proto, cap, L, deleted)
        c.inserted = set(inserted)
        c.state = proto.step(proto.step(c.state, 'begin', {}, None, None)[2], 'rescan', {'keys': 'given'}, None, None)[2]
        for i, (d, got) in enumerate(script):
            if i == remove_at:
                c.set_removed(set(removed))      # what the enumeration found gone
            if d in ('mark', 'restore'):
                if c.admit(d, {}) != 'ok':
                    return 'cut'
                c.apply(d, {})
                continue
            arg = {'direction': d}
            if c.admit('get', arg) != 'ok':
                return 'cut'
            f = c.observe('get', arg, {'ret': got != 'false', 'tid': got if got != 'false' else None})
            if c.domain:
                return 'DOMAIN'
            if f:
                return 'FAIL'
        return 'pass'
    unordered = {'amcanorder': False, 'amcanbackward': True}
    ordered = {'amcanorder': True, 'amcanbackward': True}
    F, Bk = 'forward', 'backward'
    if profile == 's5_concurrent':
        return selftest_s5(run, dict(ordered, ammarkpos=True, amrestrpos=True))
    cases = [
        ('unordered AM, stable entries in another order than the reference', 'pass',
         run(unordered, ['a', 'b', 'c'], [], [(F, 'b'), (F, 'a'), (F, 'c'), (F, 'false')])),
        ('ordered AM, the same observation', 'FAIL',
         run(ordered, ['a', 'b', 'c'], [], [(F, 'b'), (F, 'a'), (F, 'c'), (F, 'false')])),
        ('unordered AM, a stable entry missing at the end', 'FAIL',
         run(unordered, ['a', 'b', 'c'], [], [(F, 'b'), (F, 'a'), (F, 'false')])),
        ('unordered AM, backing up retraces its own order', 'pass',
         run(unordered, ['a', 'b', 'c'], [], [(F, 'c'), (F, 'a'), (Bk, 'c'), (F, 'a'), (F, 'b'), (F, 'false')])),
        ('gap: back from an inserted entry returns the last stable one', 'pass',
         run(ordered, ['a', 'b'], [], [(F, 'a'), (F, 'x'), (Bk, 'a')], inserted=['x'])),
        ('deleted entry skipped after the remove removed it', 'pass',
         run(ordered, ['a', 'd', 'b'], ['d'], [(F, 'a'), (F, 'b'), (F, 'false')], remove_at=1, removed=['d'])),
        ('deleted entry skipped before any remove', 'FAIL',
         run(ordered, ['a', 'd', 'b'], ['d'], [(F, 'a'), (F, 'b'), (F, 'false')])),
        ('remove attempted but blocked, entry still in the index, skipped', 'FAIL',
         run(ordered, ['a', 'd', 'b'], ['d'], [(F, 'a'), (F, 'b'), (F, 'false')], remove_at=1, removed=[])),
        ('deleted entry still returned after the remove removed it', 'pass',
         run(ordered, ['a', 'd', 'b'], ['d'], [(F, 'a'), (F, 'd'), (F, 'b'), (F, 'false')], remove_at=1, removed=['d'])),
    ]
    out = ['== model-level controls']
    for text, want, got in cases:
        out.append(f"   {'ok  ' if got == want else 'BAD '} {text}: {got} (want {want})")
    out.append('== heap TID reuse guard (stand level)')
    for text, initial, inserted, want in [
            ('insert returns new TIDs only', {'T1', 'T2'}, {'T3'}, 'normal'),
            ('insert reuses an initial TID', {'T1', 'T2'}, {'T2', 'T3'}, 'BOUNDARY')]:
        got = 'BOUNDARY' if tid_reuse(initial, inserted) else 'normal'
        out.append(f"   {'ok  ' if got == want else 'BAD '} {text}: {got} (want {want})")
    return out


def selftest_s5(run, cap):
    F, M, R = 'forward', ('mark', None), ('restore', None)
    cases = [
        ('mark, restore, forward: the entry after the marked one', 'pass',
         run(cap, ['a', 'b', 'c', 'd'], [], [(F, 'a'), (F, 'b'), M, (F, 'c'), R, (F, 'c'), (F, 'd'), (F, 'false')])),
        ('restore one entry too far: a stable entry skipped', 'FAIL',
         run(cap, ['a', 'b', 'c', 'd'], [], [(F, 'a'), (F, 'b'), M, (F, 'c'), R, (F, 'd')])),
        ('restore that lost the mark: from the start again', 'FAIL',
         run(cap, ['a', 'b', 'c', 'd'], [], [(F, 'a'), (F, 'b'), M, (F, 'c'), R, (F, 'a')])),
        ('the stable marked entry returned again after restore', 'FAIL',
         run(cap, ['a', 'b', 'c', 'd'], [], [(F, 'a'), (F, 'b'), M, (F, 'c'), R, (F, 'b')])),
        ('an inserted entry returned after restore', 'pass',
         run(cap, ['a', 'b', 'c'], [], [(F, 'a'), M, (F, 'b'), R, (F, 'x'), (F, 'b'), (F, 'c')], inserted=['x'])),
        ('mark in a gap, restore, forward: the next stable entry', 'pass',
         run(cap, ['a', 'b', 'c'], [], [(F, 'a'), (F, 'x'), M, (F, 'b'), (F, 'c'), R, (F, 'b')], inserted=['x'])),
        ('end of the pass right after restore, stable entries left', 'FAIL',
         run(cap, ['a', 'b', 'c'], [], [(F, 'a'), M, (F, 'b'), R, (F, 'false')])),
        ('removal right after the mark: the removed entry skipped after restore', 'pass',
         run(cap, ['a', 'b', 'd', 'c'], ['d'], [(F, 'a'), (F, 'b'), M, (F, 'd'), R, (F, 'c')], remove_at=4, removed=['d'])),
        ('removal right after the mark: the removed entry returned in its place', 'pass',
         run(cap, ['a', 'b', 'd', 'c'], ['d'], [(F, 'a'), (F, 'b'), M, (F, 'd'), R, (F, 'd'), (F, 'c')], remove_at=4, removed=['d'])),
        ('marked entry removed: restore, forward gives the next stable entry', 'pass',
         run(cap, ['a', 'd', 'b'], ['d'], [(F, 'a'), (F, 'd'), M, (F, 'b'), R, (F, 'b'), (F, 'false')], remove_at=3, removed=['d'])),
        ('marked entry removed: a stable entry before the mark after restore', 'FAIL',
         run(cap, ['a', 'd', 'b'], ['d'], [(F, 'a'), (F, 'd'), M, (F, 'b'), R, (F, 'a')], remove_at=3, removed=['d'])),
        ('marked entry removed: returned again right after restore', 'DOMAIN',
         run(cap, ['a', 'd', 'b'], ['d'], [(F, 'a'), (F, 'd'), M, (F, 'b'), R, (F, 'd')], remove_at=3, removed=['d'])),
        ('marked entry deleted, still in the index: returned again after restore', 'FAIL',
         run(cap, ['a', 'd', 'b'], ['d'], [(F, 'a'), (F, 'd'), M, (F, 'b'), R, (F, 'd')], remove_at=3, removed=[])),
    ]
    out = ['== model-level controls (S5-concurrent)']
    for text, want, got in cases:
        out.append(f"   {'ok  ' if got == want else 'BAD '} {text}: {got} (want {want})")
    return out


EVIDENCE = []        # counts that depend on server scheduling: reported, not compared


def parse_op(item):
    """'A.get(forward)*2' -> ('A', 'get', 'forward', 2)."""
    actor, rest = item.split('.', 1)
    rest, _, times = rest.partition('*')
    name, _, a = rest.partition('(')
    return actor, name, a.rstrip(')') or None, int(times or 1)


def run_subject(pspec, cspec, subj, fault, depth, profile='s6'):
    gen = cspec['generation'][profile]
    a = connect()
    b = B()
    sa = a.cursor()
    obs = pspec['observables']['returned_data']
    sa.execute("SET d2_ctl.fault = %s", (fault,))
    sa.execute("SELECT d2_configure(%s, %s)", (obs['lifetime_ends'],
               [g for op in pspec['operations'].values() for g in op.get('guard', [])]))
    sa.execute("SELECT d2_caps(%s)", (subj['index'],))
    cap = sa.fetchone()[0]
    a.commit()
    proto = engine.Protocol(pspec, cap)
    out = [f"== {subj['name']}  caps: " + ' '.join(k for k, v in sorted(cap.items()) if v)]

    alphabet = []
    for item in gen['alphabet']:
        actor, name, a_, times = parse_op(item)
        if actor == 'A':
            if name not in proto.ops:
                continue                 # the AM lacks the callback: n/a
            alphabet += [('A', n, arg, times) for n, arg in proto.instances(name)
                         if a_ is None or a_ in arg.values()]
        else:
            alphabet.append(('B', name, {}, 1))
    need = {parse_op(item)[1] for item in gen.get('order', [])}
    if not need <= set(proto.ops):
        out.append(f"   {gen['contract']}: n/a (no " + ', '.join(sorted(need - set(proto.ops))) + ")")
        a.close()
        b.mon.close()
        b.conn.close()
        return out
    prologue = []
    for item in gen['prologue']:
        actor, name, a_, times = parse_op(item)
        arg = {list(proto.ops[name]['args'])[0]: a_} if a_ is not None else {}
        prologue.append((actor, name, arg, times))
    # bounded enumeration: every body of length depth within the limits and
    # holding the 'order' operations in that order (A's obligations/domains
    # are checked on the observed state when the history runs)
    depth = gen.get('depth', depth)

    def key(i):
        return alphabet[i][0] + '.' + alphabet[i][1]

    def within(bd):
        for k, v in gen['limits'].items():
            if sum(1 for i in bd if key(i) == k or alphabet[i][0] == k) > v:
                return False
        if 'order' in gen:
            pos = [next((j for j, i in enumerate(bd) if key(i) == k), None) for k in gen['order']]
            return None not in pos and pos == sorted(pos)
        return True
    bodies = [bd for bd in itertools.product(range(len(alphabet)), repeat=depth) if within(bd)]

    opr, val = subj.get('opr'), subj.get('val')
    stats = {'histories': len(bodies), 'cut': 0, 'gets': 0, 'may': 0, 'inserted': 0,
             'completed': 0, 'blocked': 0, 'b_waiting': 0, 'skipped': 0,
             'removed_observed': 0, 'removed_while_waiting': 0, 'blocked_histories': 0,
             'boundary': 0, 'domain': 0}
    cov = {}                 # S5-concurrent coverage: what the histories exercised
    worst = None
    worst_blocked = None     # the minimal failing history in which a remove was blocked by A
    for bd in bodies:
        res = run_history(proto, cap, a, b, subj, opr, val, prologue, [alphabet[i] for i in bd], stats, cov)
        if res and (worst is None or res[0] < worst[0]):
            worst = res
        if res and res[2] and (worst_blocked is None or res[0] < worst_blocked[0]):
            worst_blocked = res
    # compared output: verdicts and the required coverage classes; counts,
    # BOUNDARY/DOMAIN numbers and counterexamples depend on what the server
    # could clean up (scheduling, other sessions' xmin): evidence only
    tag = f"{subj['name']} [{fault}] {gen['contract']}"
    out.append(f"   depth {depth}: {stats['histories']} histories")
    EVIDENCE.append(f"{tag}: BOUNDARY (heap TID reused by an insert) {stats['boundary']}; "
                    f"DOMAIN (removed marked entry returned again) {stats['domain']}")
    if 'coverage' in gen:
        missing = [k for k in gen['coverage'] if not cov.get(k)]
        out.append(f"   coverage: {len(gen['coverage']) - len(missing)} of {len(gen['coverage'])} required classes present"
                   + (": missing " + '; '.join(missing) if missing else ''))
        EVIDENCE.append(f"{tag} coverage (histories): " + '; '.join(f"{k.lstrip('~')}: {cov[k]}" for k in sorted(cov)))
    ev = (f"{subj['name']} [{fault}]: {stats['gets']} amgettuple, cut by obligation/domain {stats['cut']}; "
          f"inserted entries {stats['inserted']}, returned {stats['may']}; remove completed at once {stats['completed']}, "
          f"blocked by A {stats['blocked']} (histories where it waited {stats['blocked_histories']}; B operations not run "
          f"meanwhile {stats['b_waiting']}); steps with removed entries observed {stats['removed_observed']}, "
          f"of them while VACUUM still waited {stats['removed_while_waiting']}; removed entries passed over by A {stats['skipped']}")
    EVIDENCE.append(ev)
    if worst is None:
        out.append("     result: pass")
    else:
        out.append(f"     result: FAIL {gen['contract']}")
        EVIDENCE.append(f"{tag} minimal failing history:\n" + '\n'.join(worst[1]))
        if worst_blocked and worst_blocked is not worst:
            EVIDENCE.append(f"{tag} minimal failing history in which the remove was blocked by A:\n"
                            + '\n'.join(worst_blocked[1][1:]))
    b.mon.close()
    b.conn.close()
    a.close()
    return out


def run_history(proto, cap, a, b, subj, opr, val, prologue, body, stats, cov):
    sa = a.cursor()
    # fresh data, the reference forward pass, then rows deleted before A begins
    b.run(subj['reset'])
    cnt = b.run(f"SELECT count(*) FROM {subj['table']} WHERE {subj['qual']}")[0][0]
    hist = ['R.ambeginscan', 'R.amrescan:given'] + ['R.amgettuple:forward'] * (cnt + 1)
    ev = b.run(f"SELECT d2_run({engine.lit(subj['index'])}, {engine.lit(opr)}, {engine.lit(val)}, false, "
               f"ARRAY[{','.join(map(engine.lit, hist))}])")[0][0]
    L = [e['tid'] for e in ev if e['cb'] == 'amgettuple' and e['ret']]
    deleted = {r[0] for r in b.run(subj['delete'])}
    b.was_blocked = False
    chk = Checker(proto, cap, L, deleted)

    lines = ['     history (state before -> observed -> state after):']
    sa.execute("SET statement_timeout = '60s'")
    sa.execute("BEGIN")
    sa.execute("SELECT d2_open(%s, %s, %s, %s)", (subj['index'], opr, val, bool(subj.get('index_only'))))
    fail = None
    steps = 0
    nins = 0
    removal = {'began': False, 'final': False}
    boundary = None

    def refresh_removed():
        """After a remove started: wait until B has completed or waits for
        another backend, then classify by what the index holds now."""
        if not removal['began'] or removal['final']:
            return
        b.settle()
        gone = deleted - b.present(subj['index'], opr, val, len(L) + len(chk.inserted))
        chk.set_removed(gone)
        if gone:
            stats['removed_observed'] += 1
            if b.running:
                stats['removed_while_waiting'] += 1
        if not b.running:
            removal['final'] = True

    def a_step(name, arg):
        sa.execute("SELECT d2_step(%s)", (f"A.{proto.ops[name]['callback']}" + (':' + list(arg.values())[0] if arg else ''),))
        return sa.fetchone()[0]

    track = any(n == 'mark' for _, n, _, _ in body)     # S5-concurrent coverage
    phase = 'unmarked'
    seen = set()
    leaf = b.leaves(subj['index'], opr, val, len(L)) if track else {}

    def mark_rel(entries):
        """Where entries lie relative to the marked position, in the order
        of a fresh forward scan (coverage only)."""
        m = chk.state.mark
        rel = set()
        for e in entries:
            i = L.index(e)
            rel.add('before the mark' if i < m or (i == m and chk.mark_gap) else 'the marked entry' if i == m
                    else 'right after the mark' if i == m + 1 else 'later')
        return rel

    for actor, name, arg, times in prologue:
        if 'expect' in proto.ops[name]:
            body = [(actor, name, arg, times)] + list(body)
            continue
        chk.state = proto.step(chk.state, name, arg, None, None)[2]
        a_step(name, arg)
        lines.append(f"       A.{engine.show('A', name, arg, False)}")
    for actor, name, arg, times in body:
        if actor == 'A':
            for _ in range(times):           # A.op*k: k operations, each checked
                if chk.admit(name, arg) != 'ok':
                    stats['cut'] += 1        # outside obligation/domain: not run
                    continue
                before = engine.brief(chk.state) + (' gap' if chk.gap else '')
                if 'expect' not in proto.ops[name]:
                    a_step(name, arg)        # mark, restore: no outcome of their own
                    chk.apply(name, arg)
                    lines.append(f"       A.{engine.show('A', name, arg, False):<16} [{before}]"
                                 f"  [{engine.brief(chk.state) + (' gap' if chk.gap else '')}]")
                    if name == 'mark':
                        phase = 'marked'
                        seen.add('mark run, marked entry ' + ('inserted (gap)' if chk.mark_gap else
                                 'deleted before A' if chk.mark_entry in deleted else 'stable'))
                    elif name == 'restore' and phase == 'marked':
                        phase = 'restored'
                        seen.add('restore run')
                        if chk.mark_entry in chk.optional:
                            seen.add('~marked entry observed removed at restore')
                        for rel in mark_rel(chk.optional):
                            seen.add('~removed at restore: ' + rel)
                    continue
                res = a_step(name, arg)
                o = res[0]
                if track and res[-1].get('buffers') and phase in ('marked', 'restored'):
                    seen.add(f"~A read an index page after {'mark, before restore' if phase == 'marked' else 'restore'}")
                mleaf = leaf.get(L[chk.state.mark]) if track and phase != 'unmarked' and \
                    chk.state.mark is not None and 0 <= chk.state.mark < len(L) else None
                if o.get('ret') and o['tid'] in leaf and mleaf is not None and leaf[o['tid']] != mleaf:
                    seen.add(f"entry of another leaf than the marked one returned after "
                             f"{'mark, before restore' if phase == 'marked' else 'restore'}")
                refresh_removed()            # what was removed by the end of this step
                stats['gets'] += 1
                steps += 1
                got = o['tid'] if o.get('ret') else 'false'
                if o.get('ret') and o['tid'] in chk.inserted:
                    stats['may'] += 1
                    if phase == 'restored':
                        seen.add('inserted entry returned after restore')
                fail = chk.observe(name, arg, o)
                tag = ' (inserted)' if o.get('ret') and o['tid'] in chk.inserted else \
                      ' (deleted)' if o.get('ret') and o['tid'] in deleted else ''
                if chk.domain:
                    lines.append(f"       A.{engine.show('A', name, arg, False):<16} [{before}] -> {got}{tag}  DOMAIN: {chk.domain}")
                    break
                lines.append(f"       A.{engine.show('A', name, arg, False):<16} [{before}] -> {got}{tag}"
                             f"  [{engine.brief(chk.state) + (' gap' if chk.gap else '') if not fail else ''}]")
                if phase == 'restored' and not fail:
                    seen.add('outcome checked after restore')
                if fail:
                    break
            if fail or chk.domain:
                break
            continue
        if b.running:
            # B is one session: while it waits for A, it cannot act
            lines.append(f"       B.{name} (not run: B still waits for A)")
            stats['b_waiting'] += 1
            continue
        if phase == 'marked':
            seen.add(f"B.{name} between mark and restore")
        if name == 'insert':
            nins += 1
            rows = b.run(subj['insert'].replace('{n}', str(nins)))
            reused = tid_reuse(L, [r[0] for r in rows])
            if reused:
                boundary = f"heap TID reused by an insert ({len(reused)}: {', '.join(sorted(reused, key=engine.tid_key))}); the observer identifies entries by TID"
                lines.append(f"       B.insert -> BOUNDARY: {boundary}")
                break
            new = {r[0] for r in rows if r[1]}
            chk.inserted |= new
            stats['inserted'] += len(new)
            lines.append(f"       B.insert -> {len(new)} entries")
            if phase == 'marked' and new:
                order = b.contents(subj['index'], opr, val, len(L) + len(chk.inserted))
                m = chk.state.mark
                anchor = L[m] if 0 <= m < len(L) else None
                if anchor in order:
                    for e in new & set(order):
                        seen.add('insert between mark and restore: entry '
                                 + ('before' if order.index(e) < order.index(anchor) else 'after') + ' the mark')
        else:
            if phase == 'marked':
                for rel in mark_rel(deleted):
                    seen.add('remove between mark and restore, deleted entry ' + rel)
            state, ev_ = b.start(subj['remove'])
            removal['began'] = True
            refresh_removed()
            stats[state] += 1
            lines.append(f"       B.remove -> {state}" + (f" ({ev_})" if ev_ else "")
                         + f"; removed from the index so far: {len(chk.optional)} of {len(deleted)}")
    sa.execute("SELECT d2_close()")
    sa.execute("COMMIT")
    blocked = b.was_blocked
    if blocked:
        stats['blocked_histories'] += 1
    if boundary:
        stats['boundary'] += 1
        return None
    if phase == 'restored':
        bmr = any(k.startswith('B.') and k.endswith('between mark and restore') for k in seen)
        if bmr and 'outcome checked after restore' in seen:
            seen.add('B between mark and restore, then an outcome checked after restore')
        if bmr and 'entry of another leaf than the marked one returned after restore' in seen:
            seen.add('B between mark and restore, then an entry of another leaf returned after restore')
        if '~marked entry observed removed at restore' in seen and 'outcome checked after restore' in seen:
            seen.add('~marked entry observed removed at restore, then an outcome checked')
        for k in seen:
            cov[k] = cov.get(k, 0) + 1
    if chk.domain:
        stats['domain'] += 1
        b.finish()
        return None
    b.finish()
    stats['skipped'] += len(chk.skipped)
    if fail:
        lines.append(f"     reference: {len(L)} entries; deleted before A: {len(deleted)}"
                     f"{'; observed removed: ' + str(len(chk.optional)) if removal['began'] else ''}; inserted: {len(chk.inserted)}")
        lines.append(f"     {fail}")
        return (steps, lines, blocked)
    return None


def run_executor_subject(cspec, subj, fault, profile):
    """V5: A2 is the executor's scan of the index (a cursor), B acts between
    its FETCHes; the outcome is compared with the same query by a
    sequential scan under A2's snapshot (concurrencyspec 'executor')."""
    gen = cspec['generation'][profile]
    a = connect()
    a.autocommit = True
    b = B()
    sa = a.cursor()
    q = subj['query']

    def settings(extra=None):
        for k, v in dict(subj.get('settings', {}), **(extra or {})).items():
            sa.execute(f"SET LOCAL {k} TO {engine.lit(str(v))}")

    # base: nothing deleted, nothing concurrent
    for stmt in subj['reset']:
        b.run(stmt)
    sa.execute("BEGIN ISOLATION LEVEL REPEATABLE READ")
    settings()
    sa.execute("EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) " + q)
    plan = [r[0] for r in sa.fetchall()]
    sa.execute("COMMIT")
    hf = [l.split(':')[1].strip() for l in plan if 'Heap Fetches:' in l]
    out = [f"== {subj['name']}"]
    tag = f"{subj['name']} [{fault}]"
    if hf:
        EVIDENCE.append(f"{tag}: heap fetches with nothing deleted: {hf[0]}")

    prologue = [parse_op(i) for i in gen['prologue']]
    epilogue = [parse_op(i) for i in gen['epilogue']]
    alphabet = [parse_op(i) for i in gen['alphabet']]

    def within(bd):
        return all(sum(1 for i in bd if alphabet[i][0] + '.' + alphabet[i][1] == k
                       or alphabet[i][0] == k) <= v for k, v in gen['limits'].items())
    bodies = [bd for bd in itertools.product(range(len(alphabet)), repeat=gen['depth']) if within(bd)]
    stats = {'histories': len(bodies), 'planned': 0, 'reuse': 0, 'fail': 0,
             'completed': 0, 'blocked': 0, 'b_waiting': 0, 'extra': 0, 'missing': 0,
             'extra_not_deleted': 0, 'extra_reused_tid': 0,
             'cleaned': 0, 'fail_cleaned': 0, 'fail_not_cleaned': 0}
    worst = None
    for bd in bodies:
        res = run_executor_history(a, sa, b, subj, fault, settings,
                                   prologue + [alphabet[i] for i in bd] + epilogue, stats)
        if res and (worst is None or res[0] < worst[0]):
            worst = res
    # compared output: invariants only.  A history is eligible when B's
    # remove completed and the index no longer holds the deleted rows'
    # entries (observed by a fresh scan): whether that happens depends on
    # other sessions' xmin, so how many there were is evidence.
    out.append(f"   {stats['histories']} histories; planned as {subj['plan']}: "
               f"{'every history' if stats['planned'] == stats['histories'] else 'NOT every history'}; "
               f"histories with an observed cleanup: {'yes' if stats['cleaned'] else 'none'}")
    if worst is None:
        verdict = "pass"
        out.append("     result: pass")
    else:
        verdict = "FAIL"
        out.append(f"     result: FAIL: {gen['contract']}; every history with an observed cleanup fails: "
                   f"{'yes' if stats['fail_cleaned'] == stats['cleaned'] else 'no'}; failures without one: "
                   f"{'yes' if stats['fail_not_cleaned'] else 'none'}")
        EVIDENCE.append(f"{tag} minimal failing history:\n" + '\n'.join(worst[1]))
    if subj.get('known_violation'):
        out[1:] = [f"   known violation ({subj['known_violation']}): "
                   + ("reproduced" if verdict == "FAIL" and stats['fail_cleaned']
                      else "NOT reproduced; the expectation may be obsolete")]
    EVIDENCE.append(f"{tag}: {stats['histories']} histories, planned as {subj['plan']} {stats['planned']}, "
                    f"with an observed cleanup {stats['cleaned']}, failing {stats['fail']} "
                    f"(with cleanup {stats['fail_cleaned']}, without {stats['fail_not_cleaned']}); an insert "
                    f"reused the heap TID of a deleted row {stats['reuse']}")
    EVIDENCE.append(f"{tag}: remove completed at once {stats['completed']}, blocked by A2 "
                    f"{stats['blocked']} (B operations not run meanwhile {stats['b_waiting']}); rows A2 returned that "
                    f"its snapshot cannot see {stats['extra']} (not rows deleted before A2 began: {stats['extra_not_deleted']}; "
                    f"returned after an insert reused their heap TID: {stats['extra_reused_tid']}), rows missing {stats['missing']}")
    b.mon.close()
    b.conn.close()
    a.close()
    return out


def run_executor_history(a, sa, b, subj, fault, settings, steps, stats):
    q = subj['query']
    for stmt in subj['reset']:
        b.run(stmt)
    deleted = b.run(subj['delete'])
    del_tids = {r[0] for r in deleted}
    del_ids = {r[1] for r in deleted}
    b.was_blocked = False
    sa.execute("BEGIN ISOLATION LEVEL REPEATABLE READ")
    settings()
    sa.execute("SET LOCAL d2_ctl.fault TO %s", (fault,))
    if fault != 'none':
        sa.execute("SELECT d2_ctl_install(%s)", (subj['index'],))
    sa.execute("EXPLAIN (COSTS OFF) " + q)
    if any(subj['plan'] in r[0] for r in sa.fetchall()):
        stats['planned'] += 1
    sa.execute("DECLARE a2 NO SCROLL CURSOR FOR " + q)
    rows = []
    lines = ['     history:']
    nins = 0
    reused_any = False
    reused_ids = set()
    cleaned = False
    returned_after_reuse = []          # rows A2 returned after some insert reused a TID
    id_of = {r[0]: r[1] for r in deleted}
    for actor, name, arg, _ in steps:
        if actor == 'A2':
            sa.execute(f"FETCH {'ALL' if arg == 'all' else int(arg)} FROM a2")
            got = sa.fetchall()
            rows += got
            if reused_ids:
                returned_after_reuse += got
            lines.append(f"       A2.fetch({arg}) -> {len(got)} rows")
            continue
        if b.running:
            lines.append(f"       B.{name} (not run: B still waits for A2)")
            stats['b_waiting'] += 1
            continue
        if name == 'remove':
            state, ev_ = b.start(subj['remove'])
            stats[state] += 1
            if state == 'completed':
                left = b.present(subj['index'], subj['opr'], subj['val'],
                                 b.run(f"SELECT count(*) FROM {subj['table']}")[0][0] + len(del_tids)) & del_tids
                cleaned |= not left
                lines.append(f"       (deleted rows' entries left in the index: {len(left)})")
            lines.append(f"       B.remove -> {state}" + (f" ({ev_})" if ev_ else ""))
        else:
            nins += 1
            new = b.run(subj['insert'].replace('{n}', str(nins)))
            reused = {r[0] for r in new} & del_tids
            reused_any |= bool(reused)
            reused_ids |= {id_of[t] for t in reused}
            lines.append(f"       B.insert -> {len(new)} rows; heap TIDs of deleted rows reused: {len(reused)}")
    sa.execute("CLOSE a2")
    settings({'enable_seqscan': 'on', 'enable_indexscan': 'off', 'enable_indexonlyscan': 'off',
              'enable_bitmapscan': 'off'})
    sa.execute(q)
    ref = sa.fetchall()
    sa.execute("COMMIT")
    b.finish()
    stats['reuse'] += reused_any
    stats['cleaned'] += cleaned
    if subj.get('ordered'):
        same = rows == ref
    else:
        same = sorted(map(repr, rows)) == sorted(map(repr, ref))
    if same:
        return None
    stats['fail'] += 1
    stats['fail_cleaned' if cleaned else 'fail_not_cleaned'] += 1
    from collections import Counter
    extra = Counter(rows) - Counter(ref)
    missing = Counter(ref) - Counter(rows)
    stats['extra'] += sum(extra.values())
    stats['missing'] += sum(missing.values())
    ids = sorted(r[subj['id_column']] for r in extra)
    stats['extra_not_deleted'] += sum(1 for i in ids if i not in del_ids)
    late = {r[subj['id_column']] for r in returned_after_reuse}
    stats['extra_reused_tid'] += sum(1 for i in ids if i in reused_ids and i in late)
    lines.append(f"     reference: {len(ref)} rows; A2 returned {len(rows)}")
    if extra:
        lines.append(f"     {sum(extra.values())} rows A2's snapshot cannot see, "
                     f"{sum(1 for i in ids if i in del_ids)} of them deleted before A2 began (ids {', '.join(map(str, ids[:5]))}"
                     + (', ...' if len(ids) > 5 else '') + ")")
    if missing:
        lines.append(f"     {sum(missing.values())} rows of the reference missing")
    if not extra and not missing:
        first = next(i for i, (x, y) in enumerate(zip(rows, ref)) if x != y)
        lines.append(f"     same rows, order differs from row {first}")
    return (len(steps), lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('protocolspec')
    ap.add_argument('concurrencyspec')
    ap.add_argument('subjects', nargs='?')
    ap.add_argument('--fault', default='none')
    ap.add_argument('--depth', type=int)
    ap.add_argument('--only')
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--profile', default='s6', help='generation profile of the concurrencyspec')
    ap.add_argument('--evidence', help='append scheduling-dependent counts to this file')
    o = ap.parse_args()
    pspec = yaml.safe_load(open(o.protocolspec))['protocols']['index_scan']
    cspec = yaml.safe_load(open(o.concurrencyspec))
    assert cspec['version'] == 'concurrencyspec-v0'
    if o.selftest:
        print('\n'.join(selftest(pspec, o.profile)))
        return
    print(f"fault: {o.fault}")
    for subj in yaml.safe_load(open(o.subjects)):
        if o.only and subj['name'] != o.only:
            continue
        if 'A2' in ' '.join(cspec['generation'][o.profile]['prologue']):
            res = run_executor_subject(cspec, subj, o.fault, o.profile)
            print('\n'.join(res))
            continue
        print('\n'.join(run_subject(pspec, cspec, subj, o.fault, o.depth or subj['depth'], o.profile)))
    if o.evidence:
        with open(o.evidence, 'a') as fh:
            fh.write('\n'.join(EVIDENCE) + '\n')


if __name__ == '__main__':
    main()
