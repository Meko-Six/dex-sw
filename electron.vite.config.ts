import { defineConfig } from 'electron-vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  main: {
    build: {
      sourcemap: true
    }
  },
  preload: {
    build: {
      sourcemap: true
    }
  },
  renderer: {
    plugins: [react(), {
      name: 'dex-production-csp',
      apply: 'build',
      transformIndexHtml: (html) => html.replace('<head>', `<head><meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' blob: 'wasm-unsafe-eval'; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; media-src 'self' blob:; object-src 'none'; base-uri 'none'; frame-src 'none'">`)
    }],
    worker: {
      format: 'es'
    },
    // signalsmith-stretch stringifies its emscripten module into an AudioWorklet
    // blob; esbuild's class-field helpers are module-scoped and would be lost.
    esbuild: { target: 'esnext' },
    optimizeDeps: { exclude: ['signalsmith-stretch'] },
    build: {
      sourcemap: true,
      target: 'esnext'
    }
  }
})
