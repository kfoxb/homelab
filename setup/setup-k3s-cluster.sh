#!/bin/bash
set -euo pipefail

# ============================================================
# K3s 3-Node HA Cluster Setup
# ============================================================
# All three nodes run as servers (control plane + workload).
# Uses embedded etcd for HA (3-node quorum).
# 
# Prerequisites:
#   - SSH key access to all nodes (no password prompts)
#   - Ubuntu/Debian installed on all nodes
#   - User has sudo privileges (preferably passwordless sudo)
# ============================================================

# --- Configuration -------------------------------------------
NODES=(
  "192.168.1.200"
  "192.168.1.201"
  "192.168.1.202"
)
FIRST_NODE="${NODES[0]}"
SSH_USER="${SSH_USER:-$(whoami)}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ${SSH_KEY}"

# K3s options
K3S_VERSION="${K3S_VERSION:-}"  # empty = latest stable
# ============================================================

log() { echo -e "\n\033[1;32m>>> $1\033[0m"; }
err() { echo -e "\n\033[1;31m!!! $1\033[0m" >&2; }

run_on() {
  local host="$1"; shift
  ssh ${SSH_OPTS} "${SSH_USER}@${host}" "$@"
}

# --- Preflight checks ----------------------------------------
log "Checking SSH connectivity to all nodes..."
for node in "${NODES[@]}"; do
  if ! run_on "$node" "echo 'OK'" &>/dev/null; then
    err "Cannot SSH into ${SSH_USER}@${node}"
    err "Make sure your SSH key is authorized on this node."
    exit 1
  fi
  echo "  ✓ ${node} reachable"
done

# --- Prepare all nodes ---------------------------------------
log "Preparing all nodes (installing dependencies)..."
for node in "${NODES[@]}"; do
  echo "  Preparing ${node}..."
  run_on "$node" "sudo apt-get update -qq && \
    sudo apt-get install -y -qq curl open-iscsi nfs-common > /dev/null 2>&1 && \
    sudo systemctl enable --now iscsid"
  echo "  ✓ ${node} ready"
done

# --- Build the K3s install command ---------------------------
K3S_INSTALL_CMD="curl -sfL https://get.k3s.io | "
if [ -n "${K3S_VERSION}" ]; then
  K3S_INSTALL_CMD+="INSTALL_K3S_VERSION=${K3S_VERSION} "
fi

# --- Initialize first node -----------------------------------
log "Initializing first server node: ${FIRST_NODE}..."
run_on "$FIRST_NODE" "${K3S_INSTALL_CMD} sh -s - server \
  --cluster-init \
  --write-kubeconfig-mode 644 \
  --tls-san ${FIRST_NODE}"

echo "  Waiting for K3s to be ready..."
for i in $(seq 1 30); do
  if run_on "$FIRST_NODE" "sudo k3s kubectl get nodes" &>/dev/null; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    err "Timed out waiting for K3s on ${FIRST_NODE}"
    exit 1
  fi
  sleep 5
done
echo "  ✓ First node is up"

# --- Get the join token --------------------------------------
log "Retrieving join token..."
TOKEN=$(run_on "$FIRST_NODE" "sudo cat /var/lib/rancher/k3s/server/node-token")
echo "  ✓ Token retrieved"

# --- Join remaining nodes ------------------------------------
for node in "${NODES[@]:1}"; do
  log "Joining server node: ${node}..."
  run_on "$node" "${K3S_INSTALL_CMD} sh -s - server \
    --server https://${FIRST_NODE}:6443 \
    --token ${TOKEN} \
    --write-kubeconfig-mode 644 \
    --tls-san ${node}"

  echo "  Waiting for ${node} to join..."
  for i in $(seq 1 30); do
    if run_on "$FIRST_NODE" "sudo k3s kubectl get nodes" 2>/dev/null | grep -q "${node}"; then
      break
    fi
    if [ "$i" -eq 30 ]; then
      err "Timed out waiting for ${node} to join"
      exit 1
    fi
    sleep 5
  done
  echo "  ✓ ${node} joined"
done

# --- Verify cluster ------------------------------------------
log "Cluster status:"
run_on "$FIRST_NODE" "sudo k3s kubectl get nodes -o wide"

# --- Copy kubeconfig to local machine ------------------------
log "Fetching kubeconfig..."
KUBECONFIG_DIR="$HOME/.kube"
mkdir -p "$KUBECONFIG_DIR"

run_on "$FIRST_NODE" "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/${FIRST_NODE}/g" \
  > "${KUBECONFIG_DIR}/k3s-cluster.yaml"

echo ""
echo "  Kubeconfig saved to: ${KUBECONFIG_DIR}/k3s-cluster.yaml"
echo ""
echo "  To use it:"
echo "    export KUBECONFIG=${KUBECONFIG_DIR}/k3s-cluster.yaml"
echo ""
echo "  Or merge with existing config:"
echo "    export KUBECONFIG=\$HOME/.kube/config:${KUBECONFIG_DIR}/k3s-cluster.yaml"
echo "    kubectl config view --flatten > \$HOME/.kube/merged.yaml"
echo "    mv \$HOME/.kube/merged.yaml \$HOME/.kube/config"
echo ""

log "Done! Your 3-node K3s cluster is ready."
echo ""
echo "  Next steps:"
echo "    - Install Longhorn:  helm repo add longhorn https://charts.longhorn.io"
echo "                         helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace"
echo "    - Install DevPod:    https://devpod.sh/docs/getting-started/install"
echo "    - Set up AdGuard:    Install on a Rock64 separately"
echo ""
