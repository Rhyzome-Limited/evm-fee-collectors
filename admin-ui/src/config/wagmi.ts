import { createConfig, http } from "wagmi";
import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  injectedWallet,
  metaMaskWallet,
  rabbyWallet,
  braveWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { kasplexMainnet, igraMainnet } from "./chains";

const connectors = connectorsForWallets(
  [
    {
      groupName: "Browser Wallets",
      wallets: [injectedWallet, metaMaskWallet, rabbyWallet, braveWallet],
    },
  ],
  { appName: "Fee Collector Admin", projectId: "none" },
);

export const wagmiConfig = createConfig({
  chains: [kasplexMainnet, igraMainnet],
  connectors,
  transports: {
    [kasplexMainnet.id]: http(),
    [igraMainnet.id]: http(),
  },
  ssr: false,
});
