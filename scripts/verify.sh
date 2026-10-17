#!/usr/bin/env bash
# Read-only health check of the whole setup. Prints PASS/FAIL per check.
set -uo pipefail
source "$(dirname "$0")/env.sh"

fail=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $name"; else echo "FAIL  $name"; fail=1; fi
}

check "Karpenter controller pods running" \
  bash -c "kubectl get pods -n $KARPENTER_NAMESPACE -l app.kubernetes.io/name=karpenter --no-headers | grep -q Running"
check "Karpenter CRDs installed" kubectl get crd nodepools.karpenter.sh nodeclaims.karpenter.sh ec2nodeclasses.karpenter.k8s.aws
check "ci EC2NodeClass Ready" \
  bash -c "[[ \$(kubectl get ec2nodeclass ci -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}') == True ]]"
check "ci-ondemand NodePool Ready" \
  bash -c "[[ \$(kubectl get nodepool ci-ondemand -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}') == True ]]"
check "Runner set carries do-not-disrupt" \
  bash -c "kubectl get autoscalingrunnerset $ARC_RELEASE -n $ARC_NAMESPACE -o jsonpath='{.spec.template.metadata.annotations}' | grep -q 'karpenter.sh/do-not-disrupt'"
check "Runner set targets CI nodes" \
  bash -c "kubectl get autoscalingrunnerset $ARC_RELEASE -n $ARC_NAMESPACE -o jsonpath='{.spec.template.spec.nodeSelector}' | grep -q ci-runner"
check "CloudWatch DaemonSets tolerate the CI taint" \
  bash -c "kubectl get ds cloudwatch-agent fluent-bit -n amazon-cloudwatch -o jsonpath='{.items[*].spec.template.spec.tolerations}' | grep -q Exists"
check "Radar running" bash -c "kubectl get pods -n radar --no-headers | grep -q Running"
check "Karpenter logs free of AccessDenied" \
  bash -c "! kubectl logs -n $KARPENTER_NAMESPACE -l app.kubernetes.io/name=karpenter --tail=300 | grep -qi AccessDenied"

exit $fail
