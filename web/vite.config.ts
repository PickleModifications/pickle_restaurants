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
    rollupOptions: {
      // TWO html entries emitted in ONE pass (so emptyOutDir stays safe):
      //   index.html → the in-world NUI / DUIs (App / KioskDui / RegisterDui)
      //   phone.html → the lb-phone companion app (served as nui/phone.html)
      input: {
        main: path.resolve(__dirname, "index.html"),
        phone: path.resolve(__dirname, "phone.html"),
      },
    },
  },
  resolve: {
    alias: { "@": path.resolve(__dirname, "./src") },
  },
});
