import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  // GitHub Pages: https://rhyzome-limited.github.io/evm-fee-collectors/
  base: "/evm-fee-collectors/",
  server: {
    proxy: {
      // Kasplex Blockscout API  (CORS only allows explorer.kasplex.org)
      "/proxy/kasplex-api": {
        target: "https://api-explorer.kasplex.org",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/proxy\/kasplex-api/, ""),
      },
      // IGRA Blockscout API
      "/proxy/igra-api": {
        target: "https://explorer.igralabs.com",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/proxy\/igra-api/, ""),
      },
    },
  },
});
