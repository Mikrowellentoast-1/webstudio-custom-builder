# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

RUN echo ">>> APK ADD" && apk add --no-cache git python3 make g++ curl && echo "<<< APK DONE"
RUN echo ">>> COREPACK" && corepack enable && corepack prepare pnpm@9.14.4 --activate && echo "<<< COREPACK DONE"

WORKDIR /build
RUN echo ">>> GIT CLONE" && git clone --depth=1 https://github.com/webstudio-community/webstudio-fork.git . && echo "<<< GIT CLONE DONE"

ENV NODE_OPTIONS=--max-old-space-size=6144

# Step 1: Install with original stub — avoids dep-version conflicts
RUN echo ">>> PNPM INSTALL" && pnpm install --frozen-lockfile && echo "<<< PNPM INSTALL DONE"

# Step 2: Patch animation package AFTER install.
# Strip "webstudio" conditions (point to TS source we don't have) so Vite
# uses the "import" condition → ./lib/components.js (compiled ESM from npm).
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
        console.log('Patched. exports:', JSON.stringify(stub.exports['.'], null, 2)); \
    " \
    && rm -rf /tmp/package /tmp/animation.tgz

# Verify lib files are present
RUN ls packages/sdk-components-animation/lib/

# Debug: show animation lib state before build
RUN echo "=== animation lib first 3 lines ===" \
    && head -3 packages/sdk-components-animation/lib/components.js \
    && echo "=== patched exports ===" \
    && node -e "const p=JSON.parse(require('fs').readFileSync('packages/sdk-components-animation/package.json')); console.log('type:', p.type, '| exports[.]:', JSON.stringify(p.exports['.']))"

# Step 3: Build ONLY the builder — NOT its workspace deps.
# Run silently, save exit code, then cat the log so the error appears at the
# BOTTOM of the Docker layer output (last lines visible in any GHA screenshot).
RUN sh -c ' \
    pnpm --filter=@webstudio-is/builder build > /tmp/build.log 2>&1; \
    RC=$?; \
    echo "=== BUILD OUTPUT (exit $RC) ==="; \
    cat /tmp/build.log; \
    echo "=== END BUILD OUTPUT ==="; \
    exit $RC \
'

# Step 4: Fail loudly if animation code didn't make it into the bundle
RUN grep -rl 'AnimationGroup\|wsAnimation\|animationGroup' /build/apps/builder/build/client/assets/ \
    | grep -q . \
    || (echo "ERROR: Animation code not found in bundle — patch failed" && exit 1)

# ── Stage 2: Production ───────────────────────────────────────────────────────
FROM ghcr.io/webstudio-community/builder:latest
COPY --from=builder /build/apps/builder/build /app/build
