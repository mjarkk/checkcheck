import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

const apiUrl = process.env.CHECKCHECK_API_URL ?? 'http://localhost:8181'

export default defineConfig({
  plugins: [react()],
  // go:embed can't reach outside the Go module.
  build: { outDir: '../server/webui', emptyOutDir: true },
  // Dev only: production is the Go binary serving the embedded build, never Vite.
  server: {
    // Reachable from a phone on the LAN; Vite prints the Network URL at startup.
    host: '0.0.0.0',
    port: 5173,
    strictPort: true,
    proxy: {
      // changeOrigin points the Host header at the target, so the socket's Origin has to follow it to pass a
      // same-origin check. That opens no CSRF hole: the socket signs in with the token, not a cookie.
      '/api': { target: apiUrl, changeOrigin: true, ws: true, rewriteWsOrigin: true },
      '/mcp': { target: apiUrl, changeOrigin: true },
    },
  },
})
