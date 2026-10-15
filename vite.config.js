import { defineConfig } from 'vite';

// Tauri builds use relative assets by default. GitHub Pages supplies VITE_BASE
// so the same frontend also works from the repository's Pages subpath.
export default defineConfig({
  base: process.env.VITE_BASE || './',
});
