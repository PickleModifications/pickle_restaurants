import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "path";

export default defineConfig({
  plugins: [react()],
  base: "./",
  build: {
    outDir: "../nui",
    emptyOutDir: true,
    chunkSizeWarningLimit: 2000,
  },
  resolve: {
    alias: { "@": path.resolve(__dirname, "./src") },
  },
});
