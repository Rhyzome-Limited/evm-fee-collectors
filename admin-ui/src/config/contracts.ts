import { kasplexMainnet, igraMainnet } from "./chains";

export type ContractType = "bridge" | "swap" | "krc20-evm-bridge";

export interface ContractConfig {
  label: string;
  address: `0x${string}`;
  chainId: number;
  type: ContractType;
  symbol: string;
  explorerUrl: string;
  apiUrl: string;
}

// ⚠️  Fill in deployed contract addresses before use
export const CONTRACTS: ContractConfig[] = [
  {
    label: "Kasplex Bridge",
    address: "0x2f15c748a51438d02347878a2a0f26bc35b5e938",
    chainId: kasplexMainnet.id,
    type: "bridge",
    symbol: "KAS",
    explorerUrl: kasplexMainnet.blockExplorers.default.url,
    apiUrl: kasplexMainnet.apiUrl,
  },
  {
    label: "Zealous Swap (Kasplex)",
    address: "0xdfa17269221ce9fdba5bbd28f209a3a23b738978",
    chainId: kasplexMainnet.id,
    type: "swap",
    symbol: "KAS",
    explorerUrl: kasplexMainnet.blockExplorers.default.url,
    apiUrl: kasplexMainnet.apiUrl,
  },
  {
    label: "KAT KRC-20 Bridge (Kasplex)",
    address: "0x642638cF9D656378b679DE02FAbCc5e4E7F1F915",
    chainId: kasplexMainnet.id,
    type: "krc20-evm-bridge",
    symbol: "KAS",
    explorerUrl: kasplexMainnet.blockExplorers.default.url,
    apiUrl: kasplexMainnet.apiUrl,
  },
  {
    label: "KAT Igra Bridge",
    address: "0x9d01E8a2f3DD0B1Fc739d32ca8d79509b501eAb8",
    chainId: igraMainnet.id,
    type: "bridge",
    symbol: "iKAS",
    explorerUrl: igraMainnet.blockExplorers.default.url,
    apiUrl: igraMainnet.apiUrl,
  },
  {
    label: "KAT Igra KRC-20 Bridge",
    address: "0x642638cF9D656378b679DE02FAbCc5e4E7F1F915",
    chainId: igraMainnet.id,
    type: "krc20-evm-bridge",
    symbol: "iKAS",
    explorerUrl: igraMainnet.blockExplorers.default.url,
    apiUrl: igraMainnet.apiUrl,
  },
  {
    label: "Zealous Swap (IGRA)",
    address: "0x2f15c748a51438d02347878a2a0f26bc35b5e938",
    chainId: igraMainnet.id,
    type: "swap",
    symbol: "iKAS",
    explorerUrl: igraMainnet.blockExplorers.default.url,
    apiUrl: igraMainnet.apiUrl,
  },
];
