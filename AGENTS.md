# AGENTS.md

Operating contract for anyone (human or coding agent) working in this repository.
`register.ps1` registers a Windows device to the signed-in admin's Intune/Autopilot tenant at
OOBE (Shift+F10 → `irm https://setkernel.net/ap | iex`), waits for profile assignment, then
powers off. It runs **elevated, at OOBE, on every device in the fleet**. Licence: PolyForm
Shield 1.0.0 (source-available, `LICENSE.md`).

## Working agreement

- Keep going on steps that don't need the owner; put status notes alongside the next action.
- Stop and ask before pushing to `main` (the live URL serves `main`, so a push reaches devices
  within minutes) or changing the redirect rule in `setkernel-cloudflare`.
- Done means `./scripts/check.sh` passes, plus a real OOBE run on a test device for any
  behaviour change; say so when that run has not happened.
- End a run with three headings: **Blocked on owner**, **Changed**, **Found**.

## Commands

```sh
./scripts/check.sh   # parse register.ps1 (needs pwsh), PSScriptAnalyzer errors if installed
```

## How it is served

The live `setkernel.net/ap` is a 302 redirect rule managed in
`setkernel-cloudflare/stacks/edge/rulesets.tf` (`setkernel_net_redirects`) pointing at
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
- Changing the served revision (pinning) is a change in `setkernel-cloudflare`, not only here.
