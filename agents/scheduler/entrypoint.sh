#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="claude-workers"
CONFIG_DIR="/etc/worker-config"

while true; do
  sleep 30

  # Read max concurrency from mounted ConfigMap volume
  MAX=$(cat "${CONFIG_DIR}/maxConcurrent" 2>/dev/null || echo "2")

  # Count pods currently in running state
  RUNNING=$(kubectl get pods -n "${NAMESPACE}" -l status=running \
    --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] running=${RUNNING} max=${MAX}"

  if [ "${RUNNING}" -lt "${MAX}" ]; then
    # Find the oldest queued pod (sorted by creationTimestamp ascending)
    OLDEST=$(kubectl get pods -n "${NAMESPACE}" -l status=queued \
      --sort-by=.metadata.creationTimestamp \
      -o custom-columns='NAME:.metadata.name' \
      --no-headers 2>/dev/null | head -1)

    if [ -n "${OLDEST}" ]; then
      kubectl label pod "${OLDEST}" -n "${NAMESPACE}" status=running --overwrite
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Released: ${OLDEST}"
    fi
  fi

  # Re-queue rate-limited pods whose cooldown has expired
  NOW=$(date +%s)
  RATE_LIMITED=$(kubectl get pods -n "${NAMESPACE}" -l status=rate-limited \
    -o custom-columns='NAME:.metadata.name' \
    --no-headers 2>/dev/null)

  for POD in ${RATE_LIMITED}; do
    RETRY_AFTER=$(kubectl get pod "${POD}" -n "${NAMESPACE}" \
      -o jsonpath='{.metadata.annotations.ccw/retry-after}' 2>/dev/null || true)

    # Skip pods with no retry-after annotation
    if [ -z "${RETRY_AFTER}" ]; then
      continue
    fi

    if [ "${NOW}" -gt "${RETRY_AFTER}" ]; then
      kubectl label pod "${POD}" -n "${NAMESPACE}" status=queued --overwrite
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Re-queued after rate limit cooldown: ${POD}"
    fi
  done
done
