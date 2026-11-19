"""Hermetic tests for monitoring.watcher: no socket, no sleep, tempfile only."""
import contextlib
import io
import json
import os
import tempfile
import unittest
import urllib.error
from unittest import mock

from monitoring import watcher as w

OWNER = "0x342827c97908e5e2f71151c08502a66d44b6f758e3ac2f1de95f02eb95f0a735"
WITHDRAWER = "0x7ad56d4e6e460ed64deb189a2dba66e30e9feed79fe885f88d5fed470b2d0e8e"
FEE_RATE = "0x959ec4191db1bd972bfbc60dc7d735d4cfb897ca3fd297f4ebd6ee918feb84d4"
KASPLEX, IGRA = 202555, 38833
S1 = w.CHAINS[KASPLEX]["start_block"]
S2 = w.CHAINS[IGRA]["start_block"]
BRIDGE = "0x2f15c748a51438d02347878a2a0f26bc35b5e938"  # Kasplex Bridge on 202555, Zealous on 38833
ZERO = "0x" + "0" * 40
ALICE = "0x" + "a1" * 20
BOB = "0x" + "b2" * 20
SAMPLE = os.path.join(os.path.dirname(os.path.dirname(__file__)), "fixtures", "sample.json")
HOOK = "https://hooks.example.test/secret-token"


def bhash(n, salt=0):
    return "0x%064x" % (n * 31 + 7 + salt)


def topic(addr):
    return "0x" + "0" * 24 + addr[2:].lower()


def mklog(block, address=BRIDGE, t0=OWNER, prev=ZERO, new=ALICE, idx=0, tx=None, **extra):
    log = {
        "address": address,
        "topics": [t0, topic(prev), topic(new)],
        "data": "0x",
        "blockNumber": hex(block),
        "blockHash": bhash(block),
        "transactionHash": tx or "0x%064x" % (block * 1000 + idx),
        "logIndex": hex(idx),
        "removed": False,
    }
    log.update(extra)
    return log


class FakeRPC:
    """Node stand-in: records every call and filters logs by the requested range."""

    def __init__(self, head, logs=(), blocks=None, fail=None, after_logs=None):
        self.head, self.logs, self.blocks, self.fail = head, list(logs), blocks or {}, fail
        self.after_logs = after_logs  # one-shot fn(self): the chain switches after the node answered
        self.calls = []

    def __call__(self, method, params):
        self.calls.append((method, params))
        if self.fail == method:
            raise w.RPCError("injected failure")
        if method == "eth_blockNumber":
            return hex(self.head)
        if method == "eth_getBlockByNumber":
            n = int(params[0], 16)
            return self.blocks[n] if n in self.blocks else {"hash": bhash(n)}
        if method == "eth_getLogs":
            lo, hi = int(params[0]["fromBlock"], 16), int(params[0]["toBlock"], 16)
            result = [l for l in self.logs if lo <= int(l["blockNumber"], 16) <= hi]
            if self.after_logs:
                cb, self.after_logs = self.after_logs, None
                cb(self)
            return result
        raise AssertionError("unexpected method " + method)

    def log_calls(self):
        return [p[0] for m, p in self.calls if m == "eth_getLogs"]


def run(fn, *a, **kw):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rv = fn(*a, **kw)
    return rv, out.getvalue().splitlines(), err.getvalue().splitlines()


def clean_env(**kv):
    env = {k: v for k, v in os.environ.items() if not k.startswith("MONITOR_")}
    env.update(kv)
    return mock.patch.dict(os.environ, env, clear=True)


def envelope(val):
    """Wrap a result in a JSON-RPC envelope; a dict with "__envelope__" is already the full envelope."""
    if isinstance(val, dict) and "__envelope__" in val:
        return {k: v for k, v in val.items() if k != "__envelope__"}
    return {"jsonrpc": "2.0", "id": 1, "result": val}


def logs_params(cid, lo, hi):
    return [{"address": sorted(w.CHAINS[cid]["targets"]), "fromBlock": hex(lo), "toBlock": hex(hi),
             "topics": [[OWNER, WITHDRAWER]]}]


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = self._tmp.name
        self.path = os.path.join(self.dir, "state", "cursors.json")

    def state(self, chains=None):
        return {"version": 1, "chains": {str(k): v for k, v in (chains or {}).items()}}

    def saved(self, cid=KASPLEX):
        with open(self.path) as f:
            return json.load(f)["chains"].get(str(cid))

    def poll(self, rpc, state=None, cid=KASPLEX, confirmations=0, webhook=None, **kw):
        state = state if state is not None else self.state()
        return run(w.poll_chain, cid, rpc, state, self.path, confirmations, webhook, **kw)

    def poll_raises(self, rpc, state):
        """Poll that must raise RPCError; return its stdout and stderr lines."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), self.assertRaises(w.RPCError):
            w.poll_chain(KASPLEX, rpc, state, self.path, 0, None)
        return out.getvalue().splitlines(), err.getvalue().splitlines()


class PollTests(Base):
    def test_matching_log_emits_one_alert(self):
        head = S1 + 10
        log = mklog(S1 + 3, address=BRIDGE.upper().replace("0X", "0x"), t0=OWNER, prev=ALICE, new=BOB, idx=2)
        rpc = FakeRPC(head, [log])
        _, out, err = self.poll(rpc)
        self.assertEqual(len(out), 1, out)
        a = json.loads(out[0])
        self.assertEqual(a["type"], "role_change")
        self.assertEqual(a["chainId"], KASPLEX)
        self.assertEqual(a["contract"], BRIDGE)
        self.assertEqual(a["label"], "Kasplex Bridge")
        self.assertEqual(a["event"], "OwnerSet")
        self.assertEqual(a["previous"], ALICE)
        self.assertEqual(a["new"], BOB)
        self.assertEqual(a["block"], S1 + 3)
        self.assertEqual(a["logIndex"], 2)
        self.assertEqual(a["txHash"], log["transactionHash"])
        self.assertTrue(a["timestamp"].endswith("+00:00"))
        (flt,) = rpc.log_calls()
        self.assertEqual(flt["address"], sorted(w.CHAINS[KASPLEX]["targets"]))
        self.assertEqual(len(flt["address"]), 3)
        self.assertNotIn("0x9d01e8a2f3dd0b1fc739d32ca8d79509b501eab8", flt["address"])
        self.assertEqual(flt["topics"], [[OWNER, WITHDRAWER]])
        self.assertEqual((flt["fromBlock"], flt["toBlock"]), (hex(S1), hex(head)))
        self.assertEqual(self.saved()["block"], head)
        self.assertEqual(self.saved()["seen"], ["%s:2" % log["transactionHash"]])
        self.assertEqual(err, [])

    def test_unrelated_topic_no_alert_cursor_advances(self):
        head = S1 + 10
        rpc = FakeRPC(head, [mklog(S1 + 1, t0=FEE_RATE)])
        _, out, _ = self.poll(rpc)
        self.assertEqual(out, [])
        self.assertEqual(self.saved(), {"block": head, "hash": bhash(head), "seen": []})

    def test_unwatched_address_and_removed_logs_skipped(self):
        rpc = FakeRPC(S1 + 10, [mklog(S1 + 1, address=ALICE), mklog(S1 + 2, removed=True)])
        _, out, _ = self.poll(rpc)
        self.assertEqual(out, [])
        self.assertEqual(self.saved()["block"], S1 + 10)

    def test_reorg_rewinds_and_does_not_reemit(self):
        cur = S1 + 1000
        old = mklog(cur - 5, t0=WITHDRAWER)
        key = "%s:0" % old["transactionHash"]
        st = self.state({KASPLEX: {"block": cur, "hash": bhash(cur, salt=1), "seen": [key]}})
        rpc = FakeRPC(cur + 10, [old])  # node now reports bhash(cur) != stored hash
        _, out, err = self.poll(rpc, st)
        self.assertEqual(rpc.log_calls()[0]["fromBlock"], hex(cur - 11))
        self.assertEqual(out, [])
        self.assertEqual(len(err), 1, err)
        self.assertEqual(json.loads(err[0])["event"], "reorg")
        self.assertEqual(self.saved(), {"block": cur + 10, "hash": bhash(cur + 10), "seen": [key]})

    def test_reorg_block_gone(self):
        cur = S1 + 1000
        st = self.state({KASPLEX: {"block": cur, "hash": bhash(cur), "seen": []}})
        rpc = FakeRPC(cur + 10, blocks={cur: None})
        _, _, err = self.poll(rpc, st)
        self.assertEqual(rpc.log_calls()[0]["fromBlock"], hex(cur - 11))
        self.assertEqual(json.loads(err[0])["event"], "reorg")

    def test_reorg_clamps_at_start_block(self):
        cur = S1 + 3
        st = self.state({KASPLEX: {"block": cur, "hash": bhash(cur, salt=1), "seen": []}})
        rpc = FakeRPC(cur + 10)
        self.poll(rpc, st)
        self.assertEqual(rpc.log_calls()[0]["fromBlock"], hex(S1))

    def test_resume_from_cursor(self):
        cur = S1 + 500
        st = self.state({KASPLEX: {"block": cur, "hash": bhash(cur), "seen": []}})
        rpc = FakeRPC(cur + 7)
        _, _, err = self.poll(rpc, st)
        (flt,) = rpc.log_calls()
        self.assertEqual((flt["fromBlock"], flt["toBlock"]), (hex(cur + 1), hex(cur + 7)))
        self.assertEqual(err, [])

    def test_chunked_ranges(self):
        st = self.state({KASPLEX: {"block": S1 - 1, "hash": None, "seen": []}})
        rpc = FakeRPC(S1 + 24)
        self.poll(rpc, st, chunk=10)
        ranges = [(int(f["fromBlock"], 16), int(f["toBlock"], 16)) for f in rpc.log_calls()]
        self.assertEqual(ranges, [(S1, S1 + 9), (S1 + 10, S1 + 19), (S1 + 20, S1 + 24)])
        self.assertEqual(self.saved()["block"], S1 + 24)

    def test_duplicate_across_chunks_emits_once(self):
        dup = mklog(S1 + 9)
        rpc = FakeRPC(S1 + 24, [dup, dict(dup, blockNumber=hex(S1 + 12))])
        _, out, _ = self.poll(rpc, chunk=10)
        self.assertEqual(len(out), 1)

    def test_confirmations_hold_back_head(self):
        head = S1 + 50
        rpc = FakeRPC(head, [mklog(head - 2)])
        _, out, _ = self.poll(rpc, confirmations=5)
        self.assertEqual(int(rpc.log_calls()[-1]["toBlock"], 16), head - 5)
        self.assertEqual(out, [])
        self.assertEqual(self.saved()["block"], head - 5)

    def test_null_anchor_block_does_not_commit_range(self):
        log = mklog(S1 + 2)
        rpc = FakeRPC(S1 + 10, [log], blocks={S1 + 10: None})
        out, _ = self.poll_raises(rpc, self.state())
        # the null anchor is found before the query: no alert, nothing committed
        self.assertEqual(out, [])
        self.assertFalse(os.path.exists(self.path))

    def reorg_rpc(self, fail=None):
        """logA on the old branch; after the first eth_getLogs the head hash changes and logB replaces it."""
        head = S1 + 10
        log_a, log_b = mklog(S1 + 3, new=ALICE), mklog(S1 + 4, new=BOB)

        def flip(r):
            r.blocks[head] = {"hash": bhash(head, salt=1)}
            r.logs = [log_b]
            r.fail = fail

        return FakeRPC(head, [log_a], after_logs=flip), head, log_b

    def test_reorg_between_anchor_reads_rescans_in_loop(self):
        rpc, head, log_b = self.reorg_rpc()
        _, out, err = self.poll(rpc)
        self.assertEqual(len(out), 1, out)
        a = json.loads(out[0])
        self.assertEqual((a["txHash"], a["new"]), (log_b["transactionHash"], BOB))
        self.assertEqual(len(err), 1, err)
        msg = json.loads(err[0])
        self.assertEqual(msg["event"], "reorg")
        for part in (str(head), bhash(head), bhash(head, salt=1)):
            self.assertIn(part, msg["detail"])
        ranges = [(f["fromBlock"], f["toBlock"]) for f in rpc.log_calls()]
        self.assertEqual(ranges, [(hex(S1), hex(head))] * 2)
        self.assertEqual(self.saved(), {"block": head, "hash": bhash(head, salt=1),
                                        "seen": ["%s:0" % log_b["transactionHash"]]})

    def test_reorg_between_anchor_reads_emits_nothing_until_rescan(self):
        rpc, head, log_b = self.reorg_rpc(fail="eth_getLogs")
        st = self.state()
        out, err = self.poll_raises(rpc, st)
        self.assertEqual(out, [])
        self.assertEqual([json.loads(e)["event"] for e in err], ["reorg"])
        self.assertFalse(os.path.exists(self.path))
        self.assertEqual(st, self.state())
        rpc.fail = None
        _, out, _ = self.poll(rpc, st)
        self.assertEqual(rpc.log_calls()[-1]["fromBlock"], hex(S1))
        self.assertEqual([json.loads(l)["txHash"] for l in out], [log_b["transactionHash"]])
        self.assertEqual(self.saved()["block"], head)

    def test_reorg_during_scan_rechecks_cursor(self):
        cur = S1 + 1000
        st = self.state({KASPLEX: {"block": cur, "hash": bhash(cur), "seen": []}})

        def flip(r):  # the fork point is below the cursor
            r.blocks[cur] = {"hash": bhash(cur, salt=1)}
            r.blocks[cur + 10] = {"hash": bhash(cur + 10, salt=1)}

        rpc = FakeRPC(cur + 10, after_logs=flip)
        _, _, err = self.poll(rpc, st)
        self.assertEqual([f["fromBlock"] for f in rpc.log_calls()], [hex(cur + 1), hex(cur - 11)])
        self.assertEqual([json.loads(e)["event"] for e in err], ["reorg", "reorg"])

    def test_unstable_anchor_gives_up(self):
        head = S1 + 10
        salts = iter(range(1, 100))

        def flap(r):
            r.blocks[head] = {"hash": bhash(head, salt=next(salts))}
            r.after_logs = flap

        rpc = FakeRPC(head, [mklog(S1 + 3)], after_logs=flap)
        out, _ = self.poll_raises(rpc, self.state())
        self.assertEqual(len(rpc.log_calls()), w.REORG_RETRIES + 1)
        self.assertEqual(out, [])
        self.assertFalse(os.path.exists(self.path))


class WebhookTests(Base):
    def test_webhook_one_post_per_alert(self):
        rpc = FakeRPC(S1 + 10, [mklog(S1 + 1), mklog(S1 + 2, t0=WITHDRAWER)])
        with mock.patch.object(w.urllib.request, "urlopen", return_value=io.BytesIO(b"ok")) as uo:
            _, out, _ = self.poll(rpc, webhook=HOOK)
        self.assertEqual(len(out), 2)
        self.assertEqual(uo.call_count, 2)
        for call, line in zip(uo.call_args_list, out):
            req = call.args[0]
            self.assertEqual(req.full_url, HOOK)
            self.assertEqual(req.get_method(), "POST")
            self.assertEqual(req.data, line.encode())
            self.assertEqual(req.get_header("Content-type"), "application/json")

    def test_webhook_unset_no_post(self):
        rpc = FakeRPC(S1 + 10, [mklog(S1 + 1)])
        with mock.patch.object(w.urllib.request, "urlopen") as uo:
            _, out, _ = self.poll(rpc)
        self.assertEqual(len(out), 1)
        uo.assert_not_called()

    def test_webhook_failure_keeps_alert_and_cursor(self):
        rpc = FakeRPC(S1 + 10, [mklog(S1 + 1)])
        with mock.patch.object(w.urllib.request, "urlopen", side_effect=urllib.error.URLError("down")):
            _, out, err = self.poll(rpc, webhook=HOOK)
        self.assertEqual(len(out), 1)
        self.assertEqual(self.saved()["block"], S1 + 10)
        self.assertEqual(len(err), 1)
        msg = json.loads(err[0])
        self.assertEqual((msg["event"], msg["error"]), ("webhook_failed", "URLError"))
        self.assertNotIn("secret-token", err[0])

    def test_webhook_bad_scheme_refused(self):
        with clean_env(MONITOR_WEBHOOK_URL="file:///etc/passwd"), \
                mock.patch.object(w.urllib.request, "urlopen") as uo:
            rc, out, err = run(w.main, ["--once", "--state-file", self.path])
        self.assertEqual(rc, 2)
        uo.assert_not_called()
        self.assertNotIn("passwd", "".join(err))


class TransportTests(Base):
    def test_http_non_json_is_rpc_error(self):
        rpc = w.http_rpc("https://rpc.example.test")
        with mock.patch.object(w.urllib.request, "urlopen", return_value=io.BytesIO(b"<html>")):
            with self.assertRaises(w.RPCError):
                rpc("eth_blockNumber", [])
        with mock.patch.object(w.urllib.request, "urlopen", side_effect=urllib.error.URLError("x")):
            with self.assertRaises(w.RPCError):
                rpc("eth_blockNumber", [])

    def test_strict_quantity(self):
        for bad in ("0x", "1_0", " 0x10", "-0x1", "0x1g", 16, None):
            with self.subTest(bad=bad), self.assertRaises(w.RPCError):
                w._qty(bad)
        self.assertEqual(w._qty("0xFF"), 255)


class MainTests(Base):
    def seed(self, chains):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "w") as f:
            json.dump(self.state(chains), f)
        with open(self.path, "rb") as f:
            return f.read()

    def test_malformed_rpc_once_exits_nonzero(self):
        head = S1 + 10
        good = mklog(S1 + 1)
        lp = logs_params(KASPLEX, S1, head)
        # name: (method, params, bad response, text expected in the stderr detail)
        cases = {
            "error object": ("eth_getLogs", lp, {"__envelope__": 1, "jsonrpc": "2.0", "id": 1, "result": [],
                                                 "error": {"code": -32000, "message": "boom"}}, "boom"),
            "missing result": ("eth_getBlockByNumber", [hex(head), False],
                               {"__envelope__": 1, "jsonrpc": "2.0", "id": 1}, "no result"),
            "wrong result type": ("eth_getLogs", lp, {"not": "a list"}, "not a list"),
            "bad hex blockNumber": ("eth_getLogs", lp, [good, mklog(S1 + 2, blockNumber="0x1g")], "0x1g"),
            "two topics only": ("eth_getLogs", lp, [good, dict(mklog(S1 + 2), topics=[OWNER, topic(ALICE)])],
                                "2 topics"),
            "fixture miss": ("eth_getLogs", lp, None, "fixture miss"),
        }
        for name, (method, params, bad, detail) in cases.items():
            with self.subTest(name):
                before = self.seed({KASPLEX: {"block": S1 - 1, "hash": None, "seen": []},
                                    IGRA: {"block": S2, "hash": None, "seen": []}})
                calls = {
                    (KASPLEX, "eth_blockNumber", "[]"): hex(head),
                    (KASPLEX, "eth_getLogs", json.dumps(logs_params(KASPLEX, S1, head))): [],
                    (KASPLEX, "eth_getBlockByNumber", json.dumps([hex(head), False])): {"hash": bhash(head)},
                    (IGRA, "eth_blockNumber", "[]"): hex(S2),  # nothing to scan on IGRA
                }
                calls[(KASPLEX, method, json.dumps(params))] = bad
                fixture = {"responses": {w._key(c, m, json.loads(p)): envelope(v)
                                         for (c, m, p), v in calls.items() if v is not None}}
                fpath = os.path.join(self.dir, "fx.json")
                with open(fpath, "w") as f:
                    json.dump(fixture, f)
                with clean_env():
                    rc, out, err = run(w.main, ["--once", "--fixture", fpath, "--state-file", self.path])
                self.assertEqual(rc, 1)
                self.assertEqual(out, [])
                self.assertEqual(len(err), 1, err)
                msg = json.loads(err[0])
                self.assertEqual((msg["level"], msg["event"], msg["chainId"]), ("error", "rpc_error", KASPLEX))
                self.assertIn(detail, msg["detail"])
                with open(self.path, "rb") as f:
                    self.assertEqual(f.read(), before)

    def test_confirmations_floor(self):
        fx = ["--fixture", SAMPLE]
        # (argv, env MONITOR_CONFIRMATIONS, confirmations given to poll_chain, config warnings)
        rows = [
            ([], None, 5, 0),
            ([], "0", 5, 1),
            ([], "3", 5, 1),
            ([], "12", 12, 0),
            (["--confirmations", "2"], None, 5, 1),
            (["--confirmations", "9"], "12", 9, 0),
            (fx, None, 0, 0),
            (fx + ["--confirmations", "3"], None, 3, 0),
        ]
        for argv, conf_env, want, warnings in rows:
            with self.subTest(argv=argv, env=conf_env):
                env = {} if conf_env is None else {"MONITOR_CONFIRMATIONS": conf_env}
                with clean_env(**env), mock.patch.object(w, "poll_chain") as pc, mock.patch.object(w, "http_rpc"):
                    rc, _, err = run(w.main, ["--once", "--state-file", self.path] + argv)
                self.assertEqual(rc, 0, err)
                self.assertEqual([c.args[4] for c in pc.call_args_list], [want] * len(w.CHAINS))
                self.assertEqual(sum(json.loads(e)["event"] == "config" for e in err), warnings, err)

    def test_corrupt_state_exits_2(self):
        os.makedirs(os.path.dirname(self.path))
        for body in ("{not json", '{"version": 2, "chains": {}}', '{"version": 1, "chains": {"1": {"block": "x"}}}'):
            with self.subTest(body=body):
                with open(self.path, "w") as f:
                    f.write(body)
                with clean_env(), mock.patch.object(w, "http_rpc") as h:
                    rc, out, err = run(w.main, ["--once", "--state-file", self.path])
                self.assertEqual(rc, 2)
                h.assert_not_called()
                self.assertEqual(json.loads(err[0])["event"], "state_corrupt")

    def test_chains_are_isolated(self):
        k = FakeRPC(S1 + 10 + w.MIN_CONFIRMATIONS, [mklog(S1 + 4)])
        i = FakeRPC(S2 + 10 + w.MIN_CONFIRMATIONS, fail="eth_blockNumber")
        fakes = {w.CHAINS[KASPLEX]["rpc_url"]: k, w.CHAINS[IGRA]["rpc_url"]: i}
        with clean_env(), mock.patch.object(w, "http_rpc", side_effect=lambda url: fakes[url]):
            rc, out, err = run(w.main, ["--once", "--state-file", self.path])
        self.assertEqual(rc, 1)
        self.assertEqual(len(out), 1)
        a = json.loads(out[0])
        self.assertEqual((a["chainId"], a["label"]), (KASPLEX, "Kasplex Bridge"))
        self.assertEqual(self.saved(KASPLEX)["block"], S1 + 10)
        self.assertIsNone(self.saved(IGRA))
        self.assertEqual([json.loads(e)["chainId"] for e in err], [IGRA])

    def _rpc_urls(self, **env):
        """Run one poll and return the URL that main() gave http_rpc for each chain."""
        urls = []

        def fake(url):
            urls.append(url)
            return FakeRPC(S1 + 1 if len(urls) == 1 else S2 + 1)

        with clean_env(**env), mock.patch.object(w, "http_rpc", side_effect=fake):
            rc, _, err = run(w.main, ["--once", "--state-file", self.path])
        self.assertEqual(rc, 0, err)
        return dict(zip(w.CHAINS, urls))

    def test_default_rpc_url_literals(self):
        self.assertEqual(self._rpc_urls(), {KASPLEX: "https://evmrpc.kasplex.org",
                                            IGRA: "https://rpc.igralabs.com:8545"})

    def test_monitor_rpc_env_overrides_endpoint(self):
        self.assertEqual(self._rpc_urls(MONITOR_RPC_202555="https://alt-kasplex.example.test"),
                         {KASPLEX: "https://alt-kasplex.example.test", IGRA: "https://rpc.igralabs.com:8545"})
        self.assertEqual(self._rpc_urls(MONITOR_RPC_38833="https://alt-igra.example.test"),
                         {KASPLEX: "https://evmrpc.kasplex.org", IGRA: "https://alt-igra.example.test"})

    def test_sample_fixture_runs_offline(self):
        with clean_env(MONITOR_WEBHOOK_URL=HOOK), mock.patch.object(w.urllib.request, "urlopen") as uo:
            rc, out, err = run(w.main, ["--once", "--fixture", SAMPLE, "--state-file", self.path])
        self.assertEqual(rc, 0, err)
        uo.assert_not_called()
        alerts = [json.loads(l) for l in out]
        self.assertEqual(len(alerts), 3)
        self.assertTrue(all(a["type"] == "role_change" for a in alerts))
        self.assertEqual(sorted(a["chainId"] for a in alerts), [IGRA, KASPLEX, KASPLEX])
        self.assertEqual(self.saved(KASPLEX)["block"], S1 + 10)
        self.assertEqual(self.saved(IGRA)["block"], S2 + 10)

    def test_fixture_does_not_touch_default_state(self):
        default = os.path.join(self.dir, "default", "cursors.json")
        with clean_env(), mock.patch.object(w, "DEFAULT_STATE", default):
            rc, _, _ = run(w.main, ["--once", "--fixture", SAMPLE])
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(default))

    def test_main_http_end_to_end(self):
        nodes = {w.CHAINS[KASPLEX]["rpc_url"]: FakeRPC(S1 + 10 + w.MIN_CONFIRMATIONS, [mklog(S1 + 1)]),
                 w.CHAINS[IGRA]["rpc_url"]: FakeRPC(S2 + 10 + w.MIN_CONFIRMATIONS, [mklog(S2 + 2, t0=WITHDRAWER)])}
        posts = []

        def urlopen(req, timeout=None):
            self.assertIsNotNone(timeout)
            if req.full_url == HOOK:
                posts.append(req.data)
                return io.BytesIO(b"ok")
            body = json.loads(req.data)
            return io.BytesIO(json.dumps({"jsonrpc": "2.0", "id": body["id"],
                                          "result": nodes[req.full_url](body["method"], body["params"])}).encode())

        with clean_env(MONITOR_WEBHOOK_URL=HOOK, MONITOR_STATE_FILE=self.path), \
                mock.patch.object(w.urllib.request, "urlopen", side_effect=urlopen):
            rc, out, err = run(w.main, ["--once", "--verbose"])
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(out), 2)
        self.assertEqual(posts, [l.encode() for l in out])
        self.assertEqual(sorted(json.loads(e)["event"] for e in err), ["poll_ok", "poll_ok"])
        self.assertEqual(self.saved(IGRA)["block"], S2 + 10)


class StateAndConstantTests(Base):
    def test_state_roundtrip_atomic(self):
        st = self.state({KASPLEX: {"block": 5, "hash": bhash(5), "seen": ["0xab:1"]}})
        w.save_state(self.path, st)
        w.save_state(self.path, st)
        self.assertEqual(w.load_state(self.path), st)
        self.assertEqual(os.listdir(os.path.dirname(self.path)), ["cursors.json"])
        self.assertEqual(w.load_state(os.path.join(self.dir, "missing.json")), {"version": 1, "chains": {}})

    def test_targets_and_topics(self):
        self.assertEqual(w.TOPICS, {OWNER: "OwnerSet", WITHDRAWER: "WithdrawerSet"})
        self.assertEqual(set(w.CHAINS), {KASPLEX, IGRA})
        for cid, cfg in w.CHAINS.items():
            self.assertEqual(len(cfg["targets"]), 3)
            for a in cfg["targets"]:
                self.assertRegex(a, r"^0x[0-9a-f]{40}$")
        shared = {BRIDGE, "0x642638cf9d656378b679de02fabcc5e4e7f1f915"}
        self.assertEqual(set(w.CHAINS[KASPLEX]["targets"]) & set(w.CHAINS[IGRA]["targets"]), shared)
        self.assertIn("0xdfa17269221ce9fdba5bbd28f209a3a23b738978", w.CHAINS[KASPLEX]["targets"])
        self.assertIn("0x9d01e8a2f3dd0b1fc739d32ca8d79509b501eab8", w.CHAINS[IGRA]["targets"])
        orphans = {"0x5e40feb9cfbd572f05ea2ada9bb5935c6aa75368", "0x1e7dba18ca3c7c5fa7c7104a5e5cfe50fd73cc42",
                   "0xad5c913a6cdbfbef88f9f7b4e15ca5fcf75cb295"}
        for cfg in w.CHAINS.values():
            self.assertFalse(orphans & set(cfg["targets"]))
        self.assertEqual((S1, S2), (20977124, 7081263))


if __name__ == "__main__":
    unittest.main()
