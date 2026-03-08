#!/usr/bin/env bash
set -euo pipefail

# Build and push the claude-worker base image to ghcr.io.
#
# One-time setup required before running:
#   echo $GITHUB_TOKEN | docker login ghcr.io -u <your-github-username> --password-stdin
#
# In Phase 5 this script will be updated to also push to the local in-cluster registry.

REGISTRY="ghcr.io"
ORG="${GHCR_ORG:-kfoxb}"
IMAGE="${REGISTRY}/${ORG}/claude-worker"

# Use git short SHA for the versioned tag; fall back to "local" if not in a git repo
SHA=$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null || echo "local")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building ${IMAGE}:${SHA} and ${IMAGE}:latest"
docker build \
  --tag "${IMAGE}:${SHA}" \
  --tag "${IMAGE}:latest" \
  "${SCRIPT_DIR}"

echo "Pushing ${IMAGE}:${SHA}"
docker push "${IMAGE}:${SHA}"

echo "Pushing ${IMAGE}:latest"
docker push "${IMAGE}:latest"

echo ""
echo "Done. Image available at:"
echo "  ${IMAGE}:latest"
echo "  ${IMAGE}:${SHA}"
