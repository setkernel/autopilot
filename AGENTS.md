# AGENTS.md

What anyone, person or coding agent, needs to know to work in **this** repository.
`CLAUDE.md` only points here. Org-wide rules (tracking work on the board, when to stop and ask,
secrets, branches and commits, the end-of-run report) come from setkernel's central agent setup
(https://github.com/setkernel/hq/blob/main/docs/repo-standard.md); don't repeat them here.

## What this repo is
`register.ps1` registers a Windows device to the signed-in admin's Intune/Autopilot tenant at
OOBE (Shift+F10 → `irm https://setkernel.net/ap | iex`), waits for profile assignment, then
powers off. It runs **elevated, at OOBE, on every device in the fleet**, under Windows
PowerShell 5.1. Licence: PolyForm Shield 1.0.0 (source-available, `LICENSE.md`).

## Commands
```sh
# install:  none (needs pwsh locally; PSScriptAnalyzer optional)
# test:     ./scripts/check.sh   # parse register.ps1, PSScriptAnalyzer errors if installed
# lint:     (part of check.sh)
# build:    none
```
CI (`.github/workflows/ci.yml`) parses every `.ps1` on `ubuntu-latest`. A parse check can't
exercise the OOBE flow: any behaviour change also needs a real OOBE run on a test device, and
the PR should say whether that run happened.

## Deploy
No deploy workflow. `https://setkernel.net/ap` is a Cloudflare redirect rule (302) to
`raw.githubusercontent.com/setkernel/autopilot/main/register.ps1`, managed in
[setkernel-cloudflare](https://github.com/setkernel/setkernel-cloudflare)
(`stacks/edge/rulesets.tf`, `setkernel_net_redirects`). So a merge to `main` reaches devices
within minutes. Pinning the served revision is a change to that redirect, not only to this repo;
README "Hardening before fleet rollout" lists the pinning work, none of which is done yet.

## Layout
- `register.ps1`: the whole product.
- `scripts/check.sh`: offline parse and lint check.
- `.github/workflows/`: `ci.yml` (parse check), `merge-audit.yml` (flags changes to `main`
  without Raghav's merge or approval).

## Traps and don't-touch
- Keep the repository name and public visibility: the redirect URL depends on both.
- Keep the script secret-free and tenant-agnostic: no tenant IDs, keys, hardware hashes or
  account names in the repository.
- The script runs under `iex`: never call `exit` at top level (it closes the operator's window
  and the error vanishes); use the existing `Stop-Here …; return` pattern. The community
  uploader runs in a child `powershell.exe` for the same reason.
- Stay compatible with Windows PowerShell 5.1 at OOBE, and keep the guards: Home SKUs (98–101)
  are refused, and the group tag must match `^[A-Za-z0-9._-]{1,250}$` (it is interpolated into
  the child `-Command` string).
- The repo is public: workflows run on GitHub-hosted runners (`ubuntu-latest`) only, never a
  self-hosted runner. Actions are pinned to a full commit SHA with the version in a comment;
  Dependabot keeps them current.
