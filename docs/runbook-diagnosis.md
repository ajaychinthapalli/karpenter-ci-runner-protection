# Diagnosis runbook: did Karpenter cause this job failure?

Rule Karpenter in or out first, then let the disruption path pick the fix. Every conclusion must
point to an event you actually saw; a missing event means UNKNOWN, not "absent".

## Inputs

- **Runner name** from the GitHub job log. With ARC runner scale sets it equals the runner pod name
  (for example `arc-runner-set-fkvcg-runner-cq7vs`).
- **Job window:** start and end time of the job, and its conclusion (success, failure, cancelled).

## Where the evidence is

| Evidence | Where | Notes |
| --- | --- | --- |
| Pod events (`Scheduled`, `Killing`, `Evicted`, `OOMKilled`) | Namespace `arc-runners` | `Scheduled` names the node |
| Node and NodeClaim events | Namespace `default` | Cluster-scoped objects record events there |
| Full history after events expire | Radar timeline | Kubernetes events last about an hour |
| Runner output, SIGTERM handling | CloudWatch (Fluent Bit) | |
| Job conclusion and timing | GitHub Actions UI or `scripts/export-github-jobs.sh` | |

For a recent job, `scripts/correlate-job.sh <runner-pod-name>` collects all of the Kubernetes evidence
and marks which signatures appear.

## Steps

1. **Job outcome first.** Did the job fail, get cancelled, or succeed? Don't assume a failure.
2. **Find the node** from the pod's `Scheduled` event, then the NodeClaim for that node.
3. **Did a node termination overlap the job window?** If not, the verdict is NOT KARPENTER.
4. **Classify the path** using the signatures below.
5. **Check protections:** was `do-not-disrupt` proven on the pod, how long was the job compared with `terminationGracePeriod`, which capacity type.
6. **Impact:** did the pod finish before the node drained, or was it killed during the drain?

## Event signatures

| Signature | Meaning |
| --- | --- |
| `DisruptionBlocked`: Pod has "karpenter.sh/do-not-disrupt" annotation (Pod=…) | Protection proven for that pod |
| `Disrupting` / `DisruptionTerminating` with reason `Underutilized` or `Empty` | Consolidation (voluntary) |
| Disruption with reason `Drifted` | Drift (voluntary) |
| `TerminationGracePeriodExpiring`: All pods will be deleted by … | Forced drain (expiration or NodeClaim deletion), with the deadline |
| `FailedDraining`: 1 pods are waiting to be evicted | Drain is waiting on a protected pod |
| `Drained`, then `InstanceTerminating` | Drain finished; node is going away |
| Spot interruption or instance terminating without a preceding drain | Forceful, not blockable |

Routine events to ignore:

- `InvalidDiskCapacity: invalid capacity 0 on image filesystem` at kubelet start
- `DisruptionBlocked: Node isn't initialized` while the node boots
- `DisruptionBlocked: Nodeclaim does not have an associated node` right after launch
- `DeletingNodeFailed: nodes "…" not found` during cleanup
- `Killing` right after a job ends: ARC deleting the finished runner pod

## Verdicts and fixes

| Verdict | Evidence pattern | Fix |
| --- | --- | --- |
| **NO IMPACT** | Protection proven; `Drained` after the job ended | None needed |
| **KARPENTER-VOLUNTARY** | Consolidation or drift signature; pod killed during the job | Add `do-not-disrupt` if missing; add a peak-hours budget; pin the AMI |
| **KARPENTER-FORCEFUL (expiration or deletion)** | `TerminationGracePeriodExpiring`; pod killed at the deadline | Raise `terminationGracePeriod` above the job length, or split long jobs to their own pool |
| **KARPENTER-FORCEFUL (spot)** | Spot interruption; no drain | Move the workflow to the on-demand runner set |
| **NOT KARPENTER** | No Karpenter signatures in the job window | Check runner logs, OOM kills, user cancellation |
| **UNKNOWN** | Events expired and no Radar history | Capture evidence sooner; check Radar retention |

Never recommend `do-not-disrupt` for a forceful path or when the annotation is already proven present.

## Worked example

Runner `arc-runner-set-fkvcg-runner-cq7vs`, job 13:35 to 13:45 Phoenix time, conclusion success:

- 13:36:40 `DisruptionBlocked`: Pod has "karpenter.sh/do-not-disrupt" annotation (Pod=arc-runners/arc-runner-set-fkvcg-runner-cq7vs) → protection proven
- 13:36:56 `TerminationGracePeriodExpiring`: All pods will be deleted by 21:36:55Z → forced drain (NodeClaim deleted)
- 13:44:57 `FailedDraining` ×5 → drain waiting on the protected pod
- 13:45:36 `Drained`, `InstanceTerminating` → after the job finished

**Verdict: NO IMPACT.** Karpenter held the node for 8 min 40 s until the job finished. Recommended change: none.
