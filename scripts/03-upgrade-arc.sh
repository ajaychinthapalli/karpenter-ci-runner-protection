#!/usr/bin/env bash
# Moves the ARC runner set onto the CI pool with do-not-disrupt (docs/implementation-guide.md, Step 3).
set -euo pipefail
source "$(dirname "$0")/env.sh"

helm upgrade --install "$ARC_RELEASE" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version "$ARC_CHART_VERSION" -n "$ARC_NAMESPACE" \
  -f "${REPO_ROOT}/arc/arc-runner-set-values.yaml"

echo "Pod template now on the runner set:"
kubectl get autoscalingrunnerset "$ARC_RELEASE" -n "$ARC_NAMESPACE" \
  -o jsonpath='annotations: {.spec.template.metadata.annotations}{"\n"}nodeSelector: {.spec.template.spec.nodeSelector}{"\n"}tolerations: {.spec.template.spec.tolerations}{"\n"}'
