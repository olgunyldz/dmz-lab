import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Demo konsolu: statik build (dist/). Arka uç yok; veriler tarayıcıda (src/bank-mock.js).
export default defineConfig({
  plugins: [react()],
  base: "./",
  build: { outDir: "dist" },
});
