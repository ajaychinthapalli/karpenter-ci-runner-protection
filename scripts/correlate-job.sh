#!/usr/bin/env bash
# Collects the Kubernetes evidence for one runner pod: its node, the node's NodeClaim,
# and every pod, node and NodeClaim event, then lists which disruption signatures appear.
# It reports evidence; the verdict is yours (docs/runbook-diagnosis.md).
#
# Usage: scripts/correlate-job.sh <runner-pod-name>
#   The runner name shown in the GitHub job log equals the runner pod name.
# Kubernetes keeps events for about one hour. For older jobs, use Radar's timeline.
set -euo pipefail
source "$(dirname "$0")/env.sh"

POD="${1:?usage: correlate-job.sh <runner-pod-name>}"
NS="$ARC_NAMESPACE"
COLS='TIME:.lastTimestamp,KIND:.involvedObject.kind,OBJECT:.involvedObject.name,REASON:.reason,COUNT:.count,MESSAGE:.message'
section() { printf '\n=== %s ===\n' "$*"; }

events_for() { # namespace, object name
  kubectl get events -n "$1" --field-selector "involvedObject.name=$2" \
    --sort-by=.lastTimestamp -o custom-columns="$COLS" 2>/dev/null | tail -n +2 || true
}

section "Runner pod $NS/$POD"
NODE=""
if kubectl get pod "$POD" -n "$NS" >/dev/null 2>&1; then
  kubectl get pod "$POD" -n "$NS" \
    -o custom-columns='PHASE:.status.phase,NODE:.spec.nodeName,DO_NOT_DISRUPT:.metadata.annotations.karpenter\.sh/do-not-disrupt,STARTED:.status.startTime'
  NODE="$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}')"
else
  echo "Pod no longer exists (ARC deletes finished runner pods); using its events."
fi
POD_EVENTS="$(events_for "$NS" "$POD")"
echo "${POD_EVENTS:-<no pod events: expired or wrong name>}"
if [[ -z "$NODE" ]]; then
  NODE="$(grep -oE 'assigned [^ ]+ to [^ ]+' <<<"$POD_EVENTS" | awk '{print $4}' | tail -1 || true)"
fi
[[ -z "$NODE" ]] && { echo "Could not find the pod's node. Check Radar for this pod." >&2; exit 2; }

section "Node $NODE"
if kubectl get node "$NODE" >/dev/null 2>&1; then
  kubectl get node "$NODE" -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
  kubectl get node "$NODE" -o jsonpath='{range .spec.taints[*]}taint: {.key}={.effect}{"\n"}{end}'
else
  echo "Node no longer exists."
fi
NODE_EVENTS="$(events_for default "$NODE")"
echo "${NODE_EVENTS:-<no node events: expired>}"

section "NodeClaim"
NODECLAIM="$(kubectl get nodeclaims -o jsonpath="{range .items[?(@.status.nodeName==\"$NODE\")]}{.metadata.name}{end}" 2>/dev/null || true)"
if [[ -z "$NODECLAIM" ]]; then
  # NodeClaim already deleted: find it through NodeClaim events that name this pod or node.
  NODECLAIM="$(kubectl get events -n default --field-selector involvedObject.kind=NodeClaim \
    -o custom-columns='NAME:.involvedObject.name,MSG:.message' --no-headers 2>/dev/null \
    | grep -E "$POD|$NODE" | awk '{print $1}' | sort -u | head -1 || true)"
fi
if [[ -n "$NODECLAIM" ]]; then
  echo "NodeClaim: $NODECLAIM"
  kubectl get nodeclaim "$NODECLAIM" 2>/dev/null || echo "(deleted)"
  NC_EVENTS="$(events_for default "$NODECLAIM")"
  echo "${NC_EVENTS:-<no NodeClaim events: expired>}"
else
  echo "No NodeClaim found for $NODE (not a Karpenter node, or its events expired)."
  NC_EVENTS=""
fi

section "Disruption signatures found"
ALL="$POD_EVENTS"$'\n'"$NODE_EVENTS"$'\n'"$NC_EVENTS"
found=0
sig() { # label, regex
  if grep -qE "$2" <<<"$ALL"; then echo "  [x] $1"; found=1; else echo "  [ ] $1"; fi
}
sig "Protection proven: DisruptionBlocked names this pod's do-not-disrupt annotation" "do-not-disrupt.*$POD"
sig "Voluntary disruption: consolidation (Underutilized / Empty)" "Underutilized|Empty"
sig "Voluntary disruption: drift" "Drifted"
sig "Forced drain (expiration or NodeClaim deletion): TerminationGracePeriodExpiring" "TerminationGracePeriodExpiring"
sig "Drain waited on a protected pod: FailedDraining" "FailedDraining"
sig "Spot interruption" "SpotInterrupt|Interrupted"
sig "Node drained" "Drained"
sig "Pod killed or evicted (check its time against the job end)" "Killing|Evicted|Preempt"
sig "Out of memory" "OOMKill"

cat <<'EOF'

How to read this (docs/runbook-diagnosis.md):
  - Protection proven + Drained after the job ended  -> NO IMPACT
  - Forced drain + pod killed before the job ended    -> KARPENTER-FORCEFUL (compare job length with terminationGracePeriod)
  - Consolidation or drift + pod killed               -> KARPENTER-VOLUNTARY (annotation missing?)
  - No Karpenter signatures in the job window         -> NOT KARPENTER (check runner logs, OOM, cancellation)
  - Missing events                                    -> UNKNOWN here; use Radar's timeline
"Killing" right after a job ends is ARC deleting the finished pod, not a disruption.
EOF
exit 0
