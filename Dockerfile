# syntax=docker/dockerfile:1
# Single-file build for the LazyCat package. This merges the upstream
# Dockerfile (kernel + cloud-runtime builder) with the `slim` runtime stage of
# Dockerfile.base, because the published base image
# (ghcr.io/youzini-afk/varin-runtime-slim) is not publicly pullable at the
# packaged version. Stage `slim` below is copied verbatim from
# upstream Dockerfile.base (AGPL-3.0, same project); the `kernel-builder`,
# `builder` and final runtime stages follow upstream Dockerfile, with
# `FROM ${RUNTIME_BASE_IMAGE}` replaced by `FROM slim`.

# ---------- runtime base (upstream Dockerfile.base stage `slim`) ----------
FROM oven/bun:1.3.14 AS slim
WORKDIR /home/varin/app
LABEL io.varin.image.variant="slim" io.varin.image.role="runtime-base"
ENV VARIN_IMAGE_VARIANT=slim

ARG TARGETARCH
ARG NODE_VERSION=24.15.0

ENV PATH=/usr/local/node/bin:${PATH}

# cloudflared 2026.3.0 - update digest explicitly when upgrading
COPY --from=cloudflare/cloudflared@sha256:6b599ca3e974349ead3286d178da61d291961182ec3fe9c505e1dd02c8ac31b0 /usr/local/bin/cloudflared /usr/local/bin/cloudflared

RUN set -eux; \
  apt-get update && apt-get install -y --no-install-recommends \
  bash \
  build-essential \
  ca-certificates \
  curl \
  git \
  openssh-client \
  pkg-config \
  python3 \
  wget \
  xz-utils \
  && arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
  && case "$arch" in \
    amd64|x86_64) \
      node_arch="x64"; \
      node_sha="472655581fb851559730c48763e0c9d3bc25975c59d518003fc0849d3e4ba0f6"; \
      ;; \
    arm64|aarch64) \
      node_arch="arm64"; \
      node_sha="f3d5a797b5d210ce8e2cb265544c8e482eaedcb8aa409a8b46da7e8595d0dda0"; \
      ;; \
    *) echo "Unsupported Docker target architecture: $arch" >&2; exit 1 ;; \
  esac \
  && mkdir -p /usr/local/node \
  && wget -nv -O "/tmp/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
  && echo "${node_sha}  /tmp/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" | sha256sum -c - \
  && tar -C /usr/local/node --strip-components=1 -xJf "/tmp/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
  && node --version \
  && npm --version \
  && git --version \
  && rm -rf /var/lib/apt/lists/* /tmp/node-*.tar.xz

RUN cloudflared --version

RUN mkdir -p /etc/varin && \
  printf '%s\n' '{"schema":1,"variant":"slim","installed":["node","bun","git","ssh","cloudflared","native-build","python3"],"chrome":false}' > /etc/varin/image-capabilities.json

RUN (id -u bun >/dev/null 2>&1 && userdel bun || true) \
  && (getent group bun >/dev/null 2>&1 && groupdel bun || true) \
  && groupadd -g 1000 varin \
  && useradd -u 1000 -g 1000 -m -s /bin/bash varin \
  && mkdir -p /home/varin/app \
  && chown -R varin:varin /home/varin

USER varin

ENV HOME=/home/varin
ENV NPM_CONFIG_PREFIX=/home/varin/.npm-global
ENV PATH=/home/varin/app/node_modules/.bin:${NPM_CONFIG_PREFIX}/bin:${PATH}

RUN mkdir -p /home/varin/.local /home/varin/.config/varin /home/varin/.ssh /home/varin/workspaces /home/varin/.npm-global \
  && npm config set prefix /home/varin/.npm-global

ENV NODE_ENV=production

# ---------- kernel builder (upstream Dockerfile, verbatim) ----------
FROM --platform=$BUILDPLATFORM rust:1.97.1-bookworm AS kernel-builder
WORKDIR /src
ARG BUILDARCH
ARG TARGETARCH
RUN apt-get update \
  && apt-get install -y --no-install-recommends cmake gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
  && rm -rf /var/lib/apt/lists/*
COPY package.json ./
COPY kernel ./kernel
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=private \
  --mount=type=cache,target=/src/kernel/target,sharing=private \
  set -eux; \
  case "$TARGETARCH" in \
    amd64) kernel_arch="x64"; kernel_target="x86_64-unknown-linux-gnu" ;; \
    arm64) \
      kernel_arch="arm64"; \
      kernel_target="aarch64-unknown-linux-gnu"; \
      export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="aarch64-linux-gnu-gcc"; \
      export CC_aarch64_unknown_linux_gnu="aarch64-linux-gnu-gcc"; \
      export CXX_aarch64_unknown_linux_gnu="aarch64-linux-gnu-g++"; \
      export AR_aarch64_unknown_linux_gnu="aarch64-linux-gnu-ar"; \
      ;; \
    *) echo "Unsupported Docker target architecture: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  if [ "$BUILDARCH" != "amd64" ]; then \
    echo "Varin's Linux cross-build stage requires an amd64 build runner, found $BUILDARCH" >&2; \
    exit 1; \
  fi; \
  build_identity="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json | head -n 1)"; \
  test -n "$build_identity"; \
  rustup target add "$kernel_target"; \
  VARIN_KERNEL_BUILD_IDENTITY="$build_identity" \
  VARIN_KERNEL_TARGET="$kernel_target" \
  VARIN_KERNEL_ARCH="$kernel_arch" \
  cargo build --manifest-path kernel/Cargo.toml --release --bin varin-kernel --locked --target "$kernel_target"; \
  install -D -m 0755 "kernel/target/$kernel_target/release/varin-kernel" /out/varin-kernel

# ---------- cloud-runtime builder (upstream Dockerfile, verbatim) ----------
FROM --platform=$BUILDPLATFORM oven/bun:1.3.14 AS builder
WORKDIR /app
ARG VARIN_SOURCE_REVISION
ARG TARGETARCH

COPY package.json bun.lock ./
COPY bun-patches ./bun-patches
COPY scripts/fix-deprecation.js ./scripts/fix-deprecation.js
COPY packages/application-client/package.json ./packages/application-client/package.json
COPY packages/electron/package.json ./packages/electron/package.json
COPY packages/extension-builtins/package.json ./packages/extension-builtins/package.json
COPY packages/extension-cli/package.json ./packages/extension-cli/package.json
COPY packages/extension-contract/package.json ./packages/extension-contract/package.json
COPY packages/extension-host/package.json ./packages/extension-host/package.json
COPY packages/extension-loader/package.json ./packages/extension-loader/package.json
COPY packages/extension-react/package.json ./packages/extension-react/package.json
COPY packages/extension-sdk/package.json ./packages/extension-sdk/package.json
COPY packages/extension-surface/package.json ./packages/extension-surface/package.json
COPY packages/mobile/package.json ./packages/mobile/package.json
COPY packages/protocol/package.json ./packages/protocol/package.json
COPY packages/script-runtime/package.json ./packages/script-runtime/package.json
COPY packages/settings-store/package.json ./packages/settings-store/package.json
COPY packages/ui/package.json ./packages/ui/package.json
COPY packages/web/package.json ./packages/web/package.json
RUN bun install --frozen-lockfile --ignore-scripts \
  && node ./scripts/fix-deprecation.js

COPY . .
COPY --from=kernel-builder /out/varin-kernel /tmp/varin-kernel
RUN VARIN_SOURCE_REVISION="${VARIN_SOURCE_REVISION}" \
  VARIN_KERNEL_PREBUILT=/tmp/varin-kernel \
  VARIN_TARGET_PLATFORM=linux \
  VARIN_TARGET_ARCH="${TARGETARCH}" \
  bun run build:cloud-runtime -- --output /app/artifacts/cloud-runtime --no-archive

# ---------- final runtime (upstream Dockerfile, base swapped to `slim`) ----------
FROM slim AS runtime
WORKDIR /home/varin/app
LABEL io.varin.image.role="application"

ENV HOME=/home/varin \
  NODE_ENV=production \
  VARIN_DATA_DIR=/home/varin/.config/varin \
  VARIN_WORKSPACE_ROOT=/home/varin/workspaces

COPY --from=builder --chown=varin:varin /app/artifacts/cloud-runtime/ ./
RUN --mount=type=cache,target=/home/varin/.cache/bun,uid=1000,gid=1000 \
  bun install --production --frozen-lockfile --cache-dir=/home/varin/.cache/bun

COPY --chmod=0755 scripts/docker-entrypoint.sh /usr/local/bin/varin-entrypoint

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD curl --fail --silent --show-error http://127.0.0.1:3000/health || exit 1

ENTRYPOINT ["/usr/local/bin/varin-entrypoint"]
CMD ["node", "packages/web/bin/cli.js", "serve", "--foreground"]
