# Contributing

Thanks for helping improve the Karpenter CI runner protection repo.

## Scope

This project is a GitOps and operational safety repo for protecting self-hosted GitHub Actions runners from Karpenter disruption. Changes can affect:

- Karpenter configuration
- ARC runner settings
- IAM and pod identity policies
- verification scripts and evidence workflows
- runbooks and architecture docs

## Before you start

- Read the [README](README.md) and the relevant docs in [`docs/`](docs/).
- Keep changes small and reviewable.
- Prefer safe, reversible changes that preserve the existing protection model.

## Pull request workflow

1. Create a branch from `main`.
2. Make a focused change with the smallest possible blast radius.
3. Update related documentation if the behavior or rollout steps change.
4. Open a pull request and describe the operational impact, validation steps, and rollback plan.
5. Request review from the repository owners listed in [`CODEOWNERS`](CODEOWNERS).

## Validation expectations

For infrastructure or script changes:

- validate the relevant command or shell script locally when possible
- confirm the change still matches the repository's intended protection flow
- include any evidence or test results in the PR description

For documentation-only changes:

- keep the examples and commands consistent with the current scripts and file layout

## Reporting issues

Use GitHub issues for:

- bugs or unexpected runner disruption
- missing documentation or unclear runbooks
- requests for new guardrails or monitoring

When reporting an issue, include the cluster details, job timing, and any evidence you have from Karpenter, Kubernetes, or Radar.

## Review standards

Changes should be:

- clear and explainable
- safe under a rollback or revert
- aligned with the repo's explicit disruption-protection goals
- backed by evidence when operational behavior changes

Thank you for helping make runner disruption safer and more observable.
