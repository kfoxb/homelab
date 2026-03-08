#!/usr/bin/env bash
# Expands the root LV to use all free space in the VG on each node.
# Safe to re-run — lvextend will no-op if no free space remains.

set -euo pipefail

NODES=(
  "fox@192.168.1.200"
  "fox@192.168.1.201"
  "fox@192.168.1.202"
)

for node in "${NODES[@]}"; do
  echo "==> $node"
  ssh "$node" bash <<'EOF'
    set -euo pipefail
    VG=$(sudo vgs --noheadings -o vg_name | tr -d ' ')
    LV=$(sudo lvs --noheadings -o lv_name "$VG" | tr -d ' ' | head -1)
    LV_PATH="/dev/$VG/$LV"

    FREE=$(sudo vgs --noheadings --units b -o vg_free "$VG" | tr -d ' B')
    if [ "$FREE" -le 0 ]; then
      echo "  No free space in VG, skipping."
      exit 0
    fi

    echo "  Extending $LV_PATH by ${FREE} bytes..."
    sudo lvextend -l +100%FREE "$LV_PATH"
    echo "  Resizing filesystem..."
    sudo resize2fs "$LV_PATH"
    echo "  Done. New size: $(df -h / | awk 'NR==2{print $2}')"
EOF
  echo ""
done

echo "All nodes expanded."
