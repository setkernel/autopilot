# AGENTS.md

Operating contract for anyone (human or coding agent) working in this repository.
`register.ps1` registers a Windows device to the signed-in admin's Intune/Autopilot tenant at
OOBE (Shift+F10 → `irm https://setkernel.net/ap | iex`), waits for profile assignment, then
powers off. It runs **elevated, at OOBE, on every device in the fleet**. Licence: PolyForm
Shield 1.0.0 (source-available, `LICENSE.md`).

## Working agreement

- Keep going on steps that don't need the owner; put status notes alongside the next action.
- Stop and ask before pushing to `main` (the live URL serves `main`, so a push reaches devices
  within minutes) or changing the redirect.
- Done means `./scripts/check.sh` passes, plus a real OOBE run on a test device for any
  behaviour change; say so when that run has not happened.
- End a run with three headings: **Blocked on owner**, **Changed**, **Found**.
- Long or multi-step work: keep a checklist in `TASKS.md` (gitignored) so progress survives
  context compaction; tick items as they finish.

## Commands

```sh
./scripts/check.sh   # parse register.ps1 (needs pwsh), PSScriptAnalyzer errors if installed
# CI runs the same parse check on ubuntu-latest (.github/workflows/ci.yml)
```

## How it is served

The short URL is a 302 redirect, managed outside this repository by the owner, that points at
`raw.githubusercontent.com/setkernel/autopilot/main/register.ps1`. There is no Worker.
README "Hardening before fleet rollout" lists the pinning work, none of which is done yet.
Keep the repository name and public visibility: the redirect depends on both.

## Rules

- Keep the script secret-free and tenant-agnostic: no tenant IDs, keys, hardware hashes or
  account names in the repository.
- The script runs under `iex`: never call `exit` at top level; keep the existing `return`
  pattern.
- Keep it compatible with Windows PowerShell 5.1 at OOBE and keep the existing guards: Home
  SKUs (98–101) are refused, and the group tag must match `^[A-Za-z0-9._-]{1,250}$`.
- Changing the served revision (pinning) is a change to the redirect, not only to this repository.

## Conventions
- Branches: `<type>/<short-name>` (feat/, fix/, chore/, ci/, docs/). Agents push to `claude/` or `agent/` branches.
- Commits: conventional style (`feat: ...`, `fix: ...`). Every PR needs maintainer review before merge.
- GitHub Actions run on GitHub-hosted runners (`ubuntu-latest`) only: this repository is public, so never
  point a workflow at a self-hosted runner. Actions are pinned to a full commit SHA with the version in a
  comment, and Dependabot keeps them current.

## Agent tooling (.claude/)
- Subagents: `explorer` (Sonnet, read-only search and log reading) and `reviewer` (Opus, high
  effort, merge blockers only). Delegate lookups to `explorer`; keep code edits in the main session.
- Skills: `verify` (run the checks as CI does), `review-blockers`, `ship-pr` (verify → review →
  branch → PR). Use `ship-pr` to finish a change.
- Effort: medium for well-scoped work, high for bugs in old code and for review; low for
  mechanical edits. A check (test, build) beats raising effort.
- Cloud sessions run `.claude/cloud-setup.sh` on start (only when `CLAUDE_CODE_REMOTE` is set).
