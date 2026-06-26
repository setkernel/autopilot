# autopilot — one-command Windows Autopilot registration

A single PowerShell script you run at **OOBE** to register a Windows device to **your** Intune/Autopilot
tenant as **Corporate**, wait for the deployment profile to assign, then power off ready to ship. The end
user powers on and completes the Autopilot OOBE. Generic + tenant-agnostic (the tenant is whoever signs in
at the Graph prompt) and **secret-free**, so it's safe to host publicly.

<sub>A **SetKernel Digital Inc.** tool · [setkernel.net](https://setkernel.net)</sub>

## Use it
At a clean OOBE → **Shift+F10** → `powershell` →
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://setkernel.net/ap | iex
```
Sign in **once** at the Graph prompt as an **Intune Admin** (API auth only — it does *not* put that account
on the device). The script uploads the hardware hash with a group tag, **waits until the Autopilot profile
is assigned**, then powers off. Ship it.

> Don't sign into Windows yourself during build, and never add a work account from *Settings → Access work
> or school* (that enrolls **Personal**). The device must enroll through the **Autopilot OOBE** so it's Corporate.

### Options (env vars, set before running)
| Var | Purpose | Default |
| --- | --- | --- |
| `AP_TAG` | group tag / Autopilot OrderID (drives the dynamic-group → profile assignment) | `corp` |
| `AP_PROKEY` | a **purchased** Windows Pro key to upgrade a Home device (`changepk` + reboot, then re-run) | — |
| `AP_NOSHUTDOWN` | `1` = don't power off (reboot straight into the Autopilot OOBE — handy for your own device) | — |

## Prerequisites in your tenant
1. An **Autopilot deployment profile** assigned to a **dynamic device group** whose rule matches the tag, e.g.
   `(device.devicePhysicalIds -any (_ -eq "[OrderID]:corp"))`. (Group-tag assignment is far more reliable than "All Devices".)
2. **Windows Pro/Enterprise** — Home can't Entra-join/Autopilot, and M365 Business Premium does **not** grant Home→Pro.
3. (Recommended) **Block personal Windows enrollment** in Intune enrollment restrictions, so only corporate/Autopilot can enroll.

## Short URL (this repo → `setkernel.net/ap`)
`worker.js` + `wrangler.toml` publish a tiny Cloudflare Worker that serves `register.ps1` at `https://setkernel.net/ap`:
```sh
npm i -g wrangler && wrangler login && wrangler deploy
```
*(No-code alternative: a Cloudflare **Redirect Rule** — `setkernel.net/ap` → 302 → this repo's raw `register.ps1`. `irm` follows the redirect.)*

## Hardening before fleet rollout
This runs **elevated, at the most privileged moment** (OOBE), via `irm | iex`. Once the script is final and you've
validated a working run, pin the supply chain so a single push or a PSGallery update can't change what the fleet executes:
1. **Serve an immutable revision**, not `main`. In `worker.js` set `SRC` to a specific commit SHA or tag
   (`…/setkernel/autopilot/<commit-sha>/register.ps1`) and bump it deliberately per release.
2. **Verify a SHA-256** in the one-liner instead of bare `irm | iex`:
   ```powershell
   $f="$env:TEMP\reg.ps1"; irm https://setkernel.net/ap -OutFile $f; if((Get-FileHash $f -Algorithm SHA256).Hash -ne '<PINNED-SHA256>'){throw 'hash mismatch'}; & $f
   ```
3. **Pin the uploader version** — add `-RequiredVersion '<validated>'` to the `Install-Script Get-WindowsAutopilotInfo` line (keep `-Force`).
4. Restrict who can push to `main` and who can deploy the Worker / owns the `setkernel.net` zone.
