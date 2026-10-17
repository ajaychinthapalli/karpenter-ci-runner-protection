#!/usr/bin/env bash
# Installs self-managed Karpenter on an existing EKS cluster (docs/implementation-guide.md, Step 0).
# Safe to re-run: each step skips work that is already done.
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_aws_account

STACK="Karpenter-${CLUSTER_NAME}"
NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"
CONTROLLER_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"
log() { printf '\n==> %s\n' "$*"; }

log "Checking cluster prerequisites"
mode="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.accessConfig.authenticationMode' --output text)"
if [[ "$mode" == "CONFIG_MAP" ]]; then
  echo "Authentication mode is CONFIG_MAP; access entries need API or API_AND_CONFIG_MAP." >&2
  echo "Run: aws eks update-cluster-config --name $CLUSTER_NAME --access-config authenticationMode=API_AND_CONFIG_MAP" >&2
  exit 1
fi
echo "authentication mode: $mode"
kubectl version | grep Server

log "1/7 IAM roles, interruption queue and EventBridge rules (CloudFormation)"
tmpl="$(mktemp)"
curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" -o "$tmpl"
aws cloudformation deploy --stack-name "$STACK" --template-file "$tmpl" \
  --capabilities CAPABILITY_NAMED_IAM --parameter-overrides "ClusterName=${CLUSTER_NAME}"
rm -f "$tmpl"

log "2/7 Access entry so Karpenter nodes can join"
if aws eks describe-access-entry --cluster-name "$CLUSTER_NAME" \
    --principal-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${NODE_ROLE}" >/dev/null 2>&1; then
  echo "access entry already exists"
else
  aws eks create-access-entry --cluster-name "$CLUSTER_NAME" \
    --principal-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${NODE_ROLE}" --type EC2_LINUX >/dev/null
  echo "access entry created"
fi

log "3/7 Controller role via EKS Pod Identity"
aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name eks-pod-identity-agent >/dev/null 2>&1 \
  || aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name eks-pod-identity-agent >/dev/null
if ! aws iam get-role --role-name "$CONTROLLER_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$CONTROLLER_ROLE" \
    --assume-role-policy-document "file://${REPO_ROOT}/iam/pod-identity-trust.json" >/dev/null
  echo "created $CONTROLLER_ROLE"
fi
# Recent releases split controller permissions into several policies; attach every one the stack created.
for arn in $(aws cloudformation describe-stack-resources --stack-name "$STACK" \
    --query "StackResources[?ResourceType=='AWS::IAM::ManagedPolicy'].PhysicalResourceId" --output text); do
  aws iam attach-role-policy --role-name "$CONTROLLER_ROLE" --policy-arn "$arn"
done
aws iam list-attached-role-policies --role-name "$CONTROLLER_ROLE" --query 'AttachedPolicies[].PolicyName' --output table
if [[ -z "$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
    --namespace "$KARPENTER_NAMESPACE" --service-account karpenter --query 'associations[0].associationId' --output text | grep -v None)" ]]; then
  aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --namespace "$KARPENTER_NAMESPACE" --service-account karpenter \
    --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CONTROLLER_ROLE}" >/dev/null
  echo "pod identity association created"
fi

log "4/7 Discovery tags on the managed node group subnets and the cluster security group"
for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --query 'nodegroups' --output text); do
  aws ec2 create-tags --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
    --resources $(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" \
      --query 'nodegroup.subnets' --output text)
done
aws ec2 create-tags --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
  --resources "$(aws eks describe-cluster --name "$CLUSTER_NAME" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
aws ec2 describe-subnets --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
  --query 'Subnets[].[SubnetId,AvailabilityZone,MapPublicIpOnLaunch,AvailableIpAddressCount]' --output table

log "5/7 Spot service-linked role"
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com >/dev/null 2>&1 \
  && echo "created" || echo "already exists"

log "6/7 Karpenter controller (Helm)"
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "$KARPENTER_VERSION" --namespace "$KARPENTER_NAMESPACE" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  -f "${REPO_ROOT}/karpenter/helm/values.yaml" \
  --wait

log "7/7 Controller health"
kubectl get pods -n "$KARPENTER_NAMESPACE" -l app.kubernetes.io/name=karpenter -o wide
kubectl get crd | grep karpenter
if kubectl logs -n "$KARPENTER_NAMESPACE" -l app.kubernetes.io/name=karpenter --tail=200 \
    | grep -iE 'AccessDenied|UnauthorizedOperation|queue.*error'; then
  echo "Controller logs show permission or queue errors; see docs/implementation-guide.md, Troubleshooting." >&2
  exit 1
fi
echo "Karpenter ${KARPENTER_VERSION} installed. Next: scripts/02-apply-ci-pools.sh"
