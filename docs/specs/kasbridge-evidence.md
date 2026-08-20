# KasBridge / kat-igra-bridge FeeCollector — Evidence Pack

**Purpose.** Input to a later contract-design session for FeeCollector v2 on `kat-igra-bridge`.
This document contains only verified, quoted facts. No design, no recommendations.

**Built:** 2026-08-20. Branch `design/fee-collector-v2`, repo `Rhyzome-Limited/evm-fee-collectors`.

**Sources actually read**
| Source | How read |
|---|---|
| KasBridge `0xb82c5524c5b5c055efb2F8f4AbCcE3173c504f2d` | Blockscout verified source, `explorer.igralabs.com/api/v2/smart-contracts/…` → `/tmp/KasBridge.sol`, 1047 lines, compiler `v0.8.30+commit.73712a01`, `proxy_type: None`, `implementations: []`, single source file |
| `kat-igra-bridge/src/FeeCollector.sol` | read whole (166 lines) |
| Live chain | Igra Mainnet RPC `https://rpc.igralabs.com:8545`, chainId 38833, reads at block **14732471** |
| `kastle-mobile` | `lib/bridge/fee-collector.ts`, `hooks/bridge/useKatIgraToKasBridge.ts`, `lib/activity/exit-state.ts` (read-only) |
| ADRs | briefing only (Notion; not read this session, per instruction) |

**Headline answers** (detail in the sections below)

1. **exitId synchronously obtainable by a contract caller: YES** — via the public `exitCounter` getter. Not via a return value.
2. **Fee custody at refund time: NOT GUARANTEED.** Proven on chain: `withdrawAllNative` drained the contract to zero at block 13915637 while 4 FeeCollector-routed exits were still inside their refund window.
3. **Live roles: no drift** from the 2026-07-28 briefing values.
4. **kat-igra-bridge DOES have CI** — the briefing is stale on this point.

---

## 1. KAT KasBridge — verbatim quotes

Contract header and the immutables `lockForExit` depends on:

```solidity
30|contract KasBridge is ReentrancyGuard {
34|    uint256 public immutable MIN_PERCENT_BPS;
35|    uint256 public immutable MAX_PERCENT_BPS;
36|    uint256 public immutable MIN_FEE_FLOOR;
37|    uint256 public immutable MIN_EXIT_AMOUNT;
38|    uint256 public immutable MIN_ENTRY_AMOUNT;
39|    uint256 public immutable REFUND_BLOCK_DELAY;
41|    /// @dev Hard upper bound on the user-supplied `kaspaAddress` byte length
42|    ///      in `lockForExit`. Real Kaspa bech32 addresses are ~63 chars.
43|    uint256 public constant MAX_KASPA_ADDRESS_LENGTH = 100;
59|    uint256 public feePercentBps;
60|    uint256 public maxExitAmount;
61|    uint256 public rollingExitCap;
62|    uint256 public rollingWindowDuration;
63|    bool public paused;
64|    bool public bridgeDisabled;
```

`REFUND_BLOCK_DELAY` is `immutable`, set once in the constructor:

```solidity
320|        REFUND_BLOCK_DELAY = _refundBlockDelay;
```

**Live values read at block 14732471:**

| Field | Live value |
|---|---|
| `REFUND_BLOCK_DELAY()` | `172800` blocks (≈48 h at 1 blk/s) |
| `MAX_KASPA_ADDRESS_LENGTH()` | `100` |
| `feePercentBps()` | `10` (0.10 %) |
| `MIN_FEE_FLOOR()` | `10000000000000000000` (10 iKAS) |
| `MIN_EXIT_AMOUNT()` | `1000000000000000000` (1 iKAS) |
| `maxExitAmount()` | `20000000000000000000000` (20 000 iKAS) |
| `rollingExitCap()` | `200000000000000000000000` (200 000 iKAS) |
| `rollingWindowDuration()` | `86400` blocks |
| `exitCounter()` | `1517` |
| `paused()` / `bridgeDisabled()` | `false` / `false` |

*Meaning for a contract caller:* `REFUND_BLOCK_DELAY` cannot be changed by governance — it is `immutable`. The refund window is fixed at 172 800 blocks for every exit, past and future. The upstream fee is `max(net × 10 bps, 10 iKAS)` (see `_computeFee`, §1.6), so on small exits the flat 10 iKAS floor dominates and the effective upstream rate is far above 0.10 %.

### 1.1 The exit struct and the mapping that stores it

```solidity
84|    struct Exit {
85|        address sender;
86|        uint256 grossAmount;
87|        uint256 fee;
88|        uint256 netAmount;
89|        bytes   kaspaAddress;
90|        uint256 blockNumber;
91|        bool    acknowledged;
92|        bool    processed;
93|        bool    refunded;
94|        bytes32 kaspaTxHash;
95|    }
96|
97|    mapping(uint256 => Exit) public exits;
```

And the counter that indexes it:

```solidity
78|    uint256 public exitCounter;
```

*Meaning for a contract caller:* `sender` is the **immediate `msg.sender` of `lockForExit`** — for our architecture that is the FeeCollector, never the end user. `grossAmount` is the value the FeeCollector forwarded (already net of our fee), so KasBridge's notion of "gross" is our "net". The struct records no user-supplied reference, memo, or originator field: there is **no slot in which a wrapper can stamp the real user**. `exits` is `public`, so a wrapper can read any exit's state at any time; note the auto-generated getter omits the dynamic `kaspaAddress` member. `exitCounter` is `public` and monotonic — this is the mechanism in §2.

### 1.2 `LockForExit` event definition

```solidity
160|    event LockForExit(
161|        uint256 indexed exitId,
162|        address indexed sender,
163|        uint256 grossAmount,
164|        uint256 fee,
165|        uint256 netAmount,
166|        bytes   kaspaAddress
167|    );
```

> Topic layout, which is what matters:
> `topic0 = keccak256("LockForExit(uint256,address,uint256,uint256,uint256,bytes)") = 0x19cadda9a1afc0ed8687f9c3a42c05d0880ca38b5a8acbfc3c4cad08aa30ee70`
> `topic1 = exitId`, `topic2 = sender`. `grossAmount`, `fee`, `netAmount`, `kaspaAddress` are non-indexed data.

*Meaning for a contract caller:* exactly two indexed topics after topic0. `exitId` is filterable, and `sender` is filterable — so all exits originated by a given FeeCollector are cheaply enumerable off chain by filtering `topic2 == feeCollector`. This is the filter used in §3b to prove the custody finding. A contract **cannot** read this event in its own transaction (see §2).

Related terminal events:

```solidity
170|    event ExitRefunded(uint256 indexed exitId, address indexed sender, uint256 refundAmount);
174|    event ExitForceRefunded(uint256 indexed exitId, address indexed sender, uint256 refundAmount);
```

### 1.3 `lockForExit` in full

```solidity
336|    // ── User: lock iKAS for exit ────────────────────────────────────────
337|
338|    /// @notice Lock `msg.value` iKAS to exit to a Kaspa L1 address.
339|    /// @param  kaspaAddress UTF-8 encoded destination Kaspa bech32 address.
340|    function lockForExit(bytes calldata kaspaAddress)
341|        external
342|        payable
343|        nonReentrant
344|        whenNotPaused
345|        notDisabled
346|    {
347|        require(msg.value > 0, "No iKAS sent");
348|        require(kaspaAddress.length > 0, "Empty kaspa address");
349|        require(kaspaAddress.length <= MAX_KASPA_ADDRESS_LENGTH, "Kaspa address too long");
350|        // Typed revert beats the raw arithmetic panic that `msg.value - fee`
351|        // would emit when `msg.value <= MIN_FEE_FLOOR`.
352|        require(msg.value > MIN_FEE_FLOOR, "Below minimum fee");
353|
354|        uint256 fee = _computeFee(msg.value);
355|        uint256 netAmount = msg.value - fee;
356|
357|        require(netAmount >= MIN_EXIT_AMOUNT, "Below min exit");
358|        require(netAmount <= maxExitAmount, "Exceeds max exit");
359|
360|        _resetRollingWindowIfNeeded();
361|        require(rollingExitTotal + netAmount <= rollingExitCap, "Exceeds rolling cap");
362|        rollingExitTotal += netAmount;
363|
364|        uint256 exitId = exitCounter++;
365|        exits[exitId] = Exit({
366|            sender: msg.sender,
367|            grossAmount: msg.value,
368|            fee: fee,
369|            netAmount: netAmount,
370|            kaspaAddress: kaspaAddress,
371|            blockNumber: block.number,
372|            acknowledged: false,
373|            processed: false,
374|            refunded: false,
375|            kaspaTxHash: bytes32(0)
376|        });
377|
378|        accumulatedFees += fee;
379|        pendingExitFees += fee;
380|        pendingExitNet += netAmount;
381|
382|        emit LockForExit(exitId, msg.sender, msg.value, fee, netAmount, kaspaAddress);
383|    }
384|
```

*Meaning for a contract caller:*
- **No `returns` clause on line 340–346.** The function returns nothing. A wrapper gets no `exitId` back from the call itself.
- Line 364 is a **post-increment**: `exitId` equals the value of `exitCounter` *as read immediately before the call*, and `exitCounter - 1` immediately after. This is the whole of §2.
- Line 366: `sender: msg.sender` — the wrapper is recorded as owner of the exit. Every downstream sender-gated path (`claimRefund`, both refund payouts) therefore targets the wrapper.
- Lines 347–352 and 357–361 are all revert paths the wrapper inherits. Notably line 352 (`msg.value > MIN_FEE_FLOOR`, live 10 iKAS) and line 361 (rolling cap) can revert *after* our fee has already been computed — but since our fee is only booked as a balance and the whole tx reverts atomically, a revert un-does our fee too.
- `nonReentrant` (343) is released when the call returns, so a wrapper reading `exitCounter` after the call is not blocked.
- `whenNotPaused` / `notDisabled` (344–345): a wrapper's bridge path dies whenever KasBridge is paused, with no local override.
- The only write of user-controlled data is `kaspaAddress` (370), raw calldata bytes.

### 1.4 `claimRefund` in full

```solidity
385|    // ── User: claim refund ──────────────────────────────────────────────
386|
387|    /// @notice Refund a not-yet-acknowledged exit after `REFUND_BLOCK_DELAY`.
388|    /// @dev    Always callable, even when paused/disabled, so users can
389|    ///         recover funds during emergencies. Refunds the full gross
390|    ///         amount because the L1 vault never paid out.
391|    function claimRefund(uint256 exitId) external nonReentrant {
392|        Exit storage e = exits[exitId];
393|        require(msg.sender == e.sender, "Not exit sender");
394|        require(!e.acknowledged, "Already acknowledged");
395|        require(!e.refunded, "Already refunded");
396|        require(!e.processed, "Already processed");
397|        require(block.number >= e.blockNumber + REFUND_BLOCK_DELAY, "Too early");
398|
399|        e.refunded = true;
400|
401|        accumulatedFees -= e.fee;
402|        pendingExitFees -= e.fee;
403|        pendingExitNet -= e.netAmount;
404|
405|        _resetRollingWindowIfNeeded();
406|        if (e.blockNumber >= rollingWindowStart && rollingExitTotal >= e.netAmount) {
407|            rollingExitTotal -= e.netAmount;
408|        }
409|
410|        uint256 refundAmount = e.grossAmount;
411|
412|        (bool sent, ) = payable(msg.sender).call{value: refundAmount}("");
413|        require(sent, "Refund transfer failed");
414|
415|        emit ExitRefunded(exitId, msg.sender, refundAmount);
416|    }
```

*Meaning for a contract caller:*
- **Line 393 is a hard sender gate.** Only the address recorded at `lockForExit` time can claim. With a wrapper in the path, **only the wrapper can ever call `claimRefund`** for wrapper-routed exits. An end user calling it directly reverts with `"Not exit sender"`.
- **Line 412 pays `msg.sender`, not `e.sender`.** Because line 393 forces them equal, the payout lands at the wrapper's address. The wrapper therefore needs a `receive()` (ours has one — §3) or the refund reverts on line 413.
- **Line 410: the refund is `grossAmount`, i.e. KasBridge refunds its own fee too.** For our path that means the wrapper gets back exactly what the wrapper forwarded — our fee is not part of this number and is not returned by KasBridge.
- Line 394 makes the window one-sided: once a relayer acknowledges, `claimRefund` is dead forever and only the admin-quorum path (§1.5) remains.
- Line 397 with the fixed 172 800-block delay is the earliest a refund can be taken.
- The refund arrives as an **untagged native transfer**. Nothing in the call tells the wrapper which exit it belongs to except the wrapper's own bookkeeping and the `exitId` argument it passed.

### 1.5 `proposeForceRefundExit` — requires and payout target

```solidity
633|    /// @notice Propose force-refunding an exit that is already acknowledged
634|    ///         but cannot be processed (e.g. stalled L1 payout). Pays the
635|    ///         full gross amount back to the original sender.
636|    /// @dev    Recovery path for the otherwise-irreversible ack state.
637|    ///         Reverts if the exit is already processed or refunded.
638|    function proposeForceRefundExit(uint256 exitId) external onlyAdmin returns (uint256) {
639|        Exit storage e = exits[exitId];
640|        require(e.sender != address(0), "Exit does not exist");
641|        require(e.acknowledged, "Not acknowledged");
642|        require(!e.processed, "Already processed");
643|        require(!e.refunded, "Already refunded");
644|        return _createProposal(ProposalType.FORCE_REFUND_EXIT, address(0), exitId);
645|    }
```

The payout itself happens in the `FORCE_REFUND_EXIT` branch of `_executeProposal`:

```solidity
 978|            } else if (t == ProposalType.FORCE_REFUND_EXIT) {
 979|                // `p.amount` carries the exitId. Refund only if the exit is
 980|                // still in the acknowledged-but-unprocessed state. All checks
 981|                // re-evaluated at execute time because an honest `markExitProcessed`
 982|                // could have landed between propose and execute.
 983|                uint256 exitId = p.amount;
 984|                Exit storage e = exits[exitId];
 985|                if (e.sender == address(0) || !e.acknowledged || e.processed || e.refunded) {
 986|                    success = false;
 987|                } else {
 988|                    e.refunded = true;
 990|                    accumulatedFees -= e.fee;
 991|                    pendingExitFees -= e.fee;
 992|                    pendingExitNet -= e.netAmount;
 994|                    _resetRollingWindowIfNeeded();
 995|                    if (e.blockNumber >= rollingWindowStart && rollingExitTotal >= e.netAmount) {
 996|                        rollingExitTotal -= e.netAmount;
 997|                    }
 999|                    uint256 refundAmount = e.grossAmount;
1000|                    address payable to = payable(e.sender);
1002|                    (bool sent, ) = to.call{value: refundAmount}("");
1003|                    if (sent) {
1004|                        emit ExitForceRefunded(exitId, e.sender, refundAmount);
1005|                    } else {
1006|                        // Roll back accounting if the refund send fails so the
1007|                        // proposal can be re-targeted (e.g. user contract is
1008|                        // un-payable; admins can pause or work around).
1009|                        e.refunded = false;
1010|                        accumulatedFees += e.fee;
```

Triggered by admin quorum:

```solidity
670|        if (p.votesFor >= minimumAdminVotes) {
671|            _executeProposal(proposalId);
672|        }
```

*Meaning for a contract caller:* this is the **only** recovery route once an exit is acknowledged, it is `onlyAdmin` (KAT's admins, not ours), and **line 1000 sends to `e.sender` — the wrapper**, same as `claimRefund`. Line 1002 uses a bare `.call` and line 1005–1010 explicitly roll back if the recipient is un-payable, with the comment naming a contract recipient as the anticipated failure. A wrapper with no `receive()` would be permanently unrefundable by either path. `refundAmount` is again `grossAmount` — what the wrapper forwarded, excluding our fee.

### 1.6 `_computeFee` (upstream fee formula the wrapper's net is subject to)

```solidity
1023|    function _computeFee(uint256 amount) internal view returns (uint256) {
1024|        uint256 percentFee = (amount * feePercentBps) / 10_000;
1025|        return percentFee > MIN_FEE_FLOOR ? percentFee : MIN_FEE_FLOOR;
1026|    }
```

*Meaning for a contract caller:* upstream fee is `max(net × feePercentBps / 10000, MIN_FEE_FLOOR)`. `feePercentBps` is governance-mutable (`SET_FEE_PERCENT` proposal); `MIN_FEE_FLOOR` is immutable at 10 iKAS. A wrapper cannot predict the upstream fee from a constant — it must read `feePercentBps` live.

---

## 2. THE EXITID QUESTION

### ANSWER: **YES** — synchronously obtainable, in the same transaction.

**Mechanism: the public `exitCounter` getter (line 78), combined with the post-increment on line 364.**

```solidity
 78|    uint256 public exitCounter;
364|        uint256 exitId = exitCounter++;
```

Because line 364 is a **post-increment**, the `exitId` assigned to this exit is exactly the value of `exitCounter` read immediately *before* the external call, and equals `exitCounter - 1` immediately *after* the call returns. Both reads are available to a contract caller:

- **Read-before:** `uint256 exitId = bridge.exitCounter();` then `bridge.lockForExit{value: net}(addr);`
- **Read-after:** `bridge.lockForExit{value: net}(addr); uint256 exitId = bridge.exitCounter() - 1;`

This is exact, not a heuristic. Within a single transaction no other transaction can interleave, and `lockForExit` carries `nonReentrant` (line 343) which forecloses a reentrant second `lockForExit` inside the same call frame. The `nonReentrant` lock is released before the call returns, so a read-after also works.

**Mechanisms evaluated and rejected:**

| Mechanism | Verdict |
|---|---|
| Return value of `lockForExit` | **Not available.** Lines 340–346 declare no `returns` clause. The function returns nothing. |
| Reading one's own emitted event in-transaction | **Impossible on the EVM.** A contract cannot read logs — its own or anyone's — during execution. There is no opcode for it. Stated here explicitly so it is not proposed later. |
| Deterministic derivation from struct fields | **Not available.** `exitId` is a plain sequence number (line 364), not a hash of any struct field. Nothing about `(sender, amount, kaspaAddress, blockNumber)` determines it. |
| `exits[]` public getter to search for a match | Possible but unnecessary and O(n); the counter is exact. |
| Public counter (`exitCounter`) | **THIS IS THE ANSWER.** |

**Consequence:** a synchronous `exitId → user` mapping write inside `bridgeToL1` is mechanically possible. The design session is **not** forced into an async or event-driven architecture on this point.

**Caveats a design must still account for** (facts, not recommendations):
- `exitCounter` is `public` but has no dedicated "counter at time of my call" semantics; the correctness of read-before/read-after rests entirely on single-transaction atomicity plus `nonReentrant`.
- Both reads cost an extra external `STATICCALL` per bridge transaction.
- The value read is only meaningful if `lockForExit` succeeds; on revert the whole transaction unwinds anyway.

---

## 3. Our `kat-igra-bridge/src/FeeCollector.sol`

166 lines total. Deployed at `0x9d01E8a2f3DD0B1Fc739d32ca8d79509b501eAb8` on IGRA Mainnet.

### 3.1 Access-control declaration

```solidity
21|contract FeeCollector {
22|    // ─── Constants ───────────────────────────────────────────────────────────
23|    uint256 public constant FEE_DENOMINATOR = 10_000;
24|    uint256 public constant MAX_FEE_RATE = 1_000; // 10% hard cap
25|
26|    // ─── State ───────────────────────────────────────────────────────────────
27|    address public owner;
28|    address public pendingOwner;
29|    address public withdrawer;
30|    uint256 public feeRate; // basis points (e.g. 75 = 0.75%)
31|    IKasBridge public immutable bridge;
```

```solidity
52|    // ─── Modifiers ───────────────────────────────────────────────────────────
53|    modifier onlyOwner() {
54|        if (msg.sender != owner) revert NotOwner();
55|        _;
56|    }
57|
58|    modifier onlyWithdrawer() {
59|        if (msg.sender != withdrawer && msg.sender != owner) revert NotWithdrawer();
60|        _;
61|    }
```

Hand-rolled, no OpenZeppelin `Ownable`, no `AccessControl`, no roles enum. `onlyWithdrawer` admits **both** `withdrawer` and `owner`. Two-step ownership handover via `pendingOwner`.

### 3.2 `bridgeToL1` in full, including the fee-taking lines

```solidity
119|    // ─── Bridge wrapper ──────────────────────────────────────────────────────
120|
121|    /// @notice Bridge iKAS from L2 to L1 KAS. Fee is deducted from `msg.value`;
122|    ///         the remainder is forwarded to the KasBridge contract.
123|    /// @param kaspaAddress  Kaspa L1 destination address (UTF-8, e.g. "kaspa:qz...").
124|    ///                      Max 100 bytes. Must start with "kaspa:".
125|    function bridgeToL1(string calldata kaspaAddress) external payable {
126|        if (msg.value == 0) revert InsufficientValue();
127|
128|        // Validate Kaspa address: non-empty, starts with "kaspa:", max 100 bytes
129|        bytes memory addrBytes = bytes(kaspaAddress);
130|        if (addrBytes.length < 7 || addrBytes.length > 100) revert InvalidAddress();
131|        if (
132|            addrBytes[0] != "k" || addrBytes[1] != "a" || addrBytes[2] != "s" || addrBytes[3] != "p"
133|                || addrBytes[4] != "a" || addrBytes[5] != ":"
134|        ) revert InvalidAddress();
135|
136|        uint256 fee = (msg.value * feeRate) / FEE_DENOMINATOR;
137|        uint256 netValue = msg.value - fee;
138|
139|        if (fee > 0) emit FeeCollected(msg.sender, fee);
140|
141|        // KasBridge.lockForExit accepts raw UTF-8 bytes directly (no hex encoding)
142|        bridge.lockForExit{value: netValue}(addrBytes);
143|    }
```

The fee-taking lines are **136–137 only**. There is no fee accounting variable — the fee is simply the portion of `msg.value` not forwarded on line 142, and it becomes indistinguishable from the rest of `address(this).balance` the instant the call returns. Line 139 emits `FeeCollected` but writes no storage. There is **no `exitId` capture, no per-user mapping, no post-call read of `exitCounter`**.

The upstream interface as our contract declares it:

```solidity
 8|interface IKasBridge {
 9|    /// @param kaspaAddress UTF-8 encoded Kaspa L1 destination address (e.g. "kaspa:qz...").
10|    function lockForExit(bytes calldata kaspaAddress) external payable;
11|}
```

Consistent with §2: our own interface declares no return value.

### 3.3 Fee-rate storage and its setter

```solidity
30|    uint256 public feeRate; // basis points (e.g. 75 = 0.75%)
```

```solidity
105|    function setFeeRate(uint256 _feeRate) external onlyOwner {
106|        if (_feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
107|        emit FeeRateSet(feeRate, _feeRate);
108|        feeRate = _feeRate;
109|    }
```

Set initially from a constructor argument:

```solidity
66|    /// @param _feeRate       Fee in basis points (75 = 0.75%, max 1000 = 10%).
68|    constructor(address _owner, address _withdrawer, uint256 _feeRate, address _bridge) {
72|        if (_feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
76|        feeRate = _feeRate;
77|        bridge = IKasBridge(_bridge);
```

Preview helper:

```solidity
114|    function calculateFee(uint256 amount) external view returns (uint256 fee, uint256 netAmount) {
115|        fee = (amount * feeRate) / FEE_DENOMINATOR;
116|        netAmount = amount - fee;
117|    }
```

### 3.4 Every owner- or withdrawer-gated function

| Function | Line | Gate |
|---|---|---|
| `transferOwnership(address)` | 86 | `onlyOwner` |
| `acceptOwnership()` | 92 | `msg.sender == pendingOwner` (explicit check, line 93) |
| `setWithdrawer(address)` | 99 | `onlyOwner` |
| `setFeeRate(uint256)` | 105 | `onlyOwner` |
| `withdrawNative(address payable,uint256)` | 147 | `onlyWithdrawer` (= withdrawer **or** owner) |
| `withdrawAllNative(address payable)` | 155 | `onlyWithdrawer` (= withdrawer **or** owner) |

```solidity
 86|    function transferOwnership(address _newOwner) external onlyOwner {
 87|        if (_newOwner == address(0)) revert ZeroAddress();
 88|        pendingOwner = _newOwner;
 89|        emit OwnershipTransferProposed(owner, _newOwner);
 90|    }
 91|
 92|    function acceptOwnership() external {
 93|        if (msg.sender != pendingOwner) revert NotPendingOwner();
 94|        emit OwnerSet(owner, msg.sender);
 95|        owner = msg.sender;
 96|        pendingOwner = address(0);
 97|    }
 98|
 99|    function setWithdrawer(address _newWithdrawer) external onlyOwner {
100|        if (_newWithdrawer == address(0)) revert ZeroAddress();
101|        emit WithdrawerSet(withdrawer, _newWithdrawer);
102|        withdrawer = _newWithdrawer;
103|    }
```

That is the **complete** privileged surface. Nothing else on the contract is gated, and there is no pause, no upgrade hook, no rescue function, no arbitrary-call escape hatch.

### 3.5 The withdrawal surface

```solidity
145|    // ─── Withdrawal ──────────────────────────────────────────────────────────
146|
147|    function withdrawNative(address payable to, uint256 amount) external onlyWithdrawer {
148|        if (to == address(0)) revert ZeroAddress();
149|        if (amount > address(this).balance) revert InsufficientBalance();
150|        (bool ok,) = to.call{value: amount}("");
151|        if (!ok) revert TransferFailed();
152|        emit NativeWithdrawn(to, amount);
153|    }
154|
155|    function withdrawAllNative(address payable to) external onlyWithdrawer {
156|        if (to == address(0)) revert ZeroAddress();
157|        uint256 bal = address(this).balance;
158|        if (bal == 0) revert InsufficientBalance();
159|        (bool ok,) = to.call{value: bal}("");
160|        if (!ok) revert TransferFailed();
161|        emit NativeWithdrawn(to, bal);
162|    }
```

### 3.6 `receive()` / `fallback()`

```solidity
164|    // ─── Receive ─────────────────────────────────────────────────────────────
165|    receive() external payable {}
166|}
```

`receive()` exists, is empty, accepts any native value from anyone, and emits nothing. There is **no `fallback()`**. A refund from KasBridge (§1.4 line 412 / §1.5 line 1002) will therefore land successfully — and silently. Nothing distinguishes an arriving refund from an arriving fee or a stray transfer.

### 3.7 Briefing claims — CONFIRMS / CONTRADICTS

| Briefing claim | Verdict | Evidence |
|---|---|---|
| Withdrawal surface is **only** `withdrawNative` and `withdrawAllNative`; no ERC-20 path | **CONFIRMS** | Lines 147, 155 are the only `withdraw*` functions in the file. Repo-wide grep: `kasplex-bridge` also has 2; `kat-igra-krc20` and `zealous-swap` have 4 each (`withdraw`, `withdrawAll`, `withdrawNative`, `withdrawAllNative`). The four-function table applies to exactly two of four projects, as the wiki said. |
| Kaspa payload forwarded as **raw UTF-8 bytes** | **CONFIRMS** | Line 129 `bytes(kaspaAddress)`, line 142 passes `addrBytes` unmodified; comment on line 141 says so explicitly. No hex encoding anywhere in the file. |
| Rejects payloads over **100 bytes** | **CONFIRMS** | Line 130 `addrBytes.length > 100` → `InvalidAddress()`. Matches upstream `MAX_KASPA_ADDRESS_LENGTH = 100` (live-read: 100), so our cap is not stricter than upstream. |
| Requires **at least 7 bytes** | **CONFIRMS** | Line 130 `addrBytes.length < 7` → `InvalidAddress()`. |
| Requires a **`"kaspa:"` prefix** | **CONFIRMS** | Lines 131–134 check bytes 0–5 are `k,a,s,p,a,:`. |
| Contract is **non-upgradeable**, upstream address **immutable** | **CONFIRMS** | Line 31 `IKasBridge public immutable bridge`, set once at line 77. No proxy, no delegatecall, no implementation slot, no initializer. Blockscout reports `proxy_type: None`, `implementations: []` for the upstream too. Live read `bridge()` = `0xb82c5524c5b5c055efb2f8f4abcce3173c504f2d`, matching the hard-coded comment on line 5. |
| **kat-igra-bridge has NO CI workflow** | **CONTRADICTS** | See §7-C1. `.github/workflows/kat-igra-bridge.yml` exists and runs `forge fmt --check`, `forge build --sizes`, `forge test -vvv` on push/PR touching `kat-igra-bridge/**`. |
| Withdrawn fees **settle to owner, not to withdrawer** | **CONTRADICTS** | See §7-C2. `to` is an unconstrained caller-supplied parameter (lines 147, 155); on chain one withdrawal settled to the *withdrawer* address. |

---

## 3b. FEE CUSTODY TIMING

### No automated sweep exists — verified

- Repo-wide grep for `cron|schedule|sweep|keeper|setInterval|worker` across `*.ts *.tsx *.js *.yml *.yaml *.sol *.toml *.sh` returns exactly one file: `admin-ui/src/config/chains.ts` (a chain-config constant; not a sweeper).
- `.github/workflows/` contains only build/test/deploy jobs (§7-C1) — none has a `schedule:` trigger.
- No Solidity in any of the four projects contains a time- or block-triggered transfer. `withdrawNative` / `withdrawAllNative` are the only value-moving paths out of the FeeCollector, both externally gated.
- The FeeCollector has no keeper hook, no `performUpkeep`, no self-call.

**Conclusion: nothing moves money on a timer. CONFIRMS the briefing.**

### At the moment a refund arrives, is that exit's fee still in the contract? — **NOT GUARANTEED. Proven otherwise on chain.**

The fee is not segregated. Line 136–137 leave it in `address(this).balance`; `withdrawAllNative` (line 157) takes `address(this).balance` in full with no reserve for in-flight exits. Contrast with upstream, which *does* segregate — `pendingExitFees` / `pendingExitNet` (lines 379–380, commented "Excluded from the withdrawable balance so any in-flight refund can always succeed"). Our contract has no equivalent.

**On-chain proof.** `NativeWithdrawn` (`topic0 = 0xc303ca808382409472acbbf899c316cf439f409f6584aae22df86dfa3c9ed504`) on `0x9d01E8a2…`, full history scanned in 100 000-block pages from genesis to block 14732471 — **4 events**:

| Block | Amount | Recipient |
|---|---|---|
| 7171049 | 0.15 iKAS | `0xC9b501CD…` (the deployer address) |
| 12243479 | 619.635 iKAS | owner `0xbBA114b1…` |
| 12840761 | 617.5 iKAS (approx.) | owner `0xbBA114b1…` |
| 13915637 | **2274.960715548375 iKAS** | withdrawer `0x4be2c073…` |

Balance around the last one, read from chain:

```
balance @ block 13915636 = 2274960715548375000000 wei
balance @ block 13915637 =                       0 wei
balance @ block 13915638 =                       0 wei
```

The contract was drained to **zero**. In the 172 800 blocks immediately preceding that drain (blocks 13742838–13915637) — i.e. the window in which an exit's refund could still have become claimable *after* the drain — **4 `LockForExit` events were emitted with `topic2 == 0x…9d01E8a2f3DD0B1Fc739d32ca8d79509b501eAb8`**, our FeeCollector. (Filter: `topic0 = 0x19cadda9…`, `topic2 = 0x0000…9d01e8a2f3dd0b1fc739d32ca8d79509b501eab8` on the KasBridge address; 4 of the 10 total `LockForExit` events in that span were ours.)

**Answer: for those 4 exits, the fee was gone before the refund window even opened.** The refund itself would still have arrived (KasBridge pays `grossAmount`, which is our forwarded net — that money comes from KasBridge's reserves, not ours), but the fee slice that a "return the fee alongside the gross" design would want to hand back was already withdrawn.

**Therefore:** returning the fee alongside the gross is **not free**. It requires either a funded float, or a segregated/reserved fee accounting that `withdrawAllNative` cannot touch — the same shape upstream already implements with `pendingExitFees`. This is a fact about the deployed contract, not a recommendation about which route to take.

---

## 4. LIVE ON-CHAIN STATE

**Address identified from `DEPLOYMENTS.md:32`** (IGRA Mainnet table, `## IGRA Mainnet (chainId: 38833)` at line 27):

```
| **KAT Igra Bridge FeeCollector** | `0x9d01E8a2f3DD0B1Fc739d32ca8d79509b501eAb8` | …
```

RPC per `DEPLOYMENTS.md:37`: `https://rpc.igralabs.com:8545`.

**Read live at block 14732471:**

| Field | Live value | Briefing (2026-07-28) | Drift |
|---|---|---|---|
| `owner()` | `0xbBA114b131c1ff6e0fEfaB1329eBFaAa5f306c94` | same | **none** |
| `pendingOwner()` | `0x0000000000000000000000000000000000000000` | zero | **none** |
| `withdrawer()` | `0x4be2c073c16494Abbe3489b953c198b393b1675A` | same | **none** |
| `feeRate()` | `75` | 75 | **none** |
| `bridge()` | `0xb82c5524c5b5c055efb2f8f4abcce3173c504f2d` | (implied) | matches the audited upstream |
| native balance | `422692500000000000000` wei = **422.6925 iKAS** | not recorded | n/a |

**No drift on any role or rate.** The briefing's chain values are still current.

Note on the deployer address `0xC9b501CD…`: it is not a live role on this contract (it is neither `owner` nor `withdrawer`), consistent with the briefing's note that it appeared in the repo as a stale deploy-time value. It does appear once in the withdrawal history at block 7171049 for 0.15 iKAS (§3b) — an early test withdrawal, before the roles settled.

**Cross-check against kastle-mobile:**

`kastle-mobile/lib/bridge/fee-collector.ts:43-45`

```ts
43|/** KAT Igra Bridge FeeCollector on IGRA Mainnet (chainId: 38833) */
44|export const KAT_IGRA_FEE_COLLECTOR_BRIDGE_ADDRESS: Address =
45|  "0x9d01E8a2f3DD0B1Fc739d32ca8d79509b501eAb8";
```

**Match — byte-for-byte, including checksum casing, with `DEPLOYMENTS.md:32` and with the address whose live state is read above.** No discrepancy; no stop condition triggered.

---

## 5. CALL-SITE FACTS from kastle-mobile

Read-only. Nothing in kastle-mobile was modified.

### 5.1 How `bridgeToL1` is called — `hooks/bridge/useKatIgraToKasBridge.ts`

Fee read (live, from our contract, 60 s refresh, hard-coded fallback of 75 bps):

```ts
 94|  const { data: feeRateBps } = useSWR(
 95|    isMainnet ? `feeRate:${igraNetwork.id}:${feeCollectorAddress}` : null,
 96|    async () => {
101|      return client.readContract({
102|        address: feeCollectorAddress,
103|        abi: FEE_COLLECTOR_BRIDGE_ABI,
104|        functionName: "feeRate",
105|      }) as Promise<bigint>;
106|    },
107|    { refreshInterval: 60_000 },
108|  );
109|
110|  const effectiveFeeRate = feeRateBps !== undefined ? Number(feeRateBps) : 75; // fallback: 75 bps
111|  const kastleFeeKas = amount * (effectiveFeeRate / 10_000);
112|  const netAmountAfterKastleFee = amount - kastleFeeKas;
```

The upstream fee is mirrored client-side, floor included:

```ts
122|  // Upstream KAT bridge fee on the net amount forwarded to lockForExit —
123|  // exact mirror of the contract's max(net × bps / 10000, MIN_FEE_FLOOR),
124|  // so the displayed net always equals the settled net.
125|  const upstreamBridgeFeeKas =
129|            computeContractFeeWei(
130|              netAmountWei,
131|              BigInt(exitConfig.feePercentBps),
132|              BigInt(exitConfig.minFeeFloor) * WEI_PER_KAS,
133|            ),
```

The transaction payload — **args, value, target**:

```ts
146|  const payload =
147|    sender && kaspaAddress && amount > 0
148|      ? {
149|          account: sender,
150|          to: feeCollectorAddress,
151|          data: encodeFunctionData({
152|            abi: FEE_COLLECTOR_BRIDGE_ABI,
153|            functionName: "bridgeToL1",
154|            args: [kaspaAddress],
155|          }),
156|          value: amountWei,
157|        }
158|      : undefined;
```

**Facts:** one argument, the Kaspa address as a `string`. `value` is the user's **full gross** `amountWei` — our fee is taken inside the contract, not netted client-side. `to` is our FeeCollector, never KasBridge. This is the definitive confirmation that exits route **user → FeeCollector → KasBridge.lockForExit**.

The ABI the app uses against our contract (`lib/bridge/fee-collector.ts:47-69`) exposes only `bridgeToL1`, `feeRate`, `owner` — the app has no knowledge of our withdrawal surface.

### 5.2 How `exitId` is derived from the `LockForExit` topic

Derivation is **post-hoc, off chain, from the transaction receipt** — `hooks/bridge/useKatIgraToKasBridge.ts:360-391`:

```ts
360|      // Persist exitId for the claimRefund backstop / exit lookup. Best-effort:
361|      // a decode or storage failure must not surface as a bridge error.
362|      try {
363|        const receipt = await ethClient.waitForTransactionReceipt({
364|          hash: txId,
365|        });
366|        const [lockEvent] = parseEventLogs({
367|          abi: IGRA_EXIT_BRIDGE_ABI,
368|          eventName: "LockForExit",
369|          logs: receipt.logs,
370|        });
371|        await appendExitRecord({
372|          exitId: lockEvent ? lockEvent.args.exitId.toString() : null,
373|          txHash: txId,
374|          netAmountWei: freshNetWei.toString(),
375|          kaspaAddress,
376|          blockNumber: receipt.blockNumber?.toString() ?? null,
377|          timestamp: Date.now(),
378|          chainId: igraNetwork.id,
382|          ...(lockEvent
383|            ? {
384|                payoutWei: lockEvent.args.netAmount.toString(),
385|                feeIkas: formatEther(amountWei - lockEvent.args.netAmount),
386|              }
387|            : {}),
388|        });
389|      } catch (e) {
390|        console.log("exit record persistence failed", e);
391|      }
```

`exitId` comes from the indexed `topic1` of `LockForExit` (viem's `parseEventLogs` decoding `args.exitId`), stored in device-local `IgraExitRecord`. It is **nullable by design** — `exit-history.ts:6-8`:

```ts
6|// feature can find the exit later. exitId is null only if event decode failed.
8|  exitId: string | null;
```

The state machine's refund logic in `lib/activity/exit-state.ts`:

```ts
10|//   - the refund window (REFUND_BLOCK_DELAY = 172,800 blocks ≈ 48 h, live-read
12|//   - an eth_call simulation of claimRefund(exitId) — the ONLY per-exit signal
13|//     the in-repo ABI allows. No getExit/status getter exists in our ABI, so
```

```ts
 62|export const REFUND_WINDOW_MS = 48 * 60 * 60 * 1000;
 90|  if (record.exitId === null) return { kind: "submitted_untracked" };
 91|  if (!isRefundWindowElapsed(record, opts.nowMs)) return { kind: "pending" };
110|  refund_claimable: ["claim_refund"],
```

```ts
138|    try {
139|      await params.client.simulateContract({
140|        address: params.bridgeAddress ?? (IGRA_EXIT_BRIDGE_MAINNET as Hex),
141|        abi: CLAIM_REFUND_ABI,
142|        functionName: "claimRefund",
143|        args: [params.exitId],
144|        account: params.account,
145|      });
146|      return "claimable";
```

```ts
183|export function buildClaimRefundTx(exitId: bigint): {
189|    to: IGRA_EXIT_BRIDGE_MAINNET as Hex,
190|    data: encodeFunctionData({
191|      abi: CLAIM_REFUND_ABI,
192|      functionName: "claimRefund",
193|      args: [exitId],
194|    }),
```

**Fact with design consequences (see §7-C3):** `params.account` on line 144 and the signer of `buildClaimRefundTx` are the **user's** address, while `to` on line 189 is **KasBridge directly**. Per §1.4 line 393 (`msg.sender == e.sender`, and `e.sender` is our FeeCollector), that simulation can only ever revert for FeeCollector-routed exits.

### 5.3 Address wiring

`lib/bridge/fee-collector.ts` — the addresses the app targets:

```ts
 6|export const KASPLEX_FEE_COLLECTOR_BRIDGE_ADDRESS: Address =
 7|  "0x2f15c748a51438d02347878a2a0f26bc35b5e938";
12|export const KAT_KRC20_FEE_COLLECTOR_ADDRESS: Address =
13|  "0x642638cF9D656378b679DE02FAbCc5e4E7F1F915";
44|export const KAT_IGRA_FEE_COLLECTOR_BRIDGE_ADDRESS: Address =
45|  "0x9d01E8a2f3DD0B1Fc739d32ca8d79509b501eAb8";
```

All three match `DEPLOYMENTS.md` lines 31–33. Cross-check verdict in §4: **agreement, no finding**.

---

## 6. CONSTRAINTS THE ADRs IMPOSE ON A V2

Source: the briefing (ADRs live as Notion pages in the wiki's Decisions folder; not read this session, and **not present in this repo** — there is no `docs/adr/`). Verification status noted where the deployed code speaks to the ADR.

| ADR | What it requires of a v2 | Code evidence in this pack |
|---|---|---|
| **ADR-002** — non-upgradeable contracts; upstream address immutable | v2 must ship as a **new deployment**, not an upgrade. No proxy, no initializer, no mutable `bridge`. Any migration is address-change + client rewiring (`kastle-mobile` constant, `DEPLOYMENTS.md`, admin-ui) plus a decision about the balance sitting in v1. | §3.7: `bridge` is `immutable` (line 31), no proxy machinery in the file; Blockscout `proxy_type: None` on the upstream. **Consistent.** |
| **ADR-003** — hand-rolled owner/withdrawer access control on a single EOA; multisig migration is the open hardening item | v2 keeps the same two-role, hand-rolled model unless ADR-003 is superseded. Note `onlyWithdrawer` admits owner too, and both withdrawal functions accept an arbitrary `to`. | §3.1 lines 53–61; §3.4 table. Live: owner and withdrawer are distinct EOAs, `pendingOwner` zero (§4). **Consistent.** |
| **ADR-004** — four independent Foundry projects, no shared library | v2 lands **inside `kat-igra-bridge/` only**. No extraction of a common base, no new shared package, even if v2 duplicates logic already in `kasplex-bridge`. | Repo-wide grep confirms four separate `src/FeeCollector.sol` files with divergent withdrawal surfaces (§3.7) and no imports between projects. **Consistent.** |
| **ADR-006** — fee rate is a deploy-time env var, mutable by the owner | v2 keeps `feeRate` as a constructor parameter, owner-settable at runtime, bounded by a hard cap. The 0.75 % value itself is owned by Kastle Wiki ADR-001, not by this repo. | §3.3: constructor param (line 68, 76), `setFeeRate` `onlyOwner` (105–109), `MAX_FEE_RATE = 1_000` (line 24). Live `feeRate() = 75`. **Consistent.** |

**The v2 ADR will be ADR-007, published as a Notion page in the wiki's Decisions folder — not a file in this repo.** Current range is ADR-001 … ADR-006. Do not create `docs/adr/` and do not invent a repo-local numbering scheme.

---

## 7. CONTRADICTIONS

### C1 — **kat-igra-bridge DOES have CI.** (contradicts the briefing)

The briefing states: *"kat-igra-bridge has NO CI workflow… Only kasplex-bridge.yml, zealous-swap.yml and deploy-admin-ui.yml exist."* Both halves are false as of today.

`.github/workflows/` actually contains **seven** files:

```
deploy-admin-ui.yml   kasplex-bridge.yml   kat-igra-bridge.yml
kat-igra-krc20.yml    zealous-swap.yml
kat-igra-bridge 2.yml (untracked)   kat-igra-krc20 2.yml (untracked)
```

`kat-igra-bridge.yml` verbatim, in the relevant part:

```yaml
name: kat-igra-bridge CI
on:
  push:
    paths:
      - "kat-igra-bridge/**"
      - ".github/workflows/kat-igra-bridge.yml"
  pull_request:
    paths:
      - "kat-igra-bridge/**"
      - ".github/workflows/kat-igra-bridge.yml"
  workflow_dispatch:
jobs:
  test:
    name: kat-igra-bridge
    …
      - name: Run Forge fmt
        run: forge fmt --check
      - name: Run Forge build
        run: forge build --sizes
      - name: Run Forge tests
        run: forge test -vvv
```

Provenance: commits `fa5ec75 ci: add kat-igra-bridge and kat-igra-krc20 workflows` and `3c84bc1 ci: give each project workflow a distinct job name for branch protection`, both landed after the wiki was built at `main@0d96049`. The briefing is simply stale here.

`kat-igra-bridge/test/FeeCollector.t.sol` contains **34** `function test…` definitions — matching the briefing's "~34 tests" — and they now **do** run automatically on any push or PR touching `kat-igra-bridge/**`. **The implementation session does not need to run these manually.** The `path` filter means a v2 file added under `kat-igra-bridge/` is covered automatically.

**Secondary finding:** two untracked duplicate workflow files, `"kat-igra-bridge 2.yml"` and `"kat-igra-krc20 2.yml"` (macOS-style copy names), sit in `.github/workflows/`. They are untracked in git, so they do not run on GitHub — but if committed they would double every job. Worth cleaning before v2 work starts.

### C2 — **Withdrawn fees do NOT necessarily settle to the owner.** (contradicts the briefing)

The briefing states: *"Withdrawn fees settle to owner, not to withdrawer."* The deployed code has no such property.

```solidity
147|    function withdrawNative(address payable to, uint256 amount) external onlyWithdrawer {
155|    function withdrawAllNative(address payable to) external onlyWithdrawer {
```

`to` is an **unconstrained caller-supplied parameter**, checked only against `address(0)` (lines 148, 156). Neither function references `owner`. Funds go wherever the caller — withdrawer **or** owner, per `onlyWithdrawer` on line 59 — names.

Confirmed on chain: of the 4 `NativeWithdrawn` events (§3b), the largest and most recent, block 13915637 for 2274.960715548375 iKAS, settled to the **withdrawer** `0x4be2c073c16494Abbe3489b953c198b393b1675A`, not the owner. Two earlier ones went to the owner; the first went to the deployer. The destination is per-call discretion, not a code-enforced invariant.

This matters for v2: any design that assumes "fees end up at owner" as a property of the contract is assuming something the contract does not enforce, and that live history has already violated.

### C3 — **The end user cannot claim a refund for a FeeCollector-routed exit, and kastle-mobile's refund path is dead for these exits.** (new finding; extends the briefing's claims rather than contradicting them)

The four previously-asserted claims all hold:

| Previously-asserted claim | Verdict | Evidence |
|---|---|---|
| Exits route user → our FeeCollector → `KasBridge.lockForExit` | **TRUE** | `useKatIgraToKasBridge.ts:150` `to: feeCollectorAddress`, `:153` `functionName: "bridgeToL1"`, `:156` `value: amountWei`; `FeeCollector.sol:142` `bridge.lockForExit{value: netValue}(addrBytes)`. Also visible on chain: 4 `LockForExit` events with `topic2` = our FeeCollector in a single 172 800-block window (§3b). |
| KasBridge records `sender = msg.sender` | **TRUE** | `KasBridge.sol:366` `sender: msg.sender`. For our path that is the FeeCollector, never the end user. |
| `claimRefund` is sender-only and pays `msg.sender` | **TRUE** | `KasBridge.sol:393` `require(msg.sender == e.sender, "Not exit sender")`; `:412` `payable(msg.sender).call{value: refundAmount}("")`. Same for the admin path: `:1000` `address payable to = payable(e.sender)`. |
| Our FeeCollector has no path to call `claimRefund` and no `exitId → user` mapping | **TRUE** | The full 166-line file is quoted in §3. `IKasBridge` (lines 8–11) declares **only** `lockForExit`. There is no `claimRefund` call, no arbitrary-call function, no mapping of any kind, and no storage write in `bridgeToL1`. The privileged surface (§3.4) contains no escape hatch. |

**The consequence these four facts compose into is worth stating plainly, because it is not in the briefing:**

For every exit ever placed through `0x9d01E8a2…`, the address entitled to a refund is the FeeCollector, and the FeeCollector has no code that can call `claimRefund`. Refunds for FeeCollector-routed exits are therefore **presently unclaimable by anyone** — not by the user, not by the owner, not by the withdrawer. The same applies to the admin force-refund path (§1.5 line 1000 pays `e.sender`).

The one mitigating fact: `receive()` exists (line 165), so *if* a refund were ever triggered the money would land in the contract and could be recovered by `withdrawAllNative`. But nothing can trigger it.

**And kastle-mobile is currently offering a refund flow built on the opposite assumption.** `exit-state.ts:140-144` simulates `claimRefund` with `address: IGRA_EXIT_BRIDGE_MAINNET` (KasBridge directly) and `account: params.account` (the user's EOA); `buildClaimRefundTx:189` would broadcast to KasBridge from the user's wallet. Per line 393 that reverts with `"Not exit sender"` for every FeeCollector-routed exit. The app classifies a revert as `"reverts"` → state `acknowledged` → `EXIT_ACTIONS.acknowledged = []`, so **no `claim_refund` action is ever offered** and no user broadcasts a doomed transaction. The failure is silent and safe, but it means the refund backstop the app advertises does not exist for these exits — and the app mislabels them as `acknowledged` when they may simply be unclaimable. The in-file comment at `exit-state.ts:20-23` already notes this state "auto-resolves on operator rebalance; claimRefund REVERTS here — production incident" without identifying the sender mismatch as the cause.

### C4 — Minor: `DEPLOYMENTS.md` describes the address cap in characters, the code enforces bytes

`DEPLOYMENTS.md:89` reads *"Kaspa address max length: **100 chars**, must start with `kaspa:`"*. The code enforces **100 bytes** (`FeeCollector.sol:130`, `bytes memory addrBytes`). Identical for ASCII bech32 addresses, divergent for any multi-byte input. Cosmetic for real Kaspa addresses (~63 ASCII chars), noted for completeness.

### Claims checked and found accurate (no contradiction)

- Four independent Foundry projects, no shared library, no inheritance between them — confirmed by grep across all four `src/` trees.
- No off-chain service: no worker, sweeper, scheduler, indexer or metrics endpoint in the repo — confirmed in §3b.
- Fees are never swept; balances sit until a manual withdrawal — confirmed in §3b (4 manual withdrawals over the contract's life, no timer anywhere).
- Live `owner`, `withdrawer`, `feeRate`, `pendingOwner` unchanged since 2026-07-28 — confirmed in §4.
- `0xC9b501CD…` is not a live role — confirmed in §4.
- `kat-igra-bridge` withdrawal surface is two functions, not four — confirmed in §3.7.
- kastle-mobile's FeeCollector address matches chain and `DEPLOYMENTS.md` — confirmed in §4.

---

## Appendix — reproducing the chain reads

```bash
RPC=https://rpc.igralabs.com:8545
A=0x9d01E8a2f3DD0B1Fc739d32ca8d79509b501eAb8   # our FeeCollector
B=0xb82c5524c5b5c055efb2F8f4AbCcE3173c504f2d   # KAT KasBridge

cast call $A 'owner()(address)'        --rpc-url $RPC
cast call $A 'pendingOwner()(address)' --rpc-url $RPC
cast call $A 'withdrawer()(address)'   --rpc-url $RPC
cast call $A 'feeRate()(uint256)'      --rpc-url $RPC
cast balance $A --rpc-url $RPC

cast call $B 'REFUND_BLOCK_DELAY()(uint256)' --rpc-url $RPC
cast call $B 'feePercentBps()(uint256)'      --rpc-url $RPC
cast call $B 'MIN_FEE_FLOOR()(uint256)'      --rpc-url $RPC
cast call $B 'exitCounter()(uint256)'        --rpc-url $RPC

# withdrawal history (RPC caps eth_getLogs at 100k blocks — page it)
cast logs --from-block N --to-block N+99999 --address $A \
  0xc303ca808382409472acbbf899c316cf439f409f6584aae22df86dfa3c9ed504 --rpc-url $RPC

# our exits only: LockForExit filtered by sender topic
cast logs --from-block N --to-block N+99999 --address $B \
  0x19cadda9a1afc0ed8687f9c3a42c05d0880ca38b5a8acbfc3c4cad08aa30ee70 \
  "" 0x0000000000000000000000009d01e8a2f3dd0b1fc739d32ca8d79509b501eab8 --rpc-url $RPC

# verified source, without pulling it into context
curl -s "https://explorer.igralabs.com/api/v2/smart-contracts/$B" -o /tmp/kasbridge.json
python3 -c "import json;print(json.load(open('/tmp/kasbridge.json'))['source_code'])" > /tmp/KasBridge.sol
```
