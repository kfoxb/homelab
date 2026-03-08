#!/usr/bin/env bash
# Configure all K3s nodes to trust and mirror the in-cluster container registry.
# Writes /etc/rancher/k3s/registries.yaml on each node and restarts k3s.
# Nodes are restarted one at a time to minimise workload disruption.
# Safe to run multiple times (idempotent).

set -euo pipefail

NODES=(
  "192.168.1.200"
  "192.168.1.201"
  "192.168.1.202"
)
SSH_USER="fox"
REGISTRY_HOST="registry.claude-workers.svc.cluster.local:5000"

# Timeout in seconds to wait for a node to become Ready after k3s restart.
NODE_READY_TIMEOUT=120

REGISTRIES_YAML="mirrors:
  \"${REGISTRY_HOST}\":
    endpoint:
      - \"http://${REGISTRY_HOST}\"
configs:
  \"${REGISTRY_HOST}\":
    tls:
      insecure_skip_verify: true
"

# Returns 0 if the node already has the expected config, 1 otherwise.
node_already_configured() {
  local node="$1"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SSH_USER}@${node}" \
    "grep -qF '${REGISTRY_HOST}' /etc/rancher/k3s/registries.yaml 2>/dev/null" 2>/dev/null
}

# Write registries.yaml and restart k3s on a single node.
configure_node() {
  local node="$1"
  echo "==> Configuring ${node}..."

  if node_already_configured "${node}"; then
    echo "    Already configured, skipping write."
  else
    echo "    Writing /etc/rancher/k3s/registries.yaml..."
    # Pass the file content via stdin to avoid quoting/escaping issues.
    printf '%s' "${REGISTRIES_YAML}" | ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "${SSH_USER}@${node}" \
      "sudo tee /etc/rancher/k3s/registries.yaml > /dev/null"
  fi

  echo "    Restarting k3s..."
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SSH_USER}@${node}" \
    "sudo systemctl restart k3s"

  echo "    Waiting for node to become Ready (timeout ${NODE_READY_TIMEOUT}s)..."
  wait_for_node_ready "${node}"
  echo "    Node ${node} is Ready."
}

# Poll kubectl until the node reports Ready, or exit 1 on timeout.
wait_for_node_ready() {
  local node_ip="$1"
  local deadline=$(( $(date +%s) + NODE_READY_TIMEOUT ))

  # Resolve the node name from its internal IP so we can query kubectl.
  local node_name
  node_name=$(kubectl get nodes -o wide --no-headers 2>/dev/null \
    | awk -v ip="${node_ip}" '$6 == ip {print $1}')

  if [[ -z "${node_name}" ]]; then
    echo "    WARNING: could not find node name for IP ${node_ip}; skipping readiness check."
    return 0
  fi

  while true; do
    local status
    status=$(kubectl get node "${node_name}" --no-headers 2>/dev/null | awk '{print $2}')
    if [[ "${status}" == "Ready" ]]; then
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      echo "ERROR: node ${node_name} (${node_ip}) did not become Ready within ${NODE_READY_TIMEOUT}s."
      exit 1
    fi
    sleep 5
  done
}

echo "Configuring K3s nodes to trust local registry: ${REGISTRY_HOST}"
echo

for node in "${NODES[@]}"; do
  configure_node "${node}"
  echo
done

echo "All nodes configured successfully."
echo
echo "To verify, run a pod that pulls from the local registry:"
echo "  kubectl run registry-test --image=${REGISTRY_HOST}/library/hello-world:latest \\"
echo "    --restart=Never --rm -it -n claude-workers"
