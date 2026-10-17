#!/usr/bin/env bash
# Disruption test: force-drains the node running a runner pod, the same path node expiration takes.
# Start examples/workflows/disruption-test.yml first and wait until the runner pod is Running.
#
# Expected with protections in place (docs/testing.md):
#   - DisruptionBlocked names the pod's do-not-disrupt annotation
#   - TerminationGracePeriodExpiring + FailedDraining while the job runs
#   - the job finishes green, then the node drains and terminates
#
# Usage: scripts/test-forced-drain.sh [runner-pod-name]
set -euo pipefail
source "$(dirname "$0")/env.sh"

POD="${1:-$(kubectl get pods -n "$ARC_NAMESPACE" --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')}"
[[ -z "$POD" ]] && { echo "No running runner pod in $ARC_NAMESPACE. Start the disruption-test workflow first." >&2; exit 1; }

NODE="$(kubectl get pod "$POD" -n "$ARC_NAMESPACE" -o jsonpath='{.spec.nodeName}')"
DND="$(kubectl get pod "$POD" -n "$ARC_NAMESPACE" -o jsonpath='{.metadata.annotations.karpenter\.sh/do-not-disrupt}')"
NODECLAIM="$(kubectl get nodeclaims -o jsonpath="{range .items[?(@.status.nodeName==\"$NODE\")]}{.metadata.name}{end}")"
[[ -z "$NODECLAIM" ]] && { echo "$NODE is not a Karpenter node; refusing to continue." >&2; exit 1; }

echo "pod=$POD node=$NODE nodeclaim=$NODECLAIM do-not-disrupt=${DND:-<not set>}"
read -r -p "Delete NodeClaim $NODECLAIM to start a forced drain? [y/N] " ok
[[ "$ok" == "y" ]] || { echo "Cancelled."; exit 0; }

kubectl delete nodeclaim "$NODECLAIM" --wait=false
echo
echo "Drain started. Watch it with:"
echo "  kubectl get pods -n $ARC_NAMESPACE -w"
echo "  kubectl get nodeclaim $NODECLAIM -w"
echo "Afterwards: scripts/correlate-job.sh $POD   and   scripts/capture-evidence.sh forced-drain"
