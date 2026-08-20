# ADR-007 — FeeCollector v2: `claimRefundFor` passthrough for kat-igra-bridge

**Status:** Proposed — awaiting Leo's approval, then published to the evm-fee-collectors wiki (Notion → Decisions).
**Date:** 2026-08-20
**Project:** `kat-igra-bridge` only (ADR-004).
**Supersedes:** nothing. **Superseded by:** nothing.
**Evidence base:** `docs/specs/kasbridge-evidence.md` (branch `design/fee-collector-v2`, built 2026-08-20, chain reads at block 14732471). Every claim about contract behaviour below cites a section of that pack. Claims that could not be cited are listed in *Open Questions & Uncited Assumptions* and are **not** relied on by the design.

> **Repo copy.** The evidence pack §6 states the ADR series lives as Notion pages and instructs against creating `docs/adr/`. This file exists only so the draft is reviewable in git before publication; Notion remains the canonical home. Numbering follows §6: current range is ADR-001…ADR-006, so this is **ADR-007**.

---

## Context

### What v2 is actually insurance against

The trigger scenario is easy to state backwards, so it is stated precisely here.

`KasBridge.claimRefund` requires the exit to be **not acknowledged** (§1.4, line 394: `require(!e.acknowledged, "Already acknowledged")`), and requires `block.number >= e.blockNumber + REFUND_BLOCK_DELAY` (§1.4, line 397), with `REFUND_BLOCK_DELAY` immutable at **172 800 blocks ≈ 48 h** for every exit past and future (§1, live-read table; the constant cannot be changed by governance because it is `immutable`, §1 header lines 34–39).

Per KAT — Ashton, 2026-08-17, verbatim: *"Relayers acknowledge without checking L1 liquidity. `acknowledgeExit` only requires a valid exit + relayer quorum. No vault balance check."* So an exit against a liquidity-starved bridge is acknowledged immediately and is therefore **permanently outside the refund path**: once acknowledged, `claimRefund` is dead forever and only the admin-quorum `proposeForceRefundExit` remains (§1.4, "Line 394 makes the window one-sided"). Such an exit waits for KAT's demand-driven rebalance and is then paid out normally, late. That is what has happened in every case so far. The census in `withdraw-gate-findings.md` (2026-08-18) found **111 of 111 exits acknowledged and processed, 0 refunds ever** over blocks 7.17M→14.42M, and a log scan run for this ADR reproduces it independently and extends it: **129 exits routed through our collector over blocks 7 000 000→14 745 955, and zero `ExitRefunded` or `ExitForceRefunded` events naming our collector as `sender` in that entire range** (*Open Questions*, item 6). The refund path has never once opened for one of our users.

**The refund path opens only if the relayer set fails to acknowledge at all for 172 800 blocks** — i.e. a KAT validator-layer outage, not a bridge running short of KAS.

v2 is insurance against **that** specific failure. In that failure, the refund path is the only recovery mechanism that exists. v2 is **not** protection against liquidity shortfalls; liquidity shortfalls never reach the refund path.

### Why the refund path is currently unreachable for our users

```
  user ──value──▶ FeeCollector v1 ──net──▶ KasBridge.lockForExit
                  (0x9d01E8a2…)             records sender = FeeCollector
                                                   │
                                     claimRefund   │ sender-gated, pays msg.sender
                                                   ▼
                                            FeeCollector v1
                                                   │
                                            (no code exists here)
                                                   ✗
                                                 user
```

- Exits route user → our FeeCollector → `KasBridge.lockForExit` (§7-C3, §5.1 lines 150/153/156, §3.2 line 142).
- KasBridge records `sender: msg.sender` (§1.3, line 366) — for our architecture that is the FeeCollector, never the end user, and the `Exit` struct has **no slot in which a wrapper can stamp the real user** (§1.1).
- `claimRefund` is hard sender-gated (§1.4, line 393) and pays `msg.sender` (§1.4, line 412). An end user calling it directly reverts `"Not exit sender"`.
- Our v1 FeeCollector is 166 lines with no `exitId` capture, no per-user mapping, and no path to call `claimRefund` (§3.2, §3.4 — the complete privileged surface, "no pause, no upgrade hook, no rescue function, no arbitrary-call escape hatch").

Composite consequence, stated in the pack (§7-C3): **for every exit ever placed through `0x9d01E8a2…`, the address entitled to a refund is the FeeCollector, and the FeeCollector has no code that can claim it.** The single mitigating fact is that `receive()` exists (§3.6, line 165), so a refund that were somehow triggered would land in the contract and be recoverable only by `withdrawNative` + manual payout. Separately, kastle-mobile currently offers a refund flow built on the opposite assumption — `exit-state.ts:138-144` simulates `claimRefund` against the bridge with the user's own address, which is dead for every routed exit (§7-C3).

### Settled context (not relitigated here)

- Leo decided 2026-08-18 to build v2 rather than wait for a KAT-side refundee parameter.
- KasBridge is immutable third-party infrastructure (§3.7: upstream `proxy_type: None`, `implementations: []`). v2 works against it exactly as deployed.
- Deployment is gated on Ashton's sanity-check, full crypto-surface human gates, and Leo approving this ADR.

---

## Decision

Ship **FeeCollector v2** in `kat-igra-bridge/` as a new, non-upgradeable deployment that (a) records the originator of every exit it places and (b) exposes an ungated `claimRefundFor(exitId)` that claims the upstream refund and forwards it to that recorded originator.

### 1. Mapping write: `exitId → originator` at `bridgeToL1` time

**Synchronous acquisition is available. No architectural change is required.**

The evidence pack answered **YES** to synchronous `exitId` acquisition (§2). The mechanism is the public `exitCounter` getter (§1.1, line 78) combined with the post-increment on `§1.3` line 364 (`uint256 exitId = exitCounter++`). The `exitId` assigned to an exit is exactly the value of `exitCounter` read immediately *before* the external call. §2 states this is *"exact, not a heuristic"*: within a single transaction no other transaction can interleave, and `lockForExit` carries `nonReentrant` (§1.3, line 343) which forecloses a reentrant second `lockForExit` inside the same call frame.

**Design:** in `bridgeToL1`, immediately before the forwarding call:

1. `exitId = bridge.exitCounter()` — one extra `STATICCALL` (§2, caveats).
2. `bridge.lockForExit{value: netValue}(addrBytes)` — unchanged from v1 (§3.2, line 142).
3. `exitOriginator[exitId] = msg.sender` — one `SSTORE`.
4. `emit ExitRegistered(exitId, originator, netValue)`.

**The recorded originator is a parameter, not implicitly `msg.sender`.** v2 exposes two entry points:

- `bridgeToL1(bytes calldata kaspaAddress)` — records `msg.sender`. This is the path kastle-mobile uses today (§5.1, lines 146–158) and its ABI is unchanged.
- `bridgeToL1(bytes calldata kaspaAddress, address originator)` — records the caller-declared `originator`, rejecting `address(0)`.

Rationale for carrying the second form from day one rather than adding it later: for an **EOA or a hardware wallet** the one-argument form is already correct — `msg.sender` is the user's own account. The form that breaks is an **intermediary**: a smart-contract-wallet relayer, an aggregator, or a batching contract calling on behalf of many users would capture every refund into itself. Smart-contract and hardware wallet support is on Kastle's roadmap (briefing, 2026-08-20 — see *Open Questions*). Under ADR-002 (§8) the contract is immutable, so "add it when we need it" is not an option: it would cost a second full migration — which is precisely the position v1 is in, and precisely the mistake this ADR exists to correct. The parameter is 20 bytes of calldata on a path that already spends ~20 000 gas on the mapping write.

The declared `originator` is **not** a trust concession. The caller has already supplied the full `msg.value`; declaring someone else as originator gives money away rather than taking it, so the parameter creates no path to funds the caller did not already control.

The read-after form (`bridge.exitCounter() - 1`) is equally exact per §2 and works because the `nonReentrant` lock is released before the call returns. Read-before is chosen for one reason only: it needs no arithmetic and no assumption about how many times the counter advanced inside the call. If `lockForExit` reverts on any of its inherited revert paths (§1.3: lines 347–352 min-value/`MIN_FEE_FLOOR`, 357–361 min/max/rolling cap, 344–345 paused/disabled), the whole transaction unwinds and the mapping write unwinds with it (§2, caveats; §1.3, "a revert un-does our fee too").

**Storage cost per exit:** one 32-byte slot, `mapping(uint256 => address) public exitOriginator`. Cold zero→non-zero `SSTORE` is 20 000 gas by the EVM's standard schedule (general EVM cost, not a fact from the pack — see *Open Questions*), plus the `STATICCALL` in step 1.

**Entries are never cleared.** Reasons:

- Double-claim is already foreclosed upstream, not by us: `claimRefund` sets `e.refunded = true` before paying (§1.4, line 399) and a second call reverts `"Already refunded"` (§1.4, line 395). A local `claimed` flag would duplicate upstream state.
- The admin force-refund path (§1.5) can fire at any later time and pays `e.sender` — our contract. Clearing the mapping would destroy the only record of who that money belongs to.
- Clearing buys a gas refund on the rarest path and adds a state machine to the money path. Not worth it.

The mapping therefore grows monotonically for the life of the contract, one slot per exit. That is the accepted price.

### 2. `claimRefundFor(uint256 exitId)` — callable by anyone

**`external`, no access modifier.** The payout target is read from the mapping, never from `msg.sender`, so an arbitrary caller cannot redirect funds. This is what makes the function safe to open, and opening it buys three things: a keeper can rescue a user who cannot or will not transact; the path survives loss of owner keys (§7 below); and it removes Kastle from the critical path of a user recovering their own money.

Flow:

1. `originator = exitOriginator[exitId]`; if `address(0)`, revert `UnknownExit()`.
2. Record `balanceBefore = address(this).balance`.
3. Call `bridge.claimRefund(exitId)`. Upstream re-checks every condition — sender is us (§1.4, line 393), not acknowledged (394), not refunded (395), not processed (396), window elapsed (397) — and reverts if any fails. **v2 duplicates none of these checks.** The refund lands on our `receive()` as `grossAmount`, which is exactly the net we forwarded (§1.4, line 410; §1.4 meaning: *"our fee is not part of this number and is not returned by KasBridge"*).
4. `amount = address(this).balance - balanceBefore`; revert `NothingReceived()` if zero.
5. Forward `amount` to `originator` with a bare `.call`; revert `TransferFailed()` if it fails.
6. `emit RefundForwarded(exitId, originator, amount)`.

**Why balance-delta rather than a fixed figure.** The refund arrives as an **untagged native transfer** — *"Nothing in the call tells the wrapper which exit it belongs to"* (§1.4, meaning). Measuring the delta across the upstream call is the only local, self-consistent measurement, and it has a property this design needs: the forwarded amount can never exceed what actually arrived during that call, so **the function is structurally incapable of drawing on pooled balance** (see §4 below). Reading `bridge.exits(exitId)` for `grossAmount` (the getter is public, §1.1) would work too, but adds a second `STATICCALL` and a second trust surface for no gain.

**Missing mapping entry → revert.** `UnknownExit()` is a cheap early exit; upstream would revert anyway with `"Not exit sender"` for any exit v2 did not place (§1.4, line 393). There is deliberately **no** caller-supplied fallback recipient: that would convert an ungated function into a theft vector.

**Failure behaviour is safe, but not self-healing.** If step 5 fails — an originator contract that rejects value — the whole transaction reverts, and with it `e.refunded = true` upstream. The exit stays claimable and the call can be retried. No funds are lost or stranded in v2; they never leave KasBridge.

A **permanently** un-payable originator is a different matter, and it is not an ops-runbook case: it is a dead end. The funds sit in KasBridge; the only thing that can move them is `claimRefund`, which is gated to `e.sender` = v2 (§1.4, line 393); the only v2 code that calls it pays the mapped originator and reverts. Ops has no key, no withdrawal and no override that reaches those funds. `withdrawNative` cannot help — the money is not in v2's balance and never arrives there.

**Decision: v2 ships a second entry point to close this.**

`claimRefundTo(uint256 exitId, address to)` — identical flow to `claimRefundFor`, except gated on `msg.sender == exitOriginator[exitId]` and paying `to` (rejecting `address(0)`). `claimRefundFor(exitId)` becomes the ungated wrapper that passes `to = exitOriginator[exitId]`; both share one internal implementation, so there is one money path, not two.

This is not a theft vector: only the recorded originator can redirect, and only their own refund. It rescues the case that matters — a contract that **can execute but cannot receive value** (no `receive`, no payable fallback), which is a common shape and is exactly what the intermediary scenario in §1 produces. It does not rescue an originator that cannot execute at all — a lost-key EOA, or a contract with no reachable call path. That residual case is genuinely unrecoverable and is stated here as such rather than deferred to a runbook that has no mechanism.

### 3. Reentrancy and `receive()` posture

**Ordering.** `claimRefundFor` writes no v2 storage at all — the mapping is read, never modified (§1 above). The effect that matters (`e.refunded = true`) is written by upstream *before* it pays us (§1.4, line 399 precedes line 412), and `claimRefund` is itself `nonReentrant` (§1.4, line 391). Checks-effects-interactions is satisfied by construction: our only mutation of shared state is the one upstream performs and guards.

**Guard.** `claimRefundFor` still carries a hand-rolled reentrancy lock — a single `bool locked` with a modifier, matching v1's hand-rolled style with no OpenZeppelin dependency (§3.1: *"Hand-rolled, no OpenZeppelin `Ownable`, no `AccessControl`"*). The lock is not needed for double-claim (upstream forecloses that) but for the outbound `.call` in step 5, which hands control to arbitrary code *after* upstream's `nonReentrant` has been released. The guard removes the need to reason about a nested `claimRefundFor(otherExitId)` at all.

`bridgeToL1` is **not** guarded: it makes one external call, to `lockForExit`, which is `nonReentrant` upstream (§1.3, line 343) and never calls back into us. Re-entering `bridgeToL1` from elsewhere places an independent, self-funded exit and corrupts nothing. Adding a guard there would tax the hot path for no benefit.

**`receive()` must accept, unconditionally, from anyone.** v1's is empty and accepts any native value from anyone, emitting nothing (§3.6, line 165). v2 keeps the accept-everything posture and adds an event.

*What it must accept:*
- The refund inflow from KasBridge during `claimRefundFor`. Without a payable receiver, `claimRefund` reverts on its `require(sent, "Refund transfer failed")` (§1.4, line 413).
- **Unsolicited** force-refund inflow from KasBridge at any time (§1.5, line 1002). The pack is explicit: *"A wrapper with no `receive()` would be permanently unrefundable by either path"* (§1.5, meaning), and upstream's force-refund branch rolls back its own accounting when the recipient is un-payable, with a comment naming a contract recipient as the anticipated failure (§1.5, lines 1005–1010).

*What it must reject:* **nothing.** There is no sender-filter worth adding. Fees do not arrive through `receive()` — they arrive as the unforwarded portion of `msg.value` inside `bridgeToL1` (§3.2, lines 136–137) — so filtering `receive()` protects nothing, and any rejection condition is a new way to make a refund revert.

*Gas note:* emitting from `receive()` is safe because both upstream payout sites use a bare `.call` with no gas cap (§1.4, line 412; §1.5, line 1002), not `transfer`. Under a 2300-gas stipend an event in `receive()` would break refunds.

### 4. Fee handling on refund — **SETTLED (Leo, 2026-08-20)**

**v2 returns the bridged gross only. The 0.75 % Kastle routing fee is NOT refunded.** This is a decision, not an open question.

Rationale:

- KAT's own `claimRefund` already returns the full gross including KAT's fee (§1.4, line 410: `refundAmount = e.grossAmount`; §1.3 lines 354–355 show the upstream fee was taken out of that gross). Nothing of KAT's is withheld from the user.
- Our fee is taken *before* `lockForExit` and was therefore never part of the gross: lines 136–137 of `bridgeToL1` compute it and forward only `netValue` (§3.2), and the pack notes the fee *"becomes indistinguishable from the rest of `address(this).balance` the instant the call returns"* (§3.2).
- Building reserved per-exit fee accounting — window-aware withdrawal logic plus a funded float, in money-path code — is disproportionate to an event that has occurred 0 times in 111 exits. The pack costs this route precisely: returning the fee *"requires either a funded float, or a segregated/reserved fee accounting that `withdrawAllNative` cannot touch — the same shape upstream already implements with `pendingExitFees`"* (§3b).

**Hard constraint: v2 MUST NOT draw on `address(this).balance` to top up a refund.** The pack proved fees are not segregated: `withdrawAllNative` takes `address(this).balance` in full with no reserve for in-flight exits (§3.5, line 157; §3b), and on chain 2 274.960715548375 iKAS was drained to **zero** at block 13915637 while **four** FeeCollector-routed exits were still inside their 172 800-block refund window (§3b, with the balance reads at blocks 13915636/13915637/13915638). Covering a fee from the pooled balance would therefore pay one user out of other users' un-withdrawn fees.

The balance-delta measurement in §2 above enforces this structurally, not by convention: the forwarded amount is bounded by what arrived during the upstream call.

If the never-case ever fires, the fee is returned manually via the stranded-refund ops runbook.

### 5. Force-refund compatibility

`proposeForceRefundExit(exitId)` is `onlyAdmin` — KAT's admins, not ours — and requires the exit to be already acknowledged, not processed, not refunded (§1.5, lines 638–643). Execution happens on admin quorum (§1.5, line 670) and pays `refundAmount = e.grossAmount` to `payable(e.sender)` — **our contract** — via a bare `.call` (§1.5, lines 999–1002). It is *"the **only** recovery route once an exit is acknowledged"* (§1.5, meaning).

**Does v2's forwarding cover that inflow? No — and the difference is structural, not incidental.**

| | `claimRefund` inflow | force-refund inflow |
|---|---|---|
| Who initiates | anyone, via v2's `claimRefundFor` (§1.4, 393/412) | KAT admin quorum (§1.5, 638/670) |
| Entry point into v2 | inside `claimRefundFor`, between `balanceBefore` and the forward | bare value transfer into `receive()` (§3.6) |
| Is it measurable per-exit | yes, by balance-delta across our own call | **no** — untagged, unsolicited, merges into `address(this).balance` |
| Auto-forwarded | yes | **no** |

Because v2 is not the caller, there is no frame in which to measure or attribute the money. It lands and becomes indistinguishable from fee balance the moment it arrives (§3.6: *"Nothing distinguishes an arriving refund from an arriving fee or a stray transfer"*).

**Decision: v2 ships no automatic force-refund forwarding.** Force-refund is already a human-coordinated event requiring a KAT admin quorum; automating our half of it would mean a second money-moving path that pays a user *out of pooled balance* — reintroducing precisely the hazard §4 forbids, to serve an event gated behind other people's governance. Instead:

- `receive()` emits `NativeReceived(from, amount)` so the inflow is **detectable** rather than silent — closing the §3.6 gap.
- `exitOriginator[exitId]` is never cleared (§1), so the record of who the money belongs to survives indefinitely.
- Payout runs through the stranded-refund ops runbook: `withdrawNative` to the originator, referencing the `ExitRegistered` event for attribution.

*(If Leo wants this trustless instead, the shape is ~15 lines — read `bridge.exits(exitId)`, require `acknowledged && refunded`, pay `exitOriginator[exitId]` once behind a `forceRefundForwarded[exitId]` flag. It is bounded and cannot overpay. It is excluded here only because it necessarily spends pooled balance and races the withdrawer. Flag it if you disagree.)*

### 6. Era split and migration

**New deployment at a new address** — required by ADR-002 (§6), which the deployed code already satisfies structurally: `IKasBridge public immutable bridge` set once in the constructor, no proxy, no delegatecall, no implementation slot, no initializer (§3.7). There is **no path to add `claimRefundFor` to v1**.

Cutover:

1. Deploy v2 to IGRA Mainnet (chainId 38833) with the same constructor shape: `(_owner, _withdrawer, _feeRate = 75, _bridge = 0xb82c5524c5b5c055efb2f8f4abcce3173c504f2d)` (§3.3 lines 68/76/77; §4 live `bridge()` and `feeRate() = 75`).
2. `DEPLOYMENTS.md` gains the v2 row and marks the v1 row **retired**; v1 is line 32 today (§4).
3. kastle-mobile flips `KAT_IGRA_FEE_COLLECTOR_BRIDGE_ADDRESS` in `lib/bridge/fee-collector.ts:43-45` (§4 cross-check — currently byte-for-byte equal to `DEPLOYMENTS.md:32`). One constant; the app's ABI against our contract exposes only `bridgeToL1`, `feeRate`, `owner` (§5.1) and gains `claimRefundFor` + the new events.
4. The device-local `IgraExitRecord` (§5.2, `exit-history.ts:6-8`) gains an **`exitVia: "v1" | "v2"`** tag written at exit time. `lib/activity/exit-state.ts` routes on it: v2 exits simulate and call `claimRefundFor(exitId)` against v2; v1 exits render as ops-recovery-only and **must stop offering the dead `claimRefund` simulation** that `exit-state.ts:138-144` performs today against the bridge with the user's address (§7-C3).

**The era split must also work for rows that were never written locally.** A parallel session has made kastle-mobile's bridge history **remote-first**, sourced from KAT's `/bridge-history` API (briefing, 2026-08-20 — see *Open Questions*). Those rows carry **neither `exitId` nor `exitVia`**, so a tag written at exit time does not reach them, and a v2 exit that the user sees only via the KAT API would show no claim button. The era must therefore be derivable, not just recorded:

1. **`ExitRegistered` lookup wins.** Filter `topic2 = user address`; a match on the row's L2 transaction hash yields both the era (v2, by definition — v1 emits no such event) and the `exitId` the claim needs. This is the only derivation that works with zero local state.
2. **Else, deploy-block comparison.** A row whose block precedes v2's deploy block is v1-era; no claim button.
3. **Else, fail closed.** No era, no claim button. Never render a claim path that will revert — that is exactly the defect §7-C3 already produced once, and a wrong "claim" button on real money is worse than a missing one.

*(Step 1 assumes the `/bridge-history` row exposes the L2 transaction hash to join on. If it does not, the join key must be user + block + amount, which is weaker. See *Open Questions*.)*

**Three history sources now exist; the redundancy should be deliberate.**

| Source | Authoritative for | Fails when |
|---|---|---|
| KAT `/bridge-history` API | L1 settlement status and payout — the only source that sees the Kaspa side | KAT is down; carries no `exitId`, no era |
| Device-local `IgraExitRecord` | fast render, offline, carries `exitVia` at write time | device lost or reinstalled; `exitId` is nullable by design (§5.2) |
| `ExitRegistered` logs | **the only trustless source**; user↔exit↔era binding | v1-era exits (no such event); needs an RPC log query |

Merge rule: union by L2 transaction hash, and **never let a source that lacks era information suppress a claim** a source with era information supports. The KAT API is authoritative for status; `ExitRegistered` is authoritative for era and `exitId`.

**v1 disposition: drain and retire. Decided here, not deferred.** (The wiki's four undecided orphan deployments are the precedent for why leaving this open is a mistake — briefing figure, see *Open Questions*.)

- *Drain:* withdraw the remaining balance — 422.6925 iKAS at block 14732471 (§4) — after the cutover. Timing is unconstrained by refunds: refund money comes from KasBridge's reserves, not ours (§3b), and v1 has no `claimRefundFor` to fund in any case.
- *Retire:* v1 has no pause and no kill switch (§3.4: the complete privileged surface), so it stays live and callable forever. Retirement is a client-side and documentation act: kastle-mobile stops pointing at it, `DEPLOYMENTS.md` marks it retired, admin-ui drops it from the active set. Setting `feeRate` to 0 is **not** part of retirement — it does not stop `bridgeToL1` and only makes a stray direct call cheaper.

**Pre-v2 exits stay on the ops-runbook recovery path forever.** Every exit placed through `0x9d01E8a2…` — before, during, and after the cutover — has `e.sender` recorded as v1 (§1.3, line 366), and v1 has no code that can call `claimRefund` (§7-C3). No v2 deployment changes that for a single historical exit. If such an exit ever becomes refundable, recovery is manual and requires owner or withdrawer keys.

### 7. Ownership and admin

v2 keeps ADR-003's model unchanged (§6): hand-rolled two-role access control, two-step ownership handover via `pendingOwner`, `onlyWithdrawer` admitting **both** withdrawer and owner (§3.1, lines 53–61; §3.4 table). **v2 adds no new owner powers.** The privileged surface stays exactly: `transferOwnership`, `acceptOwnership`, `setWithdrawer`, `setFeeRate`, `withdrawNative`, `withdrawAllNative`.

**Non-negotiable: `claimRefundFor` works even if owner keys are lost.** It does — as does `claimRefundTo` (§2) — and the proof is that neither depends on anything owner-controlled:

- Neither carries an `onlyOwner` / `onlyWithdrawer` modifier, and neither reads `owner` or `withdrawer`.
- The only precondition inside v2 is `exitOriginator[exitId] != address(0)`, written at `bridgeToL1` time by the user's own transaction — not by an admin.
- The payout target is that mapping entry (or, for `claimRefundTo`, an address the mapped originator itself names), which no admin function can modify: there is no setter, and none is added.
- Its remaining preconditions are enforced upstream by KasBridge (§1.4, lines 393–397), which our keys cannot influence.
- Upstream's `claimRefund` is *"Always callable, even when paused/disabled, so users can recover funds during emergencies"* (§1.4, doc comment lines 388–390).

Total loss of both key sets therefore costs the ability to withdraw fees and change the fee rate. It does not cost any user their refund path.

**Keys today** (§4, live at block 14732471, **no drift** from the 2026-07-28 briefing): `owner() = 0xbBA114b131c1ff6e0fEfaB1329eBFaAa5f306c94`, `withdrawer() = 0x4be2c073c16494Abbe3489b953c198b393b1675A`, `pendingOwner() = 0x0` — two distinct EOAs. The deployer `0xC9b501CD…` is not a live role (§4).

The **multisig migration remains open** under ADR-003 (§6) and this ADR does not resolve it. Two related facts should be carried into that decision rather than assumed away: `onlyWithdrawer` admits the owner too (§3.1, line 59), and both withdrawal functions accept an arbitrary caller-supplied `to`, checked only against `address(0)` — on chain the largest withdrawal settled to the *withdrawer*, not the owner (§7-C2). v2 does not narrow `to`; that is a change to the withdrawal surface and belongs to the multisig decision, not here.

### 8. Upgradeability

**v2 follows ADR-002 (§6): non-upgradeable, upstream address immutable.** No proxy, no initializer, no mutable `bridge`, no `delegatecall`. This matches v1 as deployed (§3.7: line 31 `IKasBridge public immutable bridge`, set once at line 77; Blockscout `proxy_type: None`, `implementations: []` for the upstream too) and matches KasBridge itself, which is not a proxy (§3.7).

**No supersession of ADR-002 is proposed.** Implications, accepted:

- v1 cannot be fixed in place. The address change *is* the migration (§6 above), and its cost is a client release plus a documentation sweep.
- A future v3 repeats the same cutover. That cost is the price of the property that no key can rewrite the code holding user funds.
- The refund path's correctness rests on KasBridge's ABI, which cannot change under us: the upstream is not a proxy, and `REFUND_BLOCK_DELAY` is `immutable` (§1 header, §1 live table). Governance-mutable upstream values (`feePercentBps`, `maxExitAmount`, `rollingExitCap`, pause flags — §1, §1.6) affect whether `lockForExit` succeeds, never whether `claimRefundFor` works. v2 reads none of them.

### 9. Events

v2 keeps every v1 event (`FeeCollected`, `NativeWithdrawn`, `OwnerSet`, `OwnershipTransferProposed`, `WithdrawerSet`, `FeeRateSet` — §3.2 line 139, §3.4, §3.5) and adds three:

| Event | Emitted | Purpose |
|---|---|---|
| `ExitRegistered(uint256 indexed exitId, address indexed originator, uint256 netAmount)` | `bridgeToL1`, after the mapping write | The on-chain user↔exit link that KasBridge's own `Exit` struct has no slot for (§1.1) |
| `RefundForwarded(uint256 indexed exitId, address indexed originator, address to, uint256 amount)` | `claimRefundFor` / `claimRefundTo`, after a successful forward | Settlement receipt for Activity. `to` equals `originator` on the ungated path and differs only when the originator redirected (§2) |
| `NativeReceived(address indexed from, uint256 amount)` | `receive()` | Makes unsolicited inflows — force-refunds above all (§5) — visible instead of silent (§3.6) |

Two indexed topics plus non-indexed data mirrors upstream's `LockForExit` layout (§1.2), which is what makes exits *"cheaply enumerable off chain by filtering `topic2 == feeCollector`"*.

**`ExitRegistered` is the one that earns its gas** — and it is now the third bridge-history source (§6), not a nicety. Today `exitId` is recovered off chain from the receipt and stored device-locally, and it is *"**nullable by design**"* — `exitId: string | null`, null when the event decode fails (§5.2, `exit-history.ts:6-8`, `useKatIgraToKasBridge.ts:360-391`, whose whole block is wrapped in a best-effort `try/catch`). Any device loss or decode failure today means the exit is unrecoverable by the user. With `ExitRegistered`, filtering `topic2 == user` rebuilds the full exit list from chain.

**What kastle-mobile keys on:**

- `ExitRegistered` filtered on `topic2 = user address` → rebuild exit history without device-local storage; `topic1` supplies the `exitId` that `exit-state.ts` needs (§5.2). Belt-and-braces: keep the existing receipt parse, which stays correct.
- `RefundForwarded` filtered on `topic1 = exitId` → transition Activity to refunded and stop polling.
- The refund-claimable check moves from simulating `claimRefund(exitId)` against the bridge — the *"ONLY per-exit signal the in-repo ABI allows"* (§5.2, `exit-state.ts:10-13`) and dead for routed exits (§7-C3) — to simulating **`claimRefundFor(exitId)` against v2**, which is a live and truthful signal because it exercises the exact path the user will take. `REFUND_WINDOW_MS = 48h` (§5.2, line 62) and the `refund_claimable → claim_refund` action mapping (line 110) stay as they are.

### 10. Scope fence — what v2 deliberately does NOT do

- **No fee-logic changes.** `feeRate` stays a constructor parameter, owner-settable at runtime, bounded by `MAX_FEE_RATE = 1_000` (§3.3, lines 24/68/76/105–109), per ADR-006 (§6). The 0.75 % value itself is owned by Kastle Wiki ADR-001, not this repo (§6).
- **No fee segregation.** No `pendingExitFees` analogue, no reserve, no window-aware withdrawal, no float (settled in §4).
- **No changes to the other three collectors.** `kasplex-bridge`, `kat-igra-krc20`, `zealous-swap` are untouched. ADR-004 (§6) requires v2 to land inside `kat-igra-bridge/` only, *"even if v2 duplicates logic already in `kasplex-bridge`"* — no shared base, no new package. Note the surfaces genuinely differ: two projects have 2 withdrawal functions, two have 4 (§3.7).
- **No new privileged powers.** No pause, no upgrade hook, no rescue function, no arbitrary-call escape hatch — v1 has none (§3.4) and v2 adds none. In particular there is **no owner rescue for a stuck refund**: the redirect in §2 is gated to the originator, not to us, so no Kastle key can ever redirect a user's refund.
- **No automatic force-refund forwarding** (§5).
- **No narrowing of `to` on the withdrawal functions.** That belongs to the ADR-003 multisig decision (§7).
- **No ERC-20 path.** v1 has none, confirmed by grep (§3.7).
- **No off-chain component.** No keeper, sweeper, cron or indexer ships with v2. The repo has none today and the pack verified it (§3b: *"nothing moves money on a timer"*). `claimRefundFor` being ungated means a keeper *can* be added later by anyone, including us, without a contract change.
- **No assumptions about KasBridge beyond what the evidence pack quotes.** In particular v2 does not read, mirror or predict `feePercentBps` — governance-mutable, live 10 bps, with an immutable 10 iKAS `MIN_FEE_FLOOR` that dominates on small exits (§1, §1.6) — and does not depend on `MIN_EXIT_AMOUNT`, `maxExitAmount`, `rollingExitCap` or the pause flags. Those affect whether an exit can be *placed* (§1.3, lines 347–361), never whether a refund can be *forwarded*.

---

## Alternatives considered

**A. KAT-side `refundee` parameter on `lockForExit`.** The clean fix: let the wrapper name the real beneficiary, so KasBridge pays the user directly and no mapping, no passthrough and no extra storage exist anywhere. **Rejected on timeline.** KAT is bandwidth-constrained, and KasBridge as deployed is immutable third-party infrastructure with no proxy (§3.7) — adopting this means waiting for a KAT release *and* a redeploy *and* a migration, with our users unprotected throughout. Note the pack's structural finding: the `Exit` struct has *"no slot in which a wrapper can stamp the real user"* (§1.1), so this is a KAT contract change, not a call-site change. If KAT ships it later, v2 does not block adopting it.

**B. Two-transaction flow** — user calls `KasBridge.lockForExit` directly and pays Kastle's fee in a separate transaction, so `e.sender` is the user and `claimRefund` works natively. **Rejected:** a permanent UX tax — a second signature, a second gas payment and a new abandonment point — on **every** exit, to fix a case that has occurred 0 times in 111 exits. It also breaks the current payload shape, where `value` is the user's full gross and the fee is taken inside the contract (§5.1, lines 146–158), and it makes fee collection best-effort rather than atomic.

**C. Waive the exit fee entirely**, removing the wrapper from the path. **Rejected:** trades revenue for engineering convenience. The wrapper exists to collect 75 bps (§3.3, §4 live `feeRate() = 75`); deleting the product to avoid writing a 40-line passthrough is not a trade worth making.

---

## Consequences

**Positive**

- The refund path becomes reachable by end users for the first time (§7-C3 is closed for v2-era exits).
- Recovery survives loss of every Kastle key (§7).
- kastle-mobile's refund UI stops being built on a false assumption (§7-C3) and gains a truthful `claimRefundFor` simulation (§9).
- Exit history becomes reconstructible from chain rather than from a device-local, nullable-by-design record (§9, §5.2).
- Unsolicited inflows become visible instead of silent (§3.6 → `NativeReceived`).

**Negative / accepted**

- **Gas on the hot path:** every `bridgeToL1` pays one extra `STATICCALL` plus one cold `SSTORE` (~20 000 gas) plus one event, forever, to insure an event that has never occurred in 129 exits (*Open Questions*, item 6).
- **Unbounded storage growth:** one slot per exit, never cleared (§1).
- **A permanent ungated money-moving path.** `claimRefundFor` / `claimRefundTo` are the entire crypto surface of this change and must clear the full human review gate. Its safety rests on exactly two properties: the payout target is read from a mapping no admin can write, and the forwarded amount is bounded by the balance delta of the upstream call.
- **v1-era exits gain nothing, ever** (§6).
- **Coordinated release required:** contract deploy → `DEPLOYMENTS.md` → kastle-mobile constant + `exitVia` tag + `exit-state.ts` routing → admin-ui. Between deploy and app release, v2's mapping is unused.
- **An originator that can neither receive value nor execute** — a lost-key EOA, or a contract with no reachable call path — leaves an intact but permanently unclaimable exit. `claimRefundTo` (§2) closes the can-execute-but-cannot-receive case; nothing closes this one, and no ops mechanism exists for it.
- **Force-refund inflow remains a manual, human-detected event** (§5).

**CI — the evidence pack contradicts the briefing here.** `kat-igra-bridge` **does have CI**: `.github/workflows/kat-igra-bridge.yml` runs `forge fmt --check`, `forge build --sizes` and `forge test -vvv` on push and PR filtered to `kat-igra-bridge/**` (§7-C1). Because the trigger is a path filter, **a v2 file added under `kat-igra-bridge/` is covered automatically**, and `test/FeeCollector.t.sol`'s 34 tests already run on every touch. The pack states it plainly: *"The implementation session does not need to run these manually."* Two caveats carried forward:

- Two untracked duplicate workflow files, `"kat-igra-bridge 2.yml"` and `"kat-igra-krc20 2.yml"` (macOS copy names), sit in `.github/workflows/`. Untracked, so they do not run — but committing them would double every job. **Clean them before v2 work starts** (§7-C1).
- CI runs `forge test`; it does not run a deployment or verify anything on chain. Deploy-time verification stays a human step.

---

## Deployment gates

1. **Leo approves this ADR** and it is published to the wiki's Decisions folder as ADR-007 (§6).
2. **Ashton's sanity-check** on the trigger-scenario framing and on `claimRefundFor` against KasBridge as deployed.
3. **Full crypto-surface human gates** on the money path — `claimRefundFor`, the balance-delta measurement, `receive()`, and the mapping write.
4. **Deploy script corrected and the constructor argument verified on chain.** `kat-igra-bridge/script/DeployFeeCollector.s.sol` documents the deployment env in its header comment, and **line 17 still names `BRIDGE=0x4bb88C213d3eD9dc4bae694f1bc1bF745903b2d0`** — Igra's permissionless `KasExitBridge`, per wiki ADR-002 (2026-07-27), **not** KAT's custodial `KasBridge` `0xb82c5524…` that the live collector actually uses (§4, live `bridge()` read). On this branch line 18 immediately re-assigns `BRIDGE=0xb82c5524c5b5c055efb2F8f4AbCcE3173c504f2d`, so a shell taking the last assignment gets the right value — but a copy-paste that stops at line 17, or any reader trusting the first address they see, deploys against the wrong bridge. Under ADR-002 (§8) `bridge` is `immutable`, so that mistake is **unrecoverable**: the collector would forward user funds into a contract that never placed the exit, with no setter and no upgrade path. A separate PR correcting the script is in flight and this may already be resolved; the evidence pack verified the live `bridge()` value (§4), **not** the script line, so the state of the script must be checked rather than assumed. Two things gate the deploy:
   - the script's example block names `0xb82c5524…` and **only** `0xb82c5524…`; and
   - immediately after deploy and **before anything routes through v2**, read `bridge()` from the new address on Igra Mainnet and confirm it equals `0xb82c5524c5b5c055efb2F8f4AbCcE3173c504f2d` byte for byte.
5. **CI green** on the `kat-igra-bridge` workflow, including the existing 34 tests (§7-C1), with v2's own tests added under `kat-igra-bridge/`.
6. **Duplicate workflow files removed** (§7-C1).
7. **kastle-mobile change staged and reviewed** — constant flip, `exitVia` tag, `exit-state.ts` routing, **and the API-row era derivation of §6** — so the app release can follow the deploy without a gap.
8. **`DEPLOYMENTS.md` updated** with the v2 row and the v1 retirement, and the v1 drain executed.

---

## Open Questions & Uncited Assumptions

Everything here is **not** sourced from `docs/specs/kasbridge-evidence.md`. None of it is load-bearing for the design; each is recorded so it can be confirmed rather than assumed. Items 1, 2 and 6 were open in the first draft and are now **closed** — sources and scan results below.

1. **CLOSED — sourced.** *"Relayers acknowledge without checking L1 liquidity. `acknowledgeExit` only requires a valid exit + relayer quorum. No vault balance check."* — **Ashton, 2026-08-17**, verbatim. This is the whole of the *Context* framing and it is now attributed, though still to a person rather than to read code; the pack independently supplies the code consequence (§1.4, line 394: once `acknowledged` is set, `claimRefund` is dead forever).
2. **CLOSED — sourced and independently reproduced.** The 111-exits / 0-refunds census comes from **`withdraw-gate-findings.md` (2026-08-18)**, a complete census over blocks 7.17M→14.42M that did scan for refund events. It is uncommitted in the kastle-mobile working tree, which is why the evidence-pack session could not find it. Independently reproduced for this ADR by log scan (see item 6): **129** `LockForExit` events with `topic2 = 0x9d01E8a2…` over blocks 7 000 000→14 745 955, versus the census's 111 over the shorter range ending at 14.42M — consistent, the difference being exits placed since the census cutoff. Refunds over the full range: **zero** (item 6).
3. **ADR house style.** §6 describes what ADR-001…ADR-006 *require of v2*, never their format or template. The Status/Context/Decision/Alternatives/Consequences shape used here is an assumption; reformat on publication if the Notion pages differ.
4. **"Four undecided orphan deployments"** in the wiki, cited as precedent in §6. From the briefing; the pack does not mention them.
5. **EVM gas constants** (cold zero→non-zero `SSTORE` = 20 000 gas). General EVM cost schedule, not a fact from the pack. Real cost should be measured with `forge test --gas-report` during implementation.
6. **CLOSED — no. `proposeForceRefundExit` has never fired for our collector, and neither has `claimRefund`.** Log scan run for this ADR against `https://rpc.igralabs.com:8545`, contract `0xb82c5524…`, blocks **7 000 000 → 14 745 955**, in 100 000-block chunks with full coverage of the range (our collector's first exit was block 7 171 049 per §3b, so nothing earlier can concern it):

   | Event | topic0 | Hits on the whole bridge | Hits with `sender = 0x9d01E8a2…` |
   |---|---|---|---|
   | `ExitRefunded(uint256,address,uint256)` | `0x947299f0…a7cafd` | **2** — blocks 8 988 521 and 9 244 459, both `sender = 0x72de148e0cd86701e66e3f478eb72f5a36cfd142` | **0** |
   | `ExitForceRefunded(uint256,address,uint256)` | `0x6d583605…4e12630` | **5**, all `sender = 0x9807f7b5762a1336e569da3b8afe9403533fe228` | **0** |
   | `LockForExit(...)` with `topic2 = 0x9d01E8a2…` | `0x19cadda9…a30ee70` | — | **129** |

   Both refund events index `sender` as `topic2` (§1.2, lines 170 and 174), which is what makes the filter exact. **Consequence: no user's refund is sitting in v1's balance, and none was swept in the 2 274.96 iKAS drain of §3b. The v1 drain step of §6 is unchanged.** The 129-to-0 figures also make the *Context* claim — the refund path has never once opened for our users — a scanned fact rather than a briefing figure.
7. **Does the KAT `/bridge-history` API row expose the L2 transaction hash?** The §6 era derivation joins API rows to `ExitRegistered` logs on that hash. The briefing (2026-08-20) states the rows carry no `exitId` and no `exitVia`; it does not say whether a tx hash is present. If it is absent, the join degrades to user + block + amount, which is not guaranteed unique. Confirm against the parallel Activity session's implementation.
8. **Smart-contract and hardware wallet support on Kastle's roadmap** (briefing, 2026-08-20) — timeline and shape unknown. §1's two-argument `bridgeToL1` is sized for the intermediary case that roadmap implies, not for a specification anyone has read.
9. **Can `IgraExitRecord` take a new `exitVia` field cheaply?** §5.2 quotes the type but says nothing about migration of existing device-local records. Assumed: absent `exitVia` reads as `"v1"`.
10. **Whether `owner` and `withdrawer` EOAs are separately held**, and by whom. §4 gives addresses and confirms they are distinct; custody is not documented in the pack. Relevant to the ADR-003 multisig item, not to v2's correctness.
11. **Whether KasBridge ever sends value to us for any reason other than the two refund paths.** The pack documents `claimRefund` (§1.4) and force-refund (§1.5); it does not claim the enumeration is exhaustive. `receive()` accepts unconditionally regardless, so this is not load-bearing.
12. **Admin-ui's exact coupling to the collector address.** §6 mentions admin-ui as part of a migration; the pack read `kastle-mobile` but not admin-ui's wiring. Scope the change during implementation.
