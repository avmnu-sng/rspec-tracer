import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';

// Produce a deterministic, committable dist/ tree.
//
// - No asset hashing: filenames stay stable so `git diff dist/` shows
//   real code changes instead of hash churn, and the drift check in
//   CI (`npm ci && npm run build && git diff --exit-code dist/`) is
//   meaningful.
// - Single-file entry points for JS + CSS so the Ruby-side reporter
//   can reference them by predictable paths.
// - Relative base so the emitted HTML opens correctly when users
//   double-click rspec_tracer_report/index.html from their filesystem
//   (no CDN, no baked-in origin).
export default defineConfig({
  plugins: [preact()],
  // Source entry lives in src/index.html; dist/ sits beside src/ at
  // the package root so the Ruby reporter can find it at a stable
  // relative path (lib/rspec_tracer/reporters/html/dist/).
  root: 'src',
  base: './',
  build: {
    outDir: '../dist',
    emptyOutDir: true,
    assetsDir: 'assets',
    cssCodeSplit: false,
    reportCompressedSize: false,
    rollupOptions: {
      output: {
        entryFileNames: 'assets/index.js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: (assetInfo) => {
          // Vite names the CSS bundle after the entry module; force
          // `assets/index.css` for a stable, review-friendly diff.
          const name = assetInfo.name || '';
          if (name.endsWith('.css')) return 'assets/index.css';
          return 'assets/[name][extname]';
        },
      },
    },
  },
});
