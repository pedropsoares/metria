import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

const rendererRoot = fileURLToPath(new URL("./src/renderer", import.meta.url));

export default defineConfig({
  root: rendererRoot,
  base: "./",
  plugins: [react(), tailwindcss()],
  build: {
    outDir: fileURLToPath(new URL("./dist/renderer", import.meta.url)),
    emptyOutDir: true,
    rollupOptions: {
      input: {
        index: fileURLToPath(new URL("./src/renderer/index.html", import.meta.url)),
        widget: fileURLToPath(new URL("./src/renderer/widget.html", import.meta.url)),
        card: fileURLToPath(new URL("./src/renderer/card.html", import.meta.url))
      }
    }
  }
});
