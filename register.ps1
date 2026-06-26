<#
register.ps1 — one-shot Windows Autopilot registration · SetKernel Digital Inc.
Run at OOBE (Shift+F10) on a device you're provisioning: it registers the device CORPORATE to your
Intune/Autopilot tenant, waits for the deployment profile to be assigned, then powers the device off
so it's ready to ship. The end user then powers on and completes the Autopilot OOBE.

  Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://setkernel.net/ap | iex

What it does:
  1. Verifies the Windows edition (Autopilot needs Pro/Enterprise; Home is rejected).
  2. Installs the community Get-WindowsAutopilotInfo script (handles OOBE PSGallery prereqs).
  3. Get-WindowsAutopilotInfo -Online -GroupTag <tag> -Assign
       -Online   uploads the hardware hash to Intune (sign in ONCE at the Graph prompt as an
                 Intune Admin — this is API auth only; it does NOT put that account on the device).
       -GroupTag puts the device in the matching dynamic group -> which delivers the Autopilot profile.
       -Assign   WAITS until the Autopilot profile is actually assigned.
  4. On success -> powers OFF. Ship it. The user's OOBE then enrolls it Corporate with your profile.

Generic + tenant-agnostic — works for any org (the tenant is whoever signs in at the Graph prompt).
Config via env vars (set before running):
  $env:AP_TAG        group tag / OrderID   (default 'corp')
  $env:AP_PROKEY     a PURCHASED Windows Pro key, to upgrade a Home device (changepk + reboot)
  $env:AP_NOSHUTDOWN '1' to skip the power-off (reboot straight into the Autopilot OOBE instead)

DO NOT sign into Windows yourself during build, and never add a work account from Settings (= Personal).
No secrets in this script — safe to host publicly.   https://github.com/setkernel/autopilot
#>
$ErrorActionPreference = 'Stop'
$tag = if ($env:AP_TAG) { $env:AP_TAG } else { 'corp' }

function Show-Banner {
    $logo = @'

   ____   _  __
  / ___| | |/ /
  \___ \ | ' /
   ___) || . \
  |____/ |_|\_\
'@
    Write-Host $logo -ForegroundColor Cyan
    Write-Host "  S E T K E R N E L  Digital Inc." -ForegroundColor White
    Write-Host "  Windows Autopilot  *  zero-touch provisioning" -ForegroundColor DarkGray
    Write-Host "  ------------------------------------------------" -ForegroundColor DarkCyan
}

Show-Banner
Write-Host "  Registering this device to Autopilot  (group tag: $tag)`n" -ForegroundColor Cyan
try {
    Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # --- EDITION GATE: Autopilot/Entra-join need Pro/Enterprise. Windows HOME is NOT supported. ---
    $edition = (Get-CimInstance Win32_OperatingSystem).Caption
    if ($edition -match 'Home') {
        Write-Host "`nThis device is '$edition'. Windows HOME cannot Entra-join or run Autopilot." -ForegroundColor Red
        if ($env:AP_PROKEY) {
            Write-Host "Upgrading edition to Pro with the supplied AP_PROKEY, then rebooting. RE-RUN this one-liner after reboot." -ForegroundColor Yellow
            changepk.exe /productkey $env:AP_PROKEY
            Write-Host "If it doesn't reboot on its own, reboot manually and re-run." -ForegroundColor Yellow
            exit 0
        }
        Write-Host "Microsoft 365 Business Premium does NOT include Home->Pro upgrade rights — you need a PURCHASED Windows 11 Pro license/key." -ForegroundColor Red
        Write-Host "Fix: set `$env:AP_PROKEY='<your-real-Pro-key>' and re-run (runs changepk + reboots), or apply Pro in Settings>Activation, reboot, re-run." -ForegroundColor Red
        Write-Host "(The generic VK7JG-... key only gives UNACTIVATED Pro and won't be licensed — don't rely on it.)" -ForegroundColor DarkYellow
        exit 1
    }
    Write-Host "Edition OK: $edition" -ForegroundColor Green

    # PSGallery prerequisites (a fresh OOBE has no package provider yet)
    $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue
    if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    }
    Install-Script -Name Get-WindowsAutopilotInfo -Force -Scope CurrentUser -ErrorAction Stop
    $apScript = (Get-Command Get-WindowsAutopilotInfo.ps1 -ErrorAction Stop).Source

    Write-Host "Uploading hardware hash + WAITING for profile assignment..." -ForegroundColor Yellow
    Write-Host "Sign in at the prompt as an Intune Admin (Graph only — NOT a Windows sign-in)." -ForegroundColor Yellow
    & $apScript -Online -GroupTag $tag -Assign

    Write-Host "`nSUCCESS — registered to Autopilot (tag '$tag') and profile ASSIGNED." -ForegroundColor Green
    if ($env:AP_NOSHUTDOWN) {
        Write-Host "AP_NOSHUTDOWN set — not powering off. Power off before shipping; do NOT sign into Windows (unless this is your own device — then reboot into the Autopilot OOBE and sign in as yourself)." -ForegroundColor Yellow
    } else {
        Write-Host "Powering off in 20s so you can ship it. DO NOT sign into Windows." -ForegroundColor Green
        Start-Sleep -Seconds 20
        shutdown /s /t 0
    }
}
catch {
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "NOT powered off so you can retry. Check: network connected? signed in as an Intune Admin? group-tag profile assigned in Intune?" -ForegroundColor Red
    exit 1
}
