#!/bin/sh
# Check out the upstream release the embedded image is built from.
#
# The ghcr images referenced by upstream compose (varin / varin-runtime-slim)
# are not publicly pullable at v0.9.38, so this package builds the runtime
# from source and embeds it.
set -eu

VERSION="${VARIN_VERSION:-v0.9.38}"

echo "varin: fetching ${VERSION}"
rm -rf upstream
mkdir -p upstream

TARBALL="https://codeload.github.com/Youzini-afk/Varin/tar.gz/${VERSION}"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${TARBALL}" | tar -xz -C upstream --strip-components=1
else
  wget -qO- "${TARBALL}" | tar -xz -C upstream --strip-components=1
fi

# Fail loudly rather than producing an empty image from a silent 404.
test -f upstream/package.json
test -f upstream/bun.lock
test -f upstream/Dockerfile
test -d upstream/kernel
test -d upstream/packages/web
test -f upstream/scripts/docker-entrypoint.sh
test -f upstream/scripts/build-cloud-runtime.mjs
test -f upstream/scripts/fix-deprecation.js

# The merged single-file Dockerfile lives at the package root in git, but the
# action requires a file Dockerfile to sit inside its build context, so place
# a copy next to the upstream sources it builds against.
cp ./Dockerfile ./upstream/lzc-Dockerfile

echo "varin: source ready at ./upstream"
