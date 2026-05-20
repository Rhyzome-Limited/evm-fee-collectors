import { kasplexMainnet, igraMainnet } from "./chains";

export type ContractType = "bridge" | "swap";

export interface ContractConfig {
  label: string;
  address: `0x${string}`;
  chainId: number;
  type: ContractType;
  symbol: string;
  explorerUrl: string;
}

// ⚠️  Fill in deployed contract addresses before use
export const CONTRACTS: ContractConfig[] = [
  {
    label: "Kasplex Bridge",
    address: "0xaD5c913a6CDbFbEF88f9f7b4e15cA5FCF75cB295",
    chainId: kasplexMainnet.id,
    type: "bridge",
    symbol: "KAS",
    explorerUrl: kasplexMainnet.blockExplorers.default.url,
  },
  {
    label: "Igra Bridge",
    address: "0xaD5c913a6CDbFbEF88f9f7b4e15cA5FCF75cB295",
    chainId: igraMainnet.id,
    type: "bridge",
    symbol: "iKAS",
    explorerUrl: igraMainnet.blockExplorers.default.url,
  },
  {
    label: "Zealous Swap (Kasplex)",
    address: "0x1E7dbA18ca3c7C5fa7C7104a5E5CFe50fD73cc42",
    chainId: kasplexMainnet.id,
    type: "swap",
    symbol: "KAS",
    explorerUrl: kasplexMainnet.blockExplorers.default.url,
  },
  {
    label: "Zealous Swap (IGRA)",
    address: "0x1E7dbA18ca3c7C5fa7C7104a5E5CFe50fD73cc42",
    chainId: igraMainnet.id,
    type: "swap",
    symbol: "iKAS",
    explorerUrl: igraMainnet.blockExplorers.default.url,
  },
];
