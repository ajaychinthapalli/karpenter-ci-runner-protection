# Design

The core fix is a dedicated runner NodePool where `do-not-disrupt` on runner pods is paired with a
`terminationGracePeriod` longer than the longest job, plus on-demand capacity for jobs that cannot
tolerate spot loss. No single control guarantees job completion; the protection comes from combining
them per pool.

## How Karpenter disrupts nodes

The fix depends on which path ended the node, so classify the path before recommending anything.
Voluntary paths can be blocked by pod annotations and budgets. Forceful paths cannot; only grace
periods or capacity choices help.

| Path | Type | Honors `do-not-disrupt` | Honors budgets | What actually protects the job |
| --- | --- | --- | --- | --- |
| Consolidation (Empty, Underutilized) | Voluntary | Yes | Yes | Annotation on runner pods; scheduled budgets |
| Drift (AMI or NodeClass change) | Voluntary | Yes | Yes | Annotation; `Drifted` budget in peak hours; pinned AMI |
| Expiration (`expireAfter`) | Forceful | Delays eviction during drain | No | `terminationGracePeriod` ≥ longest job |
| NodeClaim deletion (manual) | Forceful | Delays eviction during drain | No | `terminationGracePeriod` ≥ longest job |
| Spot interruption | Forceful | No | No | On-demand capacity for critical pools |
| Node auto-repair | Forceful | Varies | No | Out of band; rule it in or out |
| Not Karpenter (EC2 health, kubelet or OOM eviction, cancellation) | n/a | n/a | n/a | Not a Karpenter fix; drives false-attribution rate |

On expiration or NodeClaim deletion the node starts draining right away, but a pod with
`do-not-disrupt` is not evicted. It keeps running until the NodePool's `terminationGracePeriod`
runs out, and only then is it force-deleted. With no `terminationGracePeriod`, such a pod can hold
an expired node indefinitely.

Behavior described is Karpenter v1.x (tested on 1.14.1).

## Disruption controls

| Control | Protects against | Limitation |
| --- | --- | --- |
| `karpenter.sh/do-not-disrupt` (pod) | Consolidation and drift; blocks eviction during drain | Bounded by `terminationGracePeriod`; no effect on spot interruption; also blocks consolidation of idle runner nodes |
| NodePool disruption budgets | Rate and timing of voluntary disruption, by reason (`Empty`, `Underutilized`, `Drifted`) and cron schedule | Do not apply to expiration or interruption |
| `consolidateAfter` | Churn right after pods are added or removed | Does not protect a job already running |
| `expireAfter` | Unbounded node lifetime (patching, security) | Forceful; starts a drain mid-job |
| `terminationGracePeriod` | Defines how long a draining node waits for protected pods | Force-deletes pods at the deadline; unset means nodes may never finish draining |
| On-demand capacity type | Spot interruption | Higher compute cost |
| Pinned AMI in the EC2NodeClass | Surprise drift when AWS publishes a new AMI | AMI bumps become a deliberate, reviewed change |
| Pod `terminationGracePeriodSeconds` and runner SIGTERM handling | Unclean exits and ambiguous "lost communication" job states | Behavior differs by ARC mode; verify in the grace-expiry test |

## Recommended design

1. **Dedicated pool.** Taint the CI pool so only runner pods land there; other workloads keep their own consolidation behavior.
2. **Grace period sized to jobs.** `terminationGracePeriod` = p99 job duration + margin. This is what lets an expiring node wait for the job.
3. **Capacity by criticality.** On-demand for long builds and deployment workflows; spot only for short jobs that retry cheaply.
4. **Scheduled budgets.** Block `Underutilized` and `Drifted` disruption in peak CI hours; allow it off-hours to recover savings.
5. **Watch idle runners.** A static annotation also protects idle warm runners (`minRunners`). Keep `minRunners` low.
6. **Durability for the critical few.** For jobs that must survive node loss, use checkpointing, resumable builds, or a more durable execution environment.

## Components

| Component | Role |
| --- | --- |
| Amazon EKS | Hosts the runner workloads |
| Actions Runner Controller (runner scale sets) | Creates one ephemeral runner pod per GitHub Actions job |
| Karpenter v1 | Provisions, consolidates, drifts and expires CI nodes |
| Radar | Event timeline correlating job, pod, node and NodeClaim history |
| CloudWatch (Container Insights, Fluent Bit) | Keeps runner pod logs |
| GitOps repo | Where NodePool and runner config changes are proposed and reviewed |
| Platform engineer | Diagnoses failures with the runbook and opens the fix PR |

## Success metrics

Each metric needs a pre-change baseline.

| Metric | Definition | Direction |
| --- | --- | --- |
| Job disruption rate | % of jobs failed or cancelled with a confirmed node termination in their window | Down |
| Retry waste | Runner minutes spent on retries attributable to node disruption | Down |
| Consolidation savings retained | Consolidation rate per runner node-hour after the change, against the baseline | Hold |
| Protection cost | Node-hours held by `DisruptionBlocked` or by draining past expiration | Visible and bounded |
| Detection time | Interruption to evidence-backed diagnosis | Down |
| False attribution rate | Incidents blamed on Karpenter that evidence shows had another cause | Down |

Protection cost is the counterweight to retry waste: together they show whether a protection pays for itself.

## Risks and trade-offs

- **Stuck nodes.** A long `terminationGracePeriod` plus `do-not-disrupt` can keep expired nodes alive for hours, delaying patching. Cap it deliberately and alert on drains that exceed it.
- **Idle-runner cost.** Static annotations stop consolidation of nodes that only hold idle runners.
- **Spot savings forgone.** Moving critical pools to on-demand removes interruption risk at a known price premium.
- **Misattribution.** Without the NodeClaim disruption reason, failures get blamed on Karpenter when the cause was an OOM kill or a cancellation. Diagnoses must cite events, and fixes stay human-reviewed.
- **Short event retention.** Kubernetes keeps events for about an hour; Radar's history and `scripts/capture-evidence.sh` cover the gap.

## Open questions

- [ ] What is the p99 job duration per runner set? It sets `terminationGracePeriod`.
- [ ] Which workflows are deploy-critical and need on-demand capacity?
- [ ] Peak CI hours (UTC) for the disruption budget schedule.
- [ ] How long Radar retains history.
- [ ] For production: move CI nodes to private subnets behind NAT (the dev cluster uses public subnets).
