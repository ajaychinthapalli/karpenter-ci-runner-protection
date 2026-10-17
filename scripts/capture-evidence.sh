#!/usr/bin/env bash
# Saves a snapshot of events, NodeClaims, NodePools and runner pods to evidence/<timestamp>/.
# Run it right after an incident or a disruption test: Kubernetes keeps events for about an hour.
# Usage: scripts/capture-evidence.sh [label]
set -euo pipefail
source "$(dirname "$0")/env.sh"

label="${1:-snapshot}"
dir="${REPO_ROOT}/evidence/$(date -u +%Y%m%dT%H%M%SZ)-${label}"
mkdir -p "$dir"

kubectl get events -A -o yaml > "$dir/events.yaml"
kubectl get events -A --sort-by=.lastTimestamp \
  -o custom-columns='TIME:.lastTimestamp,NS:.involvedObject.namespace,KIND:.involvedObject.kind,OBJECT:.involvedObject.name,REASON:.reason,MESSAGE:.message' \
  > "$dir/events.txt"
kubectl get nodeclaims -o yaml > "$dir/nodeclaims.yaml" 2>/dev/null || true
kubectl get nodepools -o yaml > "$dir/nodepools.yaml"
kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type > "$dir/nodes.txt"
kubectl get pods -n "$ARC_NAMESPACE" -o wide > "$dir/runner-pods.txt" 2>/dev/null || true
kubectl logs -n "$KARPENTER_NAMESPACE" -l app.kubernetes.io/name=karpenter --tail=2000 > "$dir/karpenter.log" 2>/dev/null || true

echo "Saved to $dir"
echo "evidence/ is git-ignored; it can contain node names and account details."
