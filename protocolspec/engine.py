#!/usr/bin/env python3
"""D2 engine: protocolspec -> state machine -> bounded histories -> real
Index AM callbacks (through the d2proto observer) -> conformance result.

Knows the spec format and the d2proto SQL functions; knows no AM and no
contract: operations, obligations, expectations, effects, observables and
guards all come from the spec.

usage: engine.py SPEC SUBJECTS [--fault NAME] [--depth N]
SUBJECTS (yaml): list of {name, index, opr, val, index_only, profiles:
{profile: depth}, executor: [sql, ...]}; the database is the psql default.
"""
import argparse
import itertools
import json
import subprocess
import sys

import yaml

PSQL = ['psql', '-X', '-At', '-q', '-v', 'ON_ERROR_STOP=1']


class NS(dict):
    __getattr__ = dict.get


class Unknown:
    """A model value the observation cannot give (no reference when checking
    executor traffic); distinct from None."""
    def __repr__(self):
        return '?'


UNKNOWN = Unknown()
BUILTINS = {'None': None, 'True': True, 'False': False, 'len': len}


def ev(expr, env):
    return eval(str(expr), {'__builtins__': BUILTINS}, env)


def lit(v):
    return "'" + str(v).replace("'", "''") + "'"


def sql_rows(script):
    out = subprocess.run(PSQL, input=script, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit('psql failed:\n' + out.stderr)
    return [l for l in out.stdout.split('\n') if l]


class Protocol:
    def __init__(self, spec, cap):
        self.p = spec
        self.cap = NS(cap)
        self.ops = {}
        for name, op in spec['operations'].items():
            if any(not cap.get(r) for r in op.get('requires', [])):
                continue        # callback absent in this AM: operation n/a
            self.ops[name] = op
        self.cb_to_op = {op['callback']: name for name, op in self.ops.items()}
        self.obs = spec['observables']

    def instances(self, opname):
        args = self.ops[opname].get('args', {})
        keys = list(args)
        for vals in itertools.product(*(args[k] for k in keys)):
            yield opname, dict(zip(keys, vals))

    def initial(self):
        return NS(self.p['state'])

    def step(self, s, opname, arg, L, n, observed=None):
        """Apply one operation to scan state s.  Returns (status, expect,
        new state, ok); status: 'ok', 'outside' (obligation met, outside the
        domain), 'violation' (obligation not met).  With observed (replay),
        ok comes from it."""
        op = self.ops[opname]
        env = {'s': s, 'arg': NS(arg), 'cap': self.cap, 'L': L, 'n': n}
        if not ev(op.get('obligation', 'True'), env):
            return 'violation', None, s, None
        status = 'ok' if ev(op.get('domain', 'True'), env) else 'outside'
        for k, e in op.get('let', {}).items():
            try:
                env[k] = ev(e, env)
            except TypeError:
                env[k] = UNKNOWN
        expect = {}
        if observed is None:
            for k, e in op.get('expect', {}).items():
                expect[k] = ev(e, env)
            ok = expect.get('ret')
        else:
            ok = observed.get('ret')
        env['ok'] = ok
        new = NS(s)
        for k, e in op.get('effect', {}).items():
            try:
                new[k] = ev(e, env)
            except TypeError:
                new[k] = UNKNOWN
        return status, expect, new, ok


def parse_item(item):
    scan, rest = item.split('.', 1)
    if '(' in rest:
        name, a = rest[:-1].split('(')
        return scan, name, a
    return scan, rest, None


def generate(proto, profile, depth, L, n):
    """Bounded enumeration.  Yields maximal histories: (steps, expects),
    steps = [(scan, opname, arg)], one expectation dict per step."""
    prologue = []
    for item in profile['prologue']:
        scan, name, a = parse_item(item)
        arg = {}
        if a is not None:
            arg = {list(proto.ops[name]['args'])[0]: a}
        prologue.append((scan, name, arg))
    alphabet = []
    for item in profile['alphabet']:
        scan, name, _ = parse_item(item)
        if name in proto.ops:
            alphabet += [(scan, n_, a) for n_, a in proto.instances(name)]
    states = {sc: proto.initial() for sc in profile['scans']}
    exp = []
    for scan, name, arg in prologue:
        st_, e, states[scan], _ = proto.step(states[scan], name, arg, L, n)
        assert st_ == 'ok', f'prologue step {name} not allowed'
        exp.append(e)

    def rec(steps, exps, states):
        extended = False
        if len(steps) < depth:
            for scan, name, arg in alphabet:
                st_, e, ns, _ = proto.step(states[scan], name, arg, L, n)
                if st_ != 'ok':
                    continue
                extended = True
                st = dict(states)
                st[scan] = ns
                yield from rec(steps + [(scan, name, arg)], exps + [e], st)
        if not extended and steps:
            yield steps, exps, states

    for body, exps, st in rec([], [], states):
        tail = [(sc, 'end', {}) for sc in profile['scans'] if st[sc].phase != 'none']
        yield prologue + body + tail, exp + exps + [{} for _ in tail]


def step_text(proto, scan, name, arg):
    cb = proto.ops[name]['callback']
    a = ':' + list(arg.values())[0] if arg else ''
    return f'{scan}.{cb}{a}'


def show(scan, name, arg, multi):
    a = '(' + ', '.join(arg.values()) + ')' if arg else ''
    return (f'{scan}.' if multi else '') + name + a


def check_history(proto, steps, exps, events):
    """Compare events with expectations; returns None or (index, what, expected, observed)."""
    outstanding = {}
    obs = proto.obs['returned_data']
    for i, ((scan, name, arg), e) in enumerate(zip(steps, exps)):
        if i >= len(events):
            return i, 'missing', 'an event', 'none'
        o = events[i]
        cb = proto.ops[name]['callback']
        if o.get('refused'):
            return i, 'guard', 'call forwarded', 'refused: ' + o['refused']
        if cb in obs['lifetime_ends'] and outstanding.pop(scan, False):
            if o.get('life') != 'ok':
                return i, obs['contract'], 'returned data unchanged', 'returned data ' + str(o.get('life'))
        for k, v in e.items():
            if o.get(k) != v:
                return i, k, v, o.get(k)
        if cb == obs['produced_by'] and o.get('ret'):
            if proto.cap.amcanreturn and o.get('data') is None and want_data:
                return i, obs['contract'], 'returned data', 'none'
            if o.get('data'):
                outstanding[scan] = True
    return None


def contracts_of(proto, steps, i, what):
    if what == 'guard':
        return [proto.ops[steps[i][1]].get('contract')]
    if what == proto.obs['returned_data']['contract']:
        return [what]
    # the contract of the operation that set the position the failing one
    # started from, when that was not the same kind of operation
    tags = {proto.ops[steps[i][1]].get('contract')}
    for _, n, _ in reversed(steps[:i]):
        op = proto.ops[n]
        if 'pos' in op.get('effect', {}):
            if op['callback'] != proto.ops[steps[i][1]]['callback'] and op['effect']['pos'] != 'None':
                tags = {op.get('contract')}
            break
    return sorted(t for t in tags if t)


want_data = False


def run_subject(spec, subj, fault, depth_override):
    global want_data
    want_data = subj.get('index_only', False)
    idx = subj['index']
    opr = 'NULL' if subj.get('opr') is None else lit(subj['opr'])
    val = 'NULL' if subj.get('val') is None else lit(subj['val'])
    io = 'true' if want_data else 'false'
    obs = spec['observables']['returned_data']
    guards = [g for op in spec['operations'].values() for g in op.get('guard', [])]
    setup = (f"SET d2_ctl.fault = {lit(fault)};\n"
             f"SELECT d2_configure(ARRAY[{','.join(map(lit, obs['lifetime_ends']))}]::text[], "
             f"ARRAY[{','.join(map(lit, guards))}]::text[]);\n")
    cap = json.loads(sql_rows(setup + f"SELECT d2_caps({lit(idx)});")[-1])
    # the reference comes from the AM without control layers
    refsetup = setup.replace(f"SET d2_ctl.fault = {lit(fault)};", "SET d2_ctl.fault = 'none';")
    out = [f"== {subj['name']}  caps: " + ' '.join(k for k, v in sorted(cap.items()) if v)]
    missing = [r for r in spec.get('requires', []) if not cap.get(r)]
    if missing:
        return out + [f'   n/a: {missing}'], 0
    proto = Protocol(spec, cap)

    # reference: a forward pass, checked against the seqscan
    info = sql_rows(f"""SELECT c.relname, a.attname FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0] WHERE i.indexrelid = {lit(idx)}::regclass;""")[0]
    tbl, col = info.split('|')
    qual = 'true'
    if subj.get('opr'):
        rt = sql_rows(f"SELECT oprright::regtype FROM pg_operator WHERE oid = {lit(subj['opr'])}::regoperator;")[0]
        qual = f"{col} OPERATOR(pg_catalog.{subj['opr'].split('(')[0]}) {val}::{rt}"
    refset = sql_rows(f"SET enable_indexscan = off; SET enable_bitmapscan = off; SET enable_indexonlyscan = off;"
                      f"SELECT count(*), coalesce(string_agg(ctid::text, ' ' ORDER BY ctid), '') FROM {tbl} WHERE {qual};")[-1]
    cnt, tids = refset.split('|')
    cnt = int(cnt)
    hist = ['A.ambeginscan', 'A.amrescan:given'] + ['A.amgettuple:forward'] * (cnt + 1)
    ev_ = json.loads(sql_rows(refsetup + f"SELECT d2_run({lit(idx)}, {opr}, {val}, {io}, ARRAY[{','.join(map(lit, hist))}]);")[-1])
    gets = [e for e in ev_ if e['cb'] == 'amgettuple']
    L = [e['tid'] for e in gets if e['ret']]
    n = len(L)
    refok = (n == cnt and not gets[-1]['ret'] and ' '.join(sorted(L, key=tid_key)) == tids)
    order = ''
    if cap.get('amcanorder') and n:
        same = sql_rows(f"""SELECT array(SELECT {col}::text FROM unnest(ARRAY[{','.join(map(lit, L))}]::tid[]) WITH ORDINALITY u(t, o)
                 JOIN {tbl} ON ctid = u.t ORDER BY o) = array(SELECT {col}::text FROM {tbl} WHERE {qual} ORDER BY {col});""")[-1]
        order = '; value order ' + ('same' if same == 't' else 'DIFFERS')
    out.append(f"   reference: n={n}; seqscan set {'same' if refok else 'DIFFERS'}{order}")
    if not refok:
        return out, 1

    fails = 0
    for pname, depth in subj['profiles'].items():
        profile = spec['generation'][pname]
        depth = depth_override or depth
        hs = list(generate(proto, profile, depth, L, n))
        script = setup + ''.join(
            f"SELECT '{i}|' || d2_run({lit(idx)}, {opr}, {val}, {io}, ARRAY[{','.join(lit(step_text(proto, *st)) for st in steps)}]::text[]);\n"
            for i, (steps, _) in enumerate(hs))
        res = {}
        for line in sql_rows(script):
            i, j = line.split('|', 1)
            res[int(i)] = json.loads(j)
        worst = {}              # per failing contract set: shortest failing prefix
        nsteps = 0
        for i, (steps, exps) in enumerate(hs):
            nsteps += len(steps)
            r = check_history(proto, steps, exps, res[i])
            if r:
                key = ','.join(contracts_of(proto, steps, r[0], r[1]))
                if key not in worst or (r[0], i) < (worst[key][1][0], worst[key][0]):
                    worst[key] = (i, r)
        used = {}
        for steps, _ in hs:
            for _, name, arg in steps:
                k = name + ('(' + ','.join(arg.values()) + ')' if arg else '')
                used[k] = used.get(k, 0) + 1
        out.append(f"   {pname} depth {depth}: {len(hs)} histories, {nsteps} callbacks")
        out.append("     " + ' '.join(f'{k}={v}' for k, v in sorted(used.items())))
        line = "     result: "
        if not worst:
            out.append(line + 'pass')
            continue
        fails += 1
        out.append(line + 'FAIL ' + ' '.join(sorted(worst)))
        for key in sorted(worst):
            i, (k, what, exp, got) = worst[key]
            steps, exps = hs[i]
            out.append(f"     {key}: minimal history (state before -> observed -> state after):")
            out += minimal(proto, profile, steps[:k + 1], exps[:k + 1], res[i][:k + 1], L, n, what, exp, got)
    for q in subj.get('executor', []):
        out += replay(proto, idx, setup, q)
    return out, fails


def tid_key(t):
    b, o = t.strip('()').split(',')
    return int(b), int(o)


def minimal(proto, profile, steps, exps, events, L, n, what, exp, got):
    multi = len(profile['scans']) > 1
    states = {sc: proto.initial() for sc in profile['scans']}
    lines = []
    for (scan, name, arg), o in zip(steps, events):
        before = brief(states[scan])
        _, _, states[scan], _ = proto.step(states[scan], name, arg, L, n)
        res = ''
        if 'ret' in o:
            res = ' -> ' + (o['tid'] if o['ret'] else 'false')
        lines.append(f"       {show(scan, name, arg, multi):<22} [{before}]{res}  [{brief(states[scan])}]")
    if what in exps[-1]:
        e, o = exps[-1], events[-1]
        exp = ' '.join(f'{k}={e[k]}' for k in e)
        got = ' '.join(f'{k}={o.get(k)}' for k in e)
    lines.append(f"     expected: {exp}")
    lines.append(f"     observed: {got}")
    return lines


def brief(s):
    return ' '.join(f'{k}={v}' for k, v in s.items() if k in ('phase', 'pos', 'mark') and v is not None)


def replay(proto, idx, setup, q):
    """Executor traffic: obligations (caller side), domains and observables."""
    try:
        call = (f"SELECT d2_observe_cursor({lit(idx)}, {lit(q['sql'])}, ARRAY[{','.join(map(lit, q['fetch']))}]::text[]);"
                if 'fetch' in q else f"SELECT d2_observe({lit(idx)}, {lit(q['sql'])});")
        events = json.loads(sql_rows(setup + q['setup'] + call)[-1])
    except SystemExit as e:
        err = [l for l in str(e).splitlines() if l.startswith('ERROR:')]
        return [f"   executor {q['name']}: {err[0] if err else 'psql failed'}"]
    states = {}
    outstanding = {}
    since = {}                  # callbacks on each scan since its last returned data
    obs = proto.obs['returned_data']
    counts = {}
    outside = {}
    for e in events:
        scan = e['scan']
        name = proto.cb_to_op[e['cb']]
        counts[name] = counts.get(name, 0) + 1
        arg = {}
        if 'dir' in e:
            arg = {'direction': e['dir']}
        elif e['cb'] == 'amrescan':
            arg = {'keys': 'nullkeys' if e.get('keys') is None else 'given'}
        s = states.get(scan, proto.initial())
        since.setdefault(scan, []).append(e['cb'])
        if e['cb'] in obs['lifetime_ends'] and outstanding.pop(scan, False) and e.get('life') != 'ok':
            return [f"   executor {q['name']}: FAIL {obs['contract']}: returned data {e.get('life')} on scan {scan}",
                    "     " + ' -> '.join(since[scan])]
        status, _, s, _ = proto.step(s, name, arg, None, None, observed=e)
        if status == 'violation':
            return [f"   executor {q['name']}: FAIL obligation of {name}({', '.join(arg.values())}) on scan {scan}"]
        if status == 'outside':
            outside[name] = outside.get(name, 0) + 1
        states[scan] = s
        if e.get('data'):
            outstanding[scan] = True
            since[scan] = [e['cb'] + '(' + e['dir'] + ') = ' + e['tid']]
    summary = ' '.join(f'{k}={v}' for k, v in sorted(counts.items()))
    lines = [f"   executor {q['name']}: pass ({summary})"]
    if outside:
        lines.append("     outside domain (not asserted): " + ' '.join(f'{k}={v}' for k, v in sorted(outside.items())))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('spec')
    ap.add_argument('subjects')
    ap.add_argument('--fault', default='none')
    ap.add_argument('--depth', type=int)
    ap.add_argument('--only')
    a = ap.parse_args()
    spec = yaml.safe_load(open(a.spec))
    assert spec['version'] == 'protocolspec-v0'
    proto = spec['protocols']['index_scan']
    subjects = yaml.safe_load(open(a.subjects))
    print(f"fault: {a.fault}")
    for subj in subjects:
        if a.only and subj['name'] != a.only:
            continue
        lines, _ = run_subject(proto, subj, a.fault, a.depth)
        print('\n'.join(lines))


if __name__ == '__main__':
    main()
