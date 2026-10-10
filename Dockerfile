# MastraCode Web — local/self-hosted production image (local Docker spike).
#
# Base: Node 22 on Debian. Adds the toolchain coding agents need at runtime
# (git, gh, python3, build-essential) plus ssh for git remotes. npm deps and
# the Mastra CLI are installed from the lockfile; the image runs
# `npm run check` and `npm run build` so a broken tree fails the build.
FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl git gh openssh-client python3 build-essential \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 1) Install deps first (cache-friendly layer) from the npm lockfile. This
#    retains the Mastra CLI (`mastra`) used by both `npm run build` and
#    `mastra start` below.
COPY package.json package-lock.json pnpm-workspace.yaml ./
RUN npm ci --no-audit --no-fund

# 2) Copy source (owned by the runtime user so no recursive chown is needed
#    later) and gate the image on typecheck + Mastra build.
COPY --chown=node:node . .
RUN npm run check && npm run build

# Runtime layout:
#   HOME          -> /home/node       (bind-mounted ./state/home by compose)
#   sandbox root  -> /sandboxes       (bind-mounted ./state/sandboxes)
# Both are owned by the non-root `node` user (uid 1000). Source and
# node_modules were already chowned via COPY --chown; only the writable
# `.mastra` build-output directory (plus HOME/sandboxes) needs chown here —
# a non-recursive chown of the directory itself, so build output files stay
# root-owned but readable, which is all the runtime needs.
ENV HOME=/home/node \
    NODE_ENV=production \
    PORT=4111
RUN mkdir -p /home/node /sandboxes /app/.mastra \
  && chown node:node /app/.mastra /home/node /sandboxes

USER node
EXPOSE 4111

# NOTE: package.json's `start` script is `varlock run -- mastra start`. varlock
# hard-fails ("No .env files found") when no .env file exists on disk — and in
# this image env is injected by compose (`env_file: .env.local`), never baked
# into the filesystem. So the entrypoint calls the Mastra CLI directly; env
# resolution/validation is compose's job here. See SPIKE-REPORT.md.
CMD ["node_modules/.bin/mastra", "start"]
