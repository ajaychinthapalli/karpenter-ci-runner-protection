# Implementation guide

Seven steps (0 to 6) take the design from an empty cluster to a measured rollout. Every change after
Step 0 should land as a reviewed GitOps PR, starting with one canary runner set.

Values below are for `ac-ws-dev-use2` (us-east-2, EKS 1.36). Change them in [`scripts/env.sh`](../scripts/env.sh) for another cluster.

## Prerequisites

| Item | What to confirm | Why it matters |
| --- | --- | --- |
| Kubernetes version | `kubectl version` | Karpenter 1.13+ is needed for Kubernetes 1.36 |
| Authentication mode | `aws eks describe-cluster --name <cluster> --query cluster.accessConfig.authenticationMode` | Must be `API` or `API_AND_CONFIG_MAP` for the node access entry |
| ARC mode | `helm list -n arc-systems` shows `gha-runner-scale-set-controller` | Runner pod template lives in the runner set values |
| Existing autoscaler | `kubectl get deploy -A \| grep -i autoscaler` | Nothing else should scale the CI nodes |
| Free capacity for the controller | `kubectl describe nodes \| grep -A8 'Allocated resources'` | Two replicas at 500m / 512Mi each |
| Radar | Running, and how long it keeps history | Diagnosis needs evidence older than the one-hour event TTL |

Decisions to make up front:

- [ ] Which workflows are deploy-critical (on-demand only)?
- [ ] Peak CI hours, in UTC, for the budget schedule
- [ ] Maximum acceptable node lifetime past `expireAfter` (caps `terminationGracePeriod`)

### What we found on ac-ws-dev-use2

- No Karpenter, no Cluster Autoscaler, not EKS Auto Mode (`computeConfig` is `null`).
- Authentication mode `API_AND_CONFIG_MAP`: access entries work as is.
- Nodes: managed node group `agents` (2 × t3.large on-demand, cluster security group `sg-0328d65353bee4dc8`) and a
  self-managed CloudFormation node group (`ac-ws-dev-use2-ng-stack`, 3 × t3.small, node security group `sg-0d94c1912b444aebe`).
- CoreDNS runs on the self-managed nodes. The two security groups already allow all traffic between each other, and DNS
  resolves from the `agents` nodes, so CI nodes using the cluster security group reach CoreDNS.
- Subnets are public (`MapPublicIpOnLaunch = True`, about 16,000 free IPs each). Fine for dev; use private subnets for production.
- CloudWatch DaemonSets tolerate every taint (`operator: Exists`), so runner logs on CI nodes are collected with no change.

## Step 0: Install Karpenter

`scripts/01-install-karpenter.sh` does all of this and is safe to re-run.

1. **CloudFormation stack** (`Karpenter-<cluster>`) from the release's template: `KarpenterNodeRole-<cluster>`, six
   controller policies (`KarpenterController*Policy-<cluster>`: NodeLifecycle, IAMIntegration, EKSIntegration,
   Interruption, ResourceDiscovery, ZonalShift), the SQS interruption queue named after the cluster, and EventBridge rules.
2. **Access entry** for the node role, type `EC2_LINUX`, so Karpenter nodes can join.
3. **Controller role** `KarpenterControllerRole-<cluster>` with the trust in [`iam/pod-identity-trust.json`](../iam/pod-identity-trust.json),
   all six policies attached, and an EKS Pod Identity association to `kube-system/karpenter`.
4. **Discovery tags** `karpenter.sh/discovery=<cluster>` on the managed node group's subnets and the cluster security group.
5. **Spot service-linked role** (needed for `ci-spot`).
6. **Helm install** of `oci://public.ecr.aws/karpenter/karpenter` with [`karpenter/helm/values.yaml`](../karpenter/helm/values.yaml).
   The chart's default affinity keeps the controller off Karpenter nodes, so it lands on the existing nodes.
7. **Health check:** two controller pods `Running`, CRDs present, no AccessDenied or queue errors in the logs.

Older guides check for a single `KarpenterControllerPolicy-<cluster>`. Recent releases split it into the six policies
above; attach all of them.

## Step 1: Measure the baseline

Collect two weeks of data before tuning policy. The p99 job duration sets `terminationGracePeriod`.

1. **Export job history:** `scripts/export-github-jobs.sh <owner/repo> <since YYYY-MM-DD>`. It writes `jobs.csv` and prints
   p50/p95/p99. `runner_name` equals the runner pod name, the join key to Kubernetes evidence.
2. **Count Karpenter disruptions by reason and pool** (confirm the metric name for your version):

   ```promql
   sum by (nodepool, reason) (increase(karpenter_nodeclaims_disrupted_total[1d]))
   ```

3. **Join failures to node terminations** with `scripts/correlate-job.sh <runner>` (recent jobs) or Radar (older ones).
4. **Record the cost side:** runner node-hours per day and consolidation events per runner node-hour.

## Step 2: Create the CI NodePools

`scripts/02-apply-ci-pools.sh` renders and applies:

- [`karpenter/ec2nodeclass-ci.yaml`](../karpenter/ec2nodeclass-ci.yaml): shared node class, AMI pinned with `al2023@<AMI_VERSION>`.
- [`karpenter/nodepool-ci-ondemand.yaml`](../karpenter/nodepool-ci-ondemand.yaml): on-demand, tainted `workload=ci-runner:NoSchedule`.
- [`karpenter/nodepool-ci-spot.yaml`](../karpenter/nodepool-ci-spot.yaml) with `--with-spot`.

Choices in the pools:

- **x86, `c`/`m` families, generation 6 or newer.** The AMI alias resolves to x86, ARM, NVIDIA and Neuron variants; without
  these requirements a runner could land on ARM or GPU hardware.
- **`limits.cpu: 16`** caps spend on the dev account.
- **`terminationGracePeriod: 1h`** is a placeholder until Step 1 gives a real p99.
- **No peak-hours budget yet.** The commented budget in the on-demand pool is ready once peak hours are known.

Applying a NodePool launches nothing; nodes appear only when a runner pod needs one.

### Upgrading the AMI

`scripts/latest-ami-version.sh` prints the current version. Bump `AMI_VERSION` in a PR and re-run Step 2. The change drifts
existing CI nodes; `do-not-disrupt` makes each one wait for its job.

## Step 3: Point the runner set at the pool

`scripts/03-upgrade-arc.sh` upgrades `arc-runner-set` with [`arc/arc-runner-set-values.yaml`](../arc/arc-runner-set-values.yaml):

- `karpenter.sh/do-not-disrupt: "true"` on the pod template
- node selector `workload: ci-runner`, `capacity: ondemand`, and the matching toleration
- runner requests 500m / 1Gi so Karpenter bin-packs correctly
- `minRunners: 0`, because idle annotated runners would block consolidation

The release name is unchanged, so workflows keep `runs-on: arc-runner-set`. For short, retry-safe jobs, install the optional
spot runner set from [`arc/arc-runner-set-spot-values.yaml`](../arc/arc-runner-set-spot-values.yaml) and move those workflows
to `runs-on: arc-runner-set-spot`.

Setting a pod `template` replaces the chart's default runner pod, so carry over anything already in your values
(`helm get values arc-runner-set -n arc-runners`) before upgrading.

## Step 4: Keep the evidence and use Radar

Kubernetes events expire after about an hour and runner pods disappear when the job ends, so each evidence source must be
kept somewhere durable.

| Evidence | Where it is kept | Retain at least |
| --- | --- | --- |
| Pod, node and NodeClaim events, including `DisruptionBlocked` | Radar timeline; `scripts/capture-evidence.sh` for snapshots | 30 days |
| Karpenter controller logs, NodeClaim disruption reasons | CloudWatch; Karpenter metrics | 30 days |
| Runner pod logs | CloudWatch via Fluent Bit | 14 days |
| GitHub job data | `scripts/export-github-jobs.sh` on a schedule | 90 days |

Open Radar with `kubectl port-forward -n radar svc/radar 9280:9280` and browse to http://localhost:9280. Radar shows Karpenter
NodeClaims next to their nodes, including the `DisruptionBlocked` event that names the protected pod.

Add two alerts that make protection cost visible:

- `DisruptionBlocked` events on CI nodes above a daily threshold
- a CI node still draining more than `terminationGracePeriod` after its drain started

Diagnosis follows [runbook-diagnosis.md](runbook-diagnosis.md).

## Step 5: Canary and disruption tests

Prove each protection on the canary runner set before moving more workflows. One week of clean canary data is the gate to
expand. The test plan and recorded results are in [testing.md](testing.md).

## Step 6: Measure, tune and roll back

Review the success metrics against the baseline weekly for the first month, then monthly. Tune one setting at a time.

| Symptom | Likely cause | Tune |
| --- | --- | --- |
| Disruption failures still high, path = expiration | Grace period shorter than some jobs | Raise `terminationGracePeriod` or move long jobs to their own pool |
| Failures still high, path = spot interruption | Long jobs on `ci-spot` | Move those workflows to the on-demand runner set |
| Savings dropped noticeably | Warm annotated runners or blanket budgets | Lower `minRunners`; narrow the budget schedule |
| Nodes draining for hours after expiry | Grace period too generous | Lower it toward p99 + margin |
| Failures blamed on Karpenter without evidence | Events expired before diagnosis | Capture evidence sooner; check Radar retention |

Rollback is a revert of the PR for the affected step, newest first:

1. Re-apply the previous runner set values (removes the CI node selector for new jobs immediately).
2. Delete the CI NodePools once no runner pods remain; Karpenter drains their nodes.
3. To remove Karpenter entirely: `helm uninstall karpenter -n kube-system`, delete the Pod Identity association,
   the access entry, the controller role and the `Karpenter-<cluster>` CloudFormation stack.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `NoSuchEntity` for `KarpenterControllerPolicy-<cluster>` | Recent releases split the policy | Attach the six `KarpenterController*Policy` ARNs from the stack |
| `EC2NodeClass` stuck with `AMIsReady=Unknown` | AMI alias version not real (for example a placeholder) | Set `AMI_VERSION` from `scripts/latest-ami-version.sh` |
| `update-cluster-config` says unsupported mode update | Cluster already in the requested mode | Nothing to do |
| `nslookup kubernetes.default` returns NXDOMAIN from busybox | busybox ignores search domains | Use `kubernetes.default.svc.cluster.local` |
| Runner pod `Pending` with no NodeClaim | Selector, taint or pool limit mismatch | Check `kubectl describe pod` and the NodePool `limits` |
| Helm 401/403 pulling the chart | Stale ECR login | `helm registry logout public.ecr.aws` and retry |
