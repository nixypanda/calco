import { defineConfig } from "vite";
import elmPlugin from "vite-plugin-elm";

export default defineConfig({
    plugins: [elmPlugin()],
    server: {
        host: "0.0.0.0",
        allowedHosts: true,
        port: 1234,
        strictPort: true,
        proxy: {
            "/api": {
                target: process.env.API_TARGET ?? "http://localhost:3001",
                changeOrigin: true,
            },
        },
    },
    build: {
        outDir: "dist",
    },
});
