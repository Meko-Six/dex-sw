import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

/**
 * Renderer-only dev server. electron-vite builds the real app; this exists so
 * the UI (and the audio self-test) can be exercised in a plain browser, where
 * the bridge falls back to File/localStorage instead of Electron IPC.
 */
export default defineConfig({
  root: 'src/renderer',
  plugins: [react()],
  // signalsmith-stretch stringifies its emscripten module into an AudioWorklet
  // blob; esbuild's class-field helpers are module-scoped and would be lost.
  // Keep its syntax native (Chromium supports it) and skip dep pre-bundling.
  esbuild: { target: 'esnext' },
  optimizeDeps: { exclude: ['signalsmith-stretch'] },
  build: { target: 'esnext' },
  server: {
    port: 5299,
    strictPort: true,
    host: '127.0.0.1',
    headers: { 'Cache-Control': 'no-store' }
  },
  worker: {
    format: 'es'
  }
})
