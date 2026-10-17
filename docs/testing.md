# Disruption tests

Each protection is proven with a deliberate test on the canary runner set before more workflows move over.
Copy [`examples/workflows/disruption-test.yml`](../examples/workflows/disruption-test.yml) into the runner
repository (`arc-runners-sandbox`), run it from the Actions tab, and disrupt the node while the job runs.

| Test | How to trigger | Expected result | Status |
| --- | --- | --- | --- |
| Cold start | Run the workflow with no CI nodes | NodeClaim launched, runner `Running` in about a minute | **Passed** 2026-10-16 |
| Forced drain within grace | `scripts/test-forced-drain.sh` with grace period longer than the remaining job | Node drains but waits; job succeeds; node then terminates | **Passed** 2026-10-16 |
| Consolidation blocked | Leave the node underutilized past `consolidateAfter` | No disruption; `DisruptionBlocked` names the pod; job succeeds | Pending |
| Grace period expires | Set `terminationGracePeriod: 5m` on the pool, then force a drain | Pod force-deleted at 5 minutes; record how GitHub reports the job | Pending |
| Spot interruption | AWS FIS `aws:ec2:send-spot-instance-interruptions` on a `ci-spot` node | Job interrupted; retry behavior as expected | Pending |
| Diagnosis | Run the runbook on each test | Correct verdict and fix for every test | Passed for forced drain |

After every test run `scripts/capture-evidence.sh <test-name>` before the events expire.

## Grace period expiry test

The pool has no CI nodes between tests, so its grace period can be shortened without drifting anything:

```bash
kubectl patch nodepool ci-ondemand --type merge \
  -p '{"spec":{"template":{"spec":{"terminationGracePeriod":"5m"}}}}'
# run the workflow, wait for Running, then:
scripts/test-forced-drain.sh
# afterwards, restore:
kubectl patch nodepool ci-ondemand --type merge \
  -p '{"spec":{"template":{"spec":{"terminationGracePeriod":"1h"}}}}'
```

Expected: the pod runs about 5 minutes after the drain starts, gets SIGTERM, then has 60 seconds
(`terminationGracePeriodSeconds`) before it is killed. Note the job's wording in GitHub ("cancelled",
"failed", or a runner shutdown message): it shows how the runner handles SIGTERM.

## Results: 2026-10-16 on ac-ws-dev-use2

Full evidence: [all 44 Radar events and the command logs](evidence/2026-10-16-forced-drain/README.md).

Setup: EKS 1.36.4, Karpenter 1.14.1, ARC 0.14.2, `ci-ondemand` with `terminationGracePeriod: 1h`, runner pod annotated
`do-not-disrupt`. Workflow: 10 minutes.

### Cold start

| Time (Phoenix) | Event |
| --- | --- |
| 13:34:35 | Runner pod created, `Pending` (no CI node exists) |
| 13:34:39 | NodeClaim `ci-ondemand-rbz2s` launched: c6a.large, on-demand, us-east-2c |
| 13:34:54 | Node `ip-192-168-193-117` registered |
| 13:35:11 | Node ready |
| 13:35:26 | Runner pod `Running` (51 s after creation) |

### Forced drain within grace

`kubectl delete nodeclaim ci-ondemand-rbz2s` at 13:36:56, about 2 minutes into the job. Timeline from Radar:

| Time (Phoenix) | Object | Event |
| --- | --- | --- |
| 13:36:40 | NodeClaim | `DisruptionBlocked`: Pod has "karpenter.sh/do-not-disrupt" annotation (Pod=arc-runners/arc-runner-set-fkvcg-runner-cq7vs) |
| 13:36:56 | Node | taint `karpenter.sh/disrupted` added |
| 13:36:56 | NodeClaim | `TerminationGracePeriodExpiring`: All pods will be deleted by 2026-10-16T21:36:55Z |
| 13:44:57 | Node | `FailedDraining`: 1 pods are waiting to be evicted (×5) |
| 13:45:04 | Node | `DisruptionBlocked`: Node is deleting or marked for deletion (×5) |
| 13:45:36 | NodeClaim | `Drained`; `InstanceTerminating` |
| 13:46:10 | Node | `RemovingNode` |

Result: the runner pod ran the full 10 minutes with 0 restarts and went `Completed`. The node was held for
**8 min 40 s** after the drain started, then drained and terminated; instance `i-007084a522299f95d` ended `terminated`.
No CI nodes or NodeClaims were left behind.
