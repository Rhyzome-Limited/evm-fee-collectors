import { kasplexMainnet, igraMainnet } from "./chains";

export type ContractType = "bridge" | "swap";

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
    label: "Zealous Swap (IGRA)",
    address: "0x2f15c748a51438d02347878a2a0f26bc35b5e938",
    chainId: igraMainnet.id,
    type: "swap",
    symbol: "iKAS",
    explorerUrl: igraMainnet.blockExplorers.default.url,
    apiUrl: igraMainnet.apiUrl,
  },
];
