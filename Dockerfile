# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

RUN apk add --no-cache git python3 make g++ curl
RUN corepack enable && corepack prepare pnpm@9.14.4 --activate

WORKDIR /build
RUN git clone --depth=1 https://github.com/webstudio-community/webstudio-fork.git .

ENV NODE_OPTIONS=--max-old-space-size=6144

# Step 1: Install with the original empty stub — no dep-version conflicts
RUN pnpm install --frozen-lockfile

# Step 2: AFTER install, patch animation stub with real compiled code.
#
# The npm package exports have "webstudio" conditions pointing to TypeScript
# source files (./src/*.ts) which we don't have. We strip those conditions so
# Vite falls through to "import: ./lib/components.js" (the compiled ESM).
RUN curl -fsSL \
    "https://registry.npmjs.org/@webstudio-is/sdk-components-animation/-/sdk-components-animation-0.267.0.tgz" \
    -o /tmp/animation.tgz \
    && tar xzf /tmp/animation.tgz -C /tmp \
    && cp -r /tmp/package/lib packages/sdk-components-animation/ \
    && node -e " \
        const fs = require('fs'); \
        const stub = JSON.parse(fs.readFileSync('packages/sdk-components-animation/package.json')); \
        const npm  = JSON.parse(fs.readFileSync('/tmp/package/package.json')); \
        if (npm.exports) { \
            const clean = {}; \
            for (const [k, v] of Object.entries(npm.exports)) { \
                if (typeof v === 'object') { \
                    const c = {...v}; \
                    delete c['webstudio']; \
                    delete c['webstudio-private']; \
                    clean[k] = c; \
                } else { clean[k] = v; } \
            } \
            stub.exports = clean; \
        } \
        if (npm.main)  stub.main  = npm.main; \
        if (npm.types) stub.types = npm.types; \
        fs.writeFileSync('packages/sdk-components-animation/package.json', JSON.stringify(stub, null, 2)); \
        console.log('Patched exports:', JSON.stringify(stub.exports, null, 2)); \
    " \
    && rm -rf /tmp/package /tmp/animation.tgz

# Step 3: Build — Vite now resolves lib/components.js instead of missing TS source
RUN pnpm --filter=@webstudio-is/builder... build

# ── Stage 2: Production ───────────────────────────────────────────────────────
FROM ghcr.io/webstudio-community/builder:latest
COPY --from=builder /build/apps/builder/build /app/build
