import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Local dev proxies emulate Kong's path-based routing (/<service>/<version>/... with strip_path).
export default defineConfig({
  plugins: [react()],
  build: { outDir: "dist", sourcemap: false },
  server: {
    port: 5173,
    proxy: {
      "/orders/v1": { target: "http://localhost:8082", rewrite: (p) => p.replace(/^\/orders\/v1/, "") },
      "/catalog/v1": { target: "http://localhost:8081", rewrite: (p) => p.replace(/^\/catalog\/v1/, "") },
    },
  },
});
