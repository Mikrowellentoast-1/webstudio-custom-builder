# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

RUN apk add --no-cache git python3 make g++ curl
RUN corepack enable && corepack prepare pnpm@9.14.4 --activate

WORKDIR /build
RUN git clone --depth=1 https://github.com/webstudio-community/webstudio-fork.git .

ENV NODE_OPTIONS=--max-old-space-size=6144

# Step 1: Install with original stubs — avoids dep-version conflicts
RUN pnpm install --frozen-lockfile

# Step 1.5: Create empty lib/*.js stubs for all workspace packages that declare
# "import" → ./lib/*.js in exports but have no compiled output (community fork
# only ships TS source). Fixes Vite's externalize-deps esbuild plugin which
# fails to resolve package entries during vite.config.ts loading.
# The actual Vite build uses "webstudio" condition → TS source, not these stubs.
RUN node -e " \
    const fs = require('fs'); \
    const path = require('path'); \
    const dirs = fs.readdirSync('packages').filter(d => { \
        try { return fs.statSync(path.join('packages', d, 'package.json')).isFile(); } \
        catch (e) { return false; } \
    }); \
    let n = 0; \
    const ensureStub = (full) => { \
        if (!fs.existsSync(full)) { \
            fs.mkdirSync(path.dirname(full), { recursive: true }); \
            fs.writeFileSync(full, ''); \
            n++; \
        } \
    }; \
    const scanVal = (dir, v) => { \
        if (typeof v === 'string') { \
            if ((v.endsWith('.js') || v.endsWith('.mjs')) && v.startsWith('./lib')) \
                ensureStub(path.join('packages', dir, v.slice(2))); \
        } else if (v && typeof v === 'object') { \
            Object.values(v).forEach(x => scanVal(dir, x)); \
        } \
    }; \
    dirs.forEach(dir => { \
        try { \
            const pkg = JSON.parse(fs.readFileSync(path.join('packages', dir, 'package.json'), 'utf8')); \
            if (pkg.exports) Object.values(pkg.exports).forEach(x => scanVal(dir, x)); \
            if (pkg.main && pkg.main.startsWith('./lib')) \
                ensureStub(path.join('packages', dir, pkg.main.slice(2))); \
        } catch(e) {} \
    }); \
    console.log('lib stubs created:', n); \
"

# Step 2: Patch animation package AFTER install.
# Copy real compiled lib/ from npm v0.267.0, strip "webstudio" conditions so
# Vite uses "import" → ./lib/components.js (compiled ESM) instead of TS stub.
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
        if (npm.type)  stub.type  = npm.type; \
        fs.writeFileSync('packages/sdk-components-animation/package.json', JSON.stringify(stub, null, 2)); \
        console.log('Animation patched. exports[.]:', JSON.stringify(stub.exports['.'])); \
    " \
    && rm -rf /tmp/package /tmp/animation.tgz

# Step 3: Build ONLY the builder — NOT its workspace deps.
# Vite output is captured; stripped of pnpm wrapper so real errors are visible.
RUN sh -c ' \
    pnpm --filter=@webstudio-is/builder build > /tmp/build.log 2>&1; \
    RC=$?; \
    PNPM_LINE=$(grep -n "ERR_PNPM_RECURSIVE_RUN_FIRST_FAIL" /tmp/build.log | head -1 | cut -d: -f1); \
    echo ""; \
    echo "=== VITE OUTPUT (exit $RC) ==="; \
    if [ -n "$PNPM_LINE" ] && [ "$PNPM_LINE" -gt 1 ]; then \
        head -$((PNPM_LINE - 1)) /tmp/build.log; \
    else \
        cat /tmp/build.log; \
    fi; \
    echo "=== END VITE OUTPUT ==="; \
    exit $RC \
'

# Step 4: Fail loudly if animation code didn't make it into the bundle
RUN grep -rl 'AnimationGroup\|wsAnimation\|animationGroup' /build/apps/builder/build/client/assets/ \
    | grep -q . \
    || (echo "ERROR: Animation code not found in bundle — patch failed" && exit 1)

# ── Stage 2: Production ───────────────────────────────────────────────────────
FROM ghcr.io/webstudio-community/builder:latest
COPY --from=builder /build/apps/builder/build /app/build
