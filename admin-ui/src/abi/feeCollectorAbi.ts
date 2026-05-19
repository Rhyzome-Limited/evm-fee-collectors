// Minimal ABI covering all FeeCollector variants (bridge + swap)
export const feeCollectorAbi = [
  // ─── View ──────────────────────────────────────────────────────────────────
  {
    name: "owner",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "pendingOwner",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "withdrawer",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "feeRate",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  // ─── Owner setters ─────────────────────────────────────────────────────────
  {
    name: "transferOwnership",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "_newOwner", type: "address" }],
    outputs: [],
  },
  {
    name: "acceptOwnership",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    name: "setWithdrawer",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "_newWithdrawer", type: "address" }],
    outputs: [],
  },
  {
    name: "setFeeRate",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "_feeRate", type: "uint256" }],
    outputs: [],
  },
  // ─── Native withdrawal ─────────────────────────────────────────────────────
  {
    name: "withdrawNative",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    name: "withdrawAllNative",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "to", type: "address" }],
    outputs: [],
  },
  // ─── ERC-20 withdrawal (zealous-swap only) ─────────────────────────────────
  {
    name: "withdraw",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    name: "withdrawAll",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "to", type: "address" },
    ],
    outputs: [],
  },
] as const;
