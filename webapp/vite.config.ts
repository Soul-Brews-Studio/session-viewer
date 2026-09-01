import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// Built output goes to ../web so the Swift `serve` command keeps serving ONE directory.
// The server does not learn about a build system; it still just hands over static files.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: { outDir: '../web', emptyOutDir: true },
  server: { port: 5273 },
})
