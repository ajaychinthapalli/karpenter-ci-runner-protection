#!/usr/bin/env bash
# Prints the current EKS-optimized AL2023 x86_64 AMI version (for example v20261012)
# for the cluster's Kubernetes version. Use it to bump AMI_VERSION in a reviewed PR.
set -euo pipefail
source "$(dirname "$0")/env.sh"

k8s="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.version --output text)"
ami_id="$(aws ssm get-parameter \
  --name "/aws/service/eks/optimized-ami/${k8s}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
  --query Parameter.Value --output text)"
name="$(aws ec2 describe-images --image-ids "$ami_id" --query 'Images[0].Name' --output text)"
echo "${name##*-}"
