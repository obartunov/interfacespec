#!/usr/bin/env python3
"""D3 engine (first step, S6): concurrencyspec + protocolspec -> histories in
which a second session acts between callbacks of an open scan -> allowed
outcome sets -> conformance result.

Uses the protocolspec model (engine.Protocol) unchanged.  Knows no AM: the
data each actor uses comes from the subjects file.

usage: d3.py PROTOCOLSPEC CONCURRENCYSPEC SUBJECTS [--fault NAME] [--depth N]
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
        m = self.mon.cursor()
        hist = ['R.ambeginscan', 'R.amrescan:given'] + ['R.amgettuple:forward'] * (n + 1)
        m.execute("SET d2_ctl.fault = 'none'")
        m.execute("SELECT d2_run(%s, %s, %s, false, %s)", (index, opr, val, hist))
        ev = m.fetchone()[0]
        return {e['tid'] for e in ev if e['cb'] == 'amgettuple' and e['ret']}

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

    def observe(self, name, arg, o):
        """Returns None or a failure text; updates the model."""
        fwd = arg.get('direction') == 'forward'
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


def selftest(pspec):
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
            arg = {'direction': d}
            if c.admit('get', arg) != 'ok':
                return 'cut'
            f = c.observe('get', arg, {'ret': got != 'false', 'tid': got if got != 'false' else None})
            if f:
                return 'FAIL'
        return 'pass'
    unordered = {'amcanorder': False, 'amcanbackward': True}
    ordered = {'amcanorder': True, 'amcanbackward': True}
    F, Bk = 'forward', 'backward'
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


EVIDENCE = []        # counts that depend on server scheduling: reported, not compared


def run_subject(pspec, cspec, subj, fault, depth):
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

    gen = cspec['generation']
    alphabet = []
    for item in gen['alphabet']:
        actor, name = item.split('.')
        name, _, times = name.partition('*')
        times = int(times or 1)
        if actor == 'A':
            alphabet += [('A', n, arg, times) for n, arg in proto.instances(name)]
        else:
            alphabet.append(('B', name, {}, 1))
    # bounded enumeration: every body of length depth within the limits
    # (A's obligations/domains are checked on the observed state when the
    # history runs)
    limits = {k.split('.')[1]: v for k, v in gen['limits'].items()}
    bodies = [bd for bd in itertools.product(range(len(alphabet)), repeat=depth)
              if all(sum(1 for i in bd if alphabet[i][0] == 'B' and alphabet[i][1] == k) <= v
                     for k, v in limits.items())]

    opr, val = subj.get('opr'), subj.get('val')
    stats = {'histories': len(bodies), 'cut': 0, 'gets': 0, 'may': 0, 'inserted': 0,
             'completed': 0, 'blocked': 0, 'b_waiting': 0, 'skipped': 0,
             'removed_observed': 0, 'removed_while_waiting': 0, 'blocked_histories': 0,
             'boundary': 0}
    worst = None
    worst_blocked = None     # the minimal failing history in which a remove was blocked by A
    for bd in bodies:
        res = run_history(proto, cap, a, b, subj, opr, val, [alphabet[i] for i in bd], stats)
        if res and (worst is None or res[0] < worst[0]):
            worst = res
        if res and res[2] and (worst_blocked is None or res[0] < worst_blocked[0]):
            worst_blocked = res
    out.append(f"   depth {depth}: {stats['histories']} histories"
               + (f"; BOUNDARY (heap TID reused by an insert): {stats['boundary']}" if stats['boundary'] else ""))
    ev = (f"{subj['name']} [{fault}]: {stats['gets']} amgettuple, cut by obligation/domain {stats['cut']}; "
          f"inserted entries {stats['inserted']}, returned {stats['may']}; remove completed at once {stats['completed']}, "
          f"blocked by A {stats['blocked']} (histories where it waited {stats['blocked_histories']}; B operations not run "
          f"meanwhile {stats['b_waiting']}); steps with removed entries observed {stats['removed_observed']}, "
          f"of them while VACUUM still waited {stats['removed_while_waiting']}; removed entries passed over by A {stats['skipped']}")
    EVIDENCE.append(ev)
    if worst is None:
        out.append("     result: pass")
    else:
        out.append("     result: FAIL S6")
        out += worst[1]
        if worst_blocked and worst_blocked is not worst:
            out.append("     minimal failing history in which the remove was blocked by A:")
            out += worst_blocked[1][1:]
    b.mon.close()
    b.conn.close()
    a.close()
    return out


def run_history(proto, cap, a, b, subj, opr, val, body, stats):
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

    for name, arg in (('begin', {}), ('rescan', {'keys': 'given'})):
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
                o = a_step(name, arg)[0]
                refresh_removed()            # what was removed by the end of this step
                stats['gets'] += 1
                steps += 1
                got = o['tid'] if o.get('ret') else 'false'
                if o.get('ret') and o['tid'] in chk.inserted:
                    stats['may'] += 1
                fail = chk.observe(name, arg, o)
                tag = ' (inserted)' if o.get('ret') and o['tid'] in chk.inserted else \
                      ' (deleted)' if o.get('ret') and o['tid'] in deleted else ''
                lines.append(f"       A.{engine.show('A', name, arg, False):<16} [{before}] -> {got}{tag}"
                             f"  [{engine.brief(chk.state) + (' gap' if chk.gap else '') if not fail else ''}]")
                if fail:
                    break
            if fail:
                break
            continue
        if b.running:
            # B is one session: while it waits for A, it cannot act
            lines.append(f"       B.{name} (not run: B still waits for A)")
            stats['b_waiting'] += 1
            continue
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
        else:
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
    b.finish()
    stats['skipped'] += len(chk.skipped)
    if fail:
        lines.append(f"     reference: {len(L)} entries; deleted before A: {len(deleted)}"
                     f"{'; observed removed: ' + str(len(chk.optional)) if removal['began'] else ''}; inserted: {len(chk.inserted)}")
        lines.append(f"     {fail}")
        return (steps, lines, blocked)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('protocolspec')
    ap.add_argument('concurrencyspec')
    ap.add_argument('subjects', nargs='?')
    ap.add_argument('--fault', default='none')
    ap.add_argument('--depth', type=int)
    ap.add_argument('--only')
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--evidence', help='append scheduling-dependent counts to this file')
    o = ap.parse_args()
    pspec = yaml.safe_load(open(o.protocolspec))['protocols']['index_scan']
    cspec = yaml.safe_load(open(o.concurrencyspec))
    assert cspec['version'] == 'concurrencyspec-v0'
    if o.selftest:
        print('\n'.join(selftest(pspec)))
        return
    print(f"fault: {o.fault}")
    for subj in yaml.safe_load(open(o.subjects)):
        if o.only and subj['name'] != o.only:
            continue
        print('\n'.join(run_subject(pspec, cspec, subj, o.fault, o.depth or subj['depth'])))
    if o.evidence:
        with open(o.evidence, 'a') as fh:
            fh.write('\n'.join(EVIDENCE) + '\n')


if __name__ == '__main__':
    main()
