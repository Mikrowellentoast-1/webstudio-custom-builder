# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

RUN apk add --no-cache git python3 make g++ curl
RUN corepack enable && corepack prepare pnpm@9.14.4 --activate

WORKDIR /build

# Clone webstudio community fork
RUN git clone --depth=1 https://github.com/webstudio-community/webstudio-fork.git .

# Fix: Replace animation stub with the real compiled npm package.
# The community fork ships an empty stub for this proprietary package.
# The compiled package is publicly available on npm and works correctly.
RUN curl -fsSL \
    "https://registry.npmjs.org/@webstudio-is/sdk-components-animation/-/sdk-components-animation-0.267.0.tgz" \
    -o /tmp/animation.tgz && \
    tar xzf /tmp/animation.tgz -C /tmp && \
    cp -r /tmp/package/. packages/sdk-components-animation/ && \
    rm -rf /tmp/package /tmp/animation.tgz

# Install all workspace dependencies
ENV NODE_OPTIONS=--max-old-space-size=6144
RUN pnpm install --no-frozen-lockfile

# Build the builder app and all its workspace dependencies
RUN pnpm --filter=@webstudio-is/builder... build

# ── Stage 2: Production ───────────────────────────────────────────────────────
# Use the community image as base to keep entrypoint, prisma, server.js intact.
# Only the Vite/Remix build output is replaced with our animation-enabled build.
FROM ghcr.io/webstudio-community/builder:latest

COPY --from=builder /build/apps/builder/build /app/build
