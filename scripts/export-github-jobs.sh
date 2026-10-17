#!/usr/bin/env bash
# Exports GitHub Actions job history for the baseline (docs/implementation-guide.md, Step 1).
# Output CSV: job_id,name,runner_name,conclusion,started_at,completed_at,duration_s
# runner_name equals the ARC runner pod name, which is the join key to Kubernetes evidence.
#
# Usage: scripts/export-github-jobs.sh <owner/repo> <since YYYY-MM-DD> [out.csv]
# Needs the GitHub CLI (gh) logged in with read access to the repository.
set -euo pipefail

REPO="${1:?usage: export-github-jobs.sh <owner/repo> <since YYYY-MM-DD> [out.csv]}"
SINCE="${2:?usage: export-github-jobs.sh <owner/repo> <since YYYY-MM-DD> [out.csv]}"
OUT="${3:-jobs.csv}"

echo "job_id,name,runner_name,conclusion,started_at,completed_at,duration_s" > "$OUT"
gh api --paginate "repos/${REPO}/actions/runs?created=>=${SINCE}&per_page=100" --jq '.workflow_runs[].id' |
while read -r run_id; do
  gh api --paginate "repos/${REPO}/actions/runs/${run_id}/jobs?per_page=100" --jq '
    .jobs[]
    | select(.completed_at != null and .started_at != null)
    | [.id, .name, (.runner_name // ""), (.conclusion // ""), .started_at, .completed_at,
       ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601))]
    | @csv'
done >> "$OUT"

echo "Wrote $(($(wc -l < "$OUT") - 1)) jobs to $OUT"
echo "Duration percentiles (seconds), all jobs:"
tail -n +2 "$OUT" | awk -F, '{print $7}' | sort -n | awk '
  { v[NR] = $1 }
  END {
    if (NR == 0) { print "  no jobs"; exit }
    printf "  p50=%s  p95=%s  p99=%s  max=%s  (n=%d)\n",
      v[int(NR*0.50)+(NR*0.50>int(NR*0.50))], v[int(NR*0.95)+(NR*0.95>int(NR*0.95))],
      v[int(NR*0.99)+(NR*0.99>int(NR*0.99))], v[NR], NR
  }'
echo "Set terminationGracePeriod on the CI NodePools above p99 plus margin."
