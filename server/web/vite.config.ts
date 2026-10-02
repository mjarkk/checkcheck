import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

const apiUrl = process.env.CHECKCHECK_API_URL ?? 'http://localhost:8181'

export default defineConfig({
  plugins: [react()],
  // Dev only: production is the Go binary serving the embedded dist/, never Vite.
  server: {
    // Reachable from a phone on the LAN; Vite prints the Network URL at startup.
    host: '0.0.0.0',
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': { target: apiUrl, changeOrigin: true },
      '/mcp': { target: apiUrl, changeOrigin: true },
    },
  },
})
