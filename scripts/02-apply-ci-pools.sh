#!/usr/bin/env bash
# Applies the ci EC2NodeClass and the CI NodePools (docs/implementation-guide.md, Step 2).
# Usage: scripts/02-apply-ci-pools.sh [--with-spot]
set -euo pipefail
source "$(dirname "$0")/env.sh"

envsubst '${CLUSTER_NAME} ${AMI_VERSION}' < "${REPO_ROOT}/karpenter/ec2nodeclass-ci.yaml" | kubectl apply -f -
kubectl apply -f "${REPO_ROOT}/karpenter/nodepool-ci-ondemand.yaml"
if [[ "${1:-}" == "--with-spot" ]]; then
  kubectl apply -f "${REPO_ROOT}/karpenter/nodepool-ci-spot.yaml"
fi

echo "Waiting for the ci EC2NodeClass to resolve its AMI, subnets and security groups..."
kubectl wait ec2nodeclass/ci --for=condition=Ready --timeout=120s
kubectl get ec2nodeclass ci -o jsonpath='{.status.amis[*].name}{"\n"}' | tr ' ' '\n' | grep x86_64-standard
kubectl get nodepools
