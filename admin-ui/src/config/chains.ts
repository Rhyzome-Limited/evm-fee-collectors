import { defineChain } from "viem";

export const kasplexMainnet = defineChain({
  id: 202_555,
  name: "Kasplex",
  nativeCurrency: { decimals: 18, name: "Bridged KAS", symbol: "KAS" },
  rpcUrls: { default: { http: ["https://evmrpc.kasplex.org"] } },
  blockExplorers: {
    default: { name: "Kasplex Explorer", url: "https://explorer.kasplex.org" },
  },
});

export const igraMainnet = defineChain({
  id: 38_833,
  name: "IGRA",
  nativeCurrency: { decimals: 18, name: "iKAS", symbol: "iKAS" },
  rpcUrls: { default: { http: ["https://rpc.igralabs.com:8545"] } },
  blockExplorers: {
    default: { name: "IGRA Explorer", url: "https://explorer.igralabs.com" },
  },
});

export const CHAIN_NAMES: Record<number, string> = {
  [kasplexMainnet.id]: "Kasplex",
  [igraMainnet.id]: "IGRA",
};
