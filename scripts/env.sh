#!/usr/bin/env bash
# Shared settings. Source this file; every other script does so automatically.
# Override any value by exporting it before running a script.

export CLUSTER_NAME="${CLUSTER_NAME:-ac-ws-dev-use2}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"
export KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE:-kube-system}"
# Karpenter 1.14.1 is an LTS release (supported until Jul 2027); Kubernetes 1.36 needs 1.13 or later.
export KARPENTER_VERSION="${KARPENTER_VERSION:-1.14.1}"
# EKS-optimized AL2023 AMI version for the ci EC2NodeClass (scripts/latest-ami-version.sh prints the current one).
export AMI_VERSION="${AMI_VERSION:-v20261012}"
export ARC_CHART_VERSION="${ARC_CHART_VERSION:-0.14.2}"
export ARC_NAMESPACE="${ARC_NAMESPACE:-arc-runners}"
export ARC_RELEASE="${ARC_RELEASE:-arc-runner-set}"

# Only the AWS-side scripts call this, so kubectl-only scripts work without AWS credentials.
require_aws_account() {
  if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
    export AWS_ACCOUNT_ID
  fi
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
