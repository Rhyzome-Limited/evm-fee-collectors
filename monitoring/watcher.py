"""Watch the six live FeeCollector contracts for OwnerSet / WithdrawerSet events.

Stdlib only. One JSON line per role change on stdout; JSON diagnostics on stderr.
Run: python3 -m monitoring.watcher [--once] [--backfill] [--fixture PATH]. See docs/monitoring-runbook.md.
"""
import argparse
import http.client
import json
import os
import re
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# keccak256 of the event signatures. Declared in */src/FeeCollector.sol of all four projects:
#   event OwnerSet(address indexed previousOwner, address indexed newOwner);
#   event WithdrawerSet(address indexed previousWithdrawer, address indexed newWithdrawer);
OWNER_SET = "0x342827c97908e5e2f71151c08502a66d44b6f758e3ac2f1de95f02eb95f0a735"
WITHDRAWER_SET = "0x7ad56d4e6e460ed64deb189a2dba66e30e9feed79fe885f88d5fed470b2d0e8e"
TOPICS = {OWNER_SET: "OwnerSet", WITHDRAWER_SET: "WithdrawerSet"}

# start_block = lowest deploy block of the live contracts on that chain (broadcast/**/run-latest.json).
CHAINS = {
    202555: {
        "name": "Kasplex",
        "rpc_url": "https://evmrpc.kasplex.org",
        "start_block": 20977124,
        "targets": {
            "0x2f15c748a51438d02347878a2a0f26bc35b5e938": "Kasplex Bridge",
            "0xdfa17269221ce9fdba5bbd28f209a3a23b738978": "Zealous Swap (Kasplex)",
            "0x642638cf9d656378b679de02fabcc5e4e7f1f915": "KAT KRC-20 Bridge (Kasplex)",
        },
    },
    38833: {
        "name": "IGRA",
        "rpc_url": "https://rpc.igralabs.com:8545",
        "start_block": 7081263,
        "targets": {
            "0x2f15c748a51438d02347878a2a0f26bc35b5e938": "Zealous Swap (IGRA)",
            "0x9d01e8a2f3dd0b1fc739d32ca8d79509b501eab8": "KAT Igra Bridge",
            "0x642638cf9d656378b679de02fabcc5e4e7f1f915": "KAT Igra KRC-20 Bridge",
        },
    },
}

REORG_DEPTH = 12
MIN_CONFIRMATIONS = 5  # default and floor for a live RPC; the range anchor check does not catch every race
REORG_RETRIES = 3  # re-scans of a range with a changing anchor hash before the poll fails
LOG_CHUNK = 2000
SEEN_MAX = 512
HTTP_TIMEOUT = 15
WEBHOOK_TIMEOUT = 5
DEFAULT_STATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".state", "cursors.json")

_HEX = re.compile(r"0x[0-9a-fA-F]+")
_HASH = re.compile(r"0x[0-9a-fA-F]{64}")
_ADDR = re.compile(r"0x[0-9a-fA-F]{40}")
_LOG_KEYS = ("address", "topics", "blockNumber", "blockHash", "transactionHash", "logIndex")


class RPCError(Exception):
    pass


class StateError(Exception):
    pass


def _now():
    return datetime.now(timezone.utc).isoformat()


def _log(level, event, **fields):
    sys.stderr.write(json.dumps(dict(level=level, event=event, ts=_now(), **fields), sort_keys=True) + "\n")
    sys.stderr.flush()


# ─── Validators ──────────────────────────────────────────────────────────────

def _qty(x):
    # Strict: int(x, 16) alone accepts "_", signs and whitespace.
    if not isinstance(x, str) or not _HEX.fullmatch(x):
        raise RPCError("bad quantity: %s" % repr(x)[:80])
    return int(x, 16)


def _hash32(x):
    if not isinstance(x, str) or not _HASH.fullmatch(x):
        raise RPCError("bad hash: %s" % repr(x)[:80])
    return x.lower()


def _topic_addr(x):
    return "0x" + _hash32(x)[-40:]


def _parse_log(log, lo, hi):
    if not isinstance(log, dict) or any(k not in log for k in _LOG_KEYS):
        raise RPCError("malformed log: %s" % repr(log)[:120])
    if not isinstance(log["topics"], list):
        raise RPCError("log topics is not a list")
    topics = [_hash32(t) for t in log["topics"]]
    event = TOPICS.get(topics[0]) if topics else None
    if event and len(topics) != 3:
        raise RPCError("%s log has %d topics, expected 3" % (event, len(topics)))
    if not isinstance(log["address"], str) or not _ADDR.fullmatch(log["address"]):
        raise RPCError("bad log address: %s" % repr(log["address"])[:80])
    block = _qty(log["blockNumber"])
    if not lo <= block <= hi:
        raise RPCError("log block %d outside requested range %d-%d" % (block, lo, hi))
    tx, idx = _hash32(log["transactionHash"]), _qty(log["logIndex"])
    return {
        "contract": log["address"].lower(),
        "event": event,
        "previous": _topic_addr(topics[1]) if event else None,
        "new": _topic_addr(topics[2]) if event else None,
        "block": block,
        "blockHash": _hash32(log["blockHash"]),
        "txHash": tx,
        "logIndex": idx,
        "removed": log.get("removed") is True,
        "key": "%s:%d" % (tx, idx),
    }


# ─── Transports: rpc(method, params) -> validated result, or RPCError ────────

def _unwrap(body):
    if not isinstance(body, dict):
        raise RPCError("response is not a JSON object")
    if body.get("error") is not None:
        raise RPCError("rpc error: %s" % json.dumps(body["error"])[:200])
    if "result" not in body:
        raise RPCError("response has no result")
    return body["result"]


def _key(chain_id, method, params):
    return "%d|%s|%s" % (chain_id, method, json.dumps(params, sort_keys=True, separators=(",", ":")))


def http_rpc(url):
    def rpc(method, params):
        data = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
                body = json.loads(resp.read())
        # URLError, HTTPError and timeouts are OSError; JSON and UTF-8 errors are ValueError.
        except (OSError, ValueError, http.client.HTTPException) as e:
            raise RPCError("%s: %s" % (type(e).__name__, str(e)[:200]))
        return _unwrap(body)
    return rpc


def fixture_rpc(path, chain_id):
    with open(path) as f:
        responses = json.load(f)["responses"]

    def rpc(method, params):
        key = _key(chain_id, method, params)
        if key not in responses:
            raise RPCError("fixture miss: " + key)
        return _unwrap(responses[key])
    return rpc


# ─── State ───────────────────────────────────────────────────────────────────

def load_state(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        return {"version": 1, "chains": {}}
    except (OSError, ValueError) as e:
        raise StateError("%s: %s" % (type(e).__name__, e))
    ok = isinstance(data, dict) and data.get("version") == 1 and isinstance(data.get("chains"), dict)
    for c in (data["chains"].values() if ok else ()):
        ok = ok and isinstance(c, dict) and type(c.get("block")) is int \
            and (c.get("hash") is None or (isinstance(c["hash"], str) and bool(_HASH.fullmatch(c["hash"])))) \
            and isinstance(c.get("seen"), list) and all(isinstance(s, str) for s in c["seen"])
    if not ok:
        raise StateError("unexpected state shape")
    return data


def save_state(path, state):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".cursors-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, sort_keys=True)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


# ─── Poll ────────────────────────────────────────────────────────────────────

def _block(rpc, n):
    """(hash, block time as ISO-8601 UTC) of block n, or None if the node has no such block."""
    b = rpc("eth_getBlockByNumber", [hex(n), False])
    if b is None:
        return None
    if not isinstance(b, dict):
        raise RPCError("block %d is not an object" % n)
    bhash = _hash32(b.get("hash"))
    try:
        return bhash, datetime.fromtimestamp(_qty(b.get("timestamp")), timezone.utc).isoformat()
    except (RPCError, OverflowError, OSError, ValueError):
        raise RPCError("block %d has no valid timestamp: %r" % (n, b.get("timestamp")))


def _block_hash(rpc, n):
    b = _block(rpc, n)
    return b and b[0]


def post_webhook(url, line):
    req = urllib.request.Request(url, data=line.encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=WEBHOOK_TIMEOUT) as resp:
            resp.read()
    except Exception as e:  # never log the URL: it can carry a secret
        _log("warning", "webhook_failed", error=type(e).__name__)


def seed_chain(chain_id, rpc, state, path, confirmations):
    """First run without --backfill: store the cursor at head - confirmations, scan no history."""
    cfg, key = CHAINS[chain_id], str(chain_id)
    n = max(_qty(rpc("eth_blockNumber", [])) - confirmations, cfg["start_block"] - 1)
    b = _block(rpc, n)
    if b is None:
        raise RPCError("block %d not found" % n)
    state["chains"][key] = {"block": n, "hash": b[0], "seen": []}
    save_state(path, state)
    _log("warning", "seed", chainId=chain_id, block=n, hash=b[0],
         detail="no cursor: seeded at head - confirmations, earlier events are not scanned "
                "(use --backfill to scan from the deploy block)")


def poll_chain(chain_id, rpc, state, path, confirmations, webhook_url, chunk=LOG_CHUNK):
    """Scan one chain from its cursor to head - confirmations.

    `state` changes only together with a save, so after an RPCError it still equals the file.
    """
    cfg, key = CHAINS[chain_id], str(chain_id)
    cur = state["chains"].get(key) or {"block": cfg["start_block"] - 1, "hash": None, "seen": []}
    block, bhash, seen = cur["block"], cur["hash"], list(cur["seen"])

    def commit():
        state["chains"][key] = {"block": block, "hash": bhash, "seen": seen}
        save_state(path, state)

    def check_cursor():
        nonlocal block, bhash
        if bhash is not None and _block_hash(rpc, block) != bhash:
            new = max(block - REORG_DEPTH, cfg["start_block"] - 1)
            _log("warning", "reorg", chainId=chain_id, detail="cursor %d hash changed, rewind to %d" % (block, new))
            block, bhash = new, None

    head = _qty(rpc("eth_blockNumber", [])) - confirmations
    check_cursor()

    targets = sorted(cfg["targets"])
    frm = block + 1
    rescans = 0
    while frm <= head:
        to = min(frm + chunk - 1, head)
        anchor = _block(rpc, to)
        if anchor is None:
            raise RPCError("block %d not found" % to)
        before = anchor[0]
        raw = rpc("eth_getLogs", [{"address": targets, "fromBlock": hex(frm), "toBlock": hex(to),
                                   "topics": [[OWNER_SET, WITHDRAWER_SET]]}])
        if not isinstance(raw, list):
            raise RPCError("eth_getLogs result is not a list")
        logs = sorted((_parse_log(l, frm, to) for l in raw), key=lambda l: (l["block"], l["logIndex"]))
        after = _block_hash(rpc, to)
        if after != before:  # the logs may come from a dropped branch: no alert, nothing committed
            rescans += 1
            _log("warning", "reorg", chainId=chain_id,
                 detail="block %d hash changed during scan of %d-%d: %s -> %s, re-scan" % (to, frm, to, before, after))
            if rescans > REORG_RETRIES:
                raise RPCError("block %d hash unstable after %d re-scans" % (to, REORG_RETRIES))
            check_cursor()  # the fork point can be below the cursor
            frm = block + 1
            continue
        times = {to: anchor}  # one header read per event block in this range
        for log in logs:
            if log["removed"] or not log["event"] or log["contract"] not in cfg["targets"] or log["key"] in seen:
                continue
            if log["block"] not in times:
                times[log["block"]] = _block(rpc, log["block"])
            b = times[log["block"]]
            if b is None or b[0] != log["blockHash"]:  # also a reorg after the anchor check: no alert
                raise RPCError("block %d header does not match log blockHash" % log["block"])
            alert = {
                "type": "role_change", "chainId": chain_id, "chain": cfg["name"],
                "contract": log["contract"], "label": cfg["targets"][log["contract"]],
                "event": log["event"], "previous": log["previous"], "new": log["new"],
                "block": log["block"], "blockHash": log["blockHash"], "txHash": log["txHash"],
                "logIndex": log["logIndex"], "timestamp": b[1],
            }
            line = json.dumps(alert, sort_keys=True)
            print(line, flush=True)
            if webhook_url:
                post_webhook(webhook_url, line)
            seen = (seen + [log["key"]])[-SEEN_MAX:]
            commit()  # old cursor, new seen: a crash replays at most this one alert
        block, bhash = to, before
        commit()
        frm = to + 1


# ─── CLI ─────────────────────────────────────────────────────────────────────

def _nonneg(s):
    v = int(s)
    if v < 0:
        raise ValueError(s)
    return v


def main(argv=None):
    env = os.environ.get
    p = argparse.ArgumentParser(prog="python3 -m monitoring.watcher", description=__doc__.splitlines()[0])
    p.add_argument("--once", action="store_true", help="poll each chain one time, then exit (1 if any chain failed)")
    p.add_argument("--interval", type=_nonneg, default=env("MONITOR_INTERVAL", "60"),
                   help="seconds between polls in loop mode (env MONITOR_INTERVAL, default 60)")
    p.add_argument("--confirmations", type=_nonneg, default=env("MONITOR_CONFIRMATIONS"),
                   help="stay this many blocks behind head (env MONITOR_CONFIRMATIONS, default and minimum 5; "
                        "no minimum with --fixture)")
    p.add_argument("--state-file", default=env("MONITOR_STATE_FILE"),
                   help="cursor file (env MONITOR_STATE_FILE, default monitoring/.state/cursors.json)")
    p.add_argument("--backfill", action="store_true",
                   help="first run only: scan each chain that has no cursor from its deploy block and emit the "
                        "historical alerts (default: seed the cursor at head - confirmations and emit nothing)")
    p.add_argument("--fixture", help="replay recorded responses: one poll, no network, no webhook, implies --backfill")
    p.add_argument("--verbose", action="store_true", help="write one poll_ok line per chain to stderr")
    args = p.parse_args(argv)

    floor = 0 if args.fixture else MIN_CONFIRMATIONS
    conf = floor if args.confirmations is None else args.confirmations
    if conf < floor:
        _log("warning", "config", detail="confirmations %d is below the minimum %d, using %d" % (conf, floor, floor))
        conf = floor

    webhook = None if args.fixture else env("MONITOR_WEBHOOK_URL") or None
    if webhook and urllib.parse.urlsplit(webhook).scheme not in ("http", "https"):
        _log("error", "config", detail="MONITOR_WEBHOOK_URL must be http or https")
        return 2

    tmpdir = None
    path = args.state_file
    if not path and args.fixture:  # a fixture run must not move the production cursor
        tmpdir = tempfile.TemporaryDirectory()
        path = os.path.join(tmpdir.name, "cursors.json")
    path = path or DEFAULT_STATE

    try:
        state = load_state(path)
    except StateError as e:
        _log("error", "state_corrupt", detail=str(e))
        return 2
    try:
        rpcs = {cid: fixture_rpc(args.fixture, cid) if args.fixture
                else http_rpc(env("MONITOR_RPC_%d" % cid) or cfg["rpc_url"]) for cid, cfg in CHAINS.items()}
    except (OSError, ValueError, KeyError, TypeError) as e:
        _log("error", "config", detail="fixture unreadable: %s" % type(e).__name__)
        return 2

    once = args.once or bool(args.fixture)
    backfill = args.backfill or bool(args.fixture)  # a fixture replays recorded history
    try:
        while True:
            failed = False
            for cid in CHAINS:  # chains are independent: one failure never blocks the other
                try:
                    if backfill or str(cid) in state["chains"]:  # an existing cursor always wins
                        poll_chain(cid, rpcs[cid], state, path, conf, webhook)
                    else:
                        seed_chain(cid, rpcs[cid], state, path, conf)
                    if args.verbose:
                        _log("info", "poll_ok", chainId=cid, block=state["chains"].get(str(cid), {}).get("block"))
                except RPCError as e:
                    failed = True
                    _log("error", "rpc_error", chainId=cid, detail=str(e))
            if once:
                return 1 if failed else 0
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
