<#
register.ps1 — one-shot Windows Autopilot registration, run at OOBE (Shift+F10). SetKernel Digital Inc.

Registers the device CORPORATE to your Intune/Autopilot tenant, waits for the deployment profile to be
assigned, then powers off ready to ship. The end user then powers on and completes the Autopilot OOBE.

  Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://setkernel.net/ap | iex

Flow: edition check (Pro/Enterprise required) -> install Get-WindowsAutopilotInfo ->
      Get-WindowsAutopilotInfo -Online -GroupTag <tag> -Assign  (upload hash, wait for profile) -> power off.
Sign in ONCE at the Graph prompt as an Intune Admin (API auth only — it does NOT put that account on the
device). Don't sign into Windows during build, and never add a work account from Settings (= Personal).

Generic + tenant-agnostic (tenant = whoever signs in) and secret-free — safe to host publicly.
Options (env vars, set before running):
  $env:AP_TAG        group tag / OrderID   (default 'corp')
  $env:AP_PROKEY     a PURCHASED Windows Pro key to upgrade a Home device (changepk + reboot, then re-run)
  $env:AP_NOSHUTDOWN '1' to skip the power-off (reboot straight into the Autopilot OOBE — e.g. your own device)
                                                                  https://github.com/setkernel/autopilot
#>
$ErrorActionPreference = 'Stop'
$tag = if ($env:AP_TAG) { $env:AP_TAG } else { 'corp' }

# Auto-log everything to a temp file so the error survives even if a sub-script `exit`s the host.
$LogFile = Join-Path $env:TEMP 'setkernel-autopilot.log'
try { Start-Transcript -Path $LogFile -Force -ErrorAction Stop | Out-Null } catch {}

function Show-Banner {
    $logo = @'

   ____   _____  _____  _  __ ____   _   _  _
  / ___| | ____||_   _|| |/ /|  _ \ | \ | || |
  \___ \ |  _|    | |  | ' / | |_) ||  \| || |
   ___) || |___   | |  | . \ |  _ < | |\  || |___
  |____/ |_____|  |_|  |_|\_\|_| \_\|_| \_||_____|
'@
    Write-Host $logo -ForegroundColor Cyan
    Write-Host "  SetKernel Digital Inc." -ForegroundColor White
    Write-Host "  Windows Autopilot  *  zero-touch provisioning" -ForegroundColor DarkGray
    Write-Host "  -------------------------------------------------" -ForegroundColor DarkCyan
}

# Under `irm | iex`, `exit` would close the whole host and the message would vanish — pause + return instead.
function Stop-Here($msg, $color = 'Red') {
    if ($msg) { Write-Host "`n$msg" -ForegroundColor $color }
    Write-Host "`nFull log saved to: $LogFile   (open with: notepad `"$LogFile`")" -ForegroundColor DarkGray
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    [void](Read-Host "`nPress Enter to close")
}

Show-Banner
Write-Host "  Registering this device to Autopilot  (group tag: $tag)`n" -ForegroundColor Cyan

# group tag sanity (OrderID is ASCII, no spaces)
if ($tag -match '\s' -or $tag -notmatch '^[\x21-\x7E]{1,250}$') {
    Stop-Here "Invalid group tag '$tag' — must be ASCII with no spaces. Fix `$env:AP_TAG and re-run."
    return
}

try {
    Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # --- EDITION GATE (SKU-based, not localized Caption): Autopilot needs Pro/Enterprise; Home is unsupported ---
    $os = Get-CimInstance Win32_OperatingSystem
    $homeSkus = 98, 99, 100, 101    # CoreN, CoreSingleLanguage, CoreCountrySpecific, Core (all "Home")
    $isHome = ($homeSkus -contains [int]$os.OperatingSystemSKU) -or ($os.Caption -match 'Home')
    if ($isHome) {
        Write-Host "This device is '$($os.Caption)' (Home). Windows HOME cannot Entra-join or run Autopilot." -ForegroundColor Red
        if ($env:AP_PROKEY) {
            Write-Host "Upgrading to Pro with AP_PROKEY (changepk) — it will reboot; RE-RUN this one-liner after reboot." -ForegroundColor Yellow
            changepk.exe /productkey $env:AP_PROKEY
            if ($LASTEXITCODE -ne 0) {
                Stop-Here "changepk failed (exit $LASTEXITCODE) — key invalid or the edition upgrade was blocked. Use a real, purchased Pro key, or apply it in Settings > Activation."
                return
            }
            Stop-Here "If it didn't reboot automatically, reboot manually, then re-run the one-liner." 'Yellow'
            return
        }
        Write-Host "M365 Business Premium does NOT include Home->Pro upgrade rights — you need a PURCHASED Windows 11 Pro key." -ForegroundColor Red
        Write-Host "Then: set `$env:AP_PROKEY='<your-real-Pro-key>' and re-run, or apply Pro in Settings>Activation, reboot, re-run." -ForegroundColor Red
        Stop-Here "(The generic VK7JG-... key only gives UNACTIVATED Pro and won't be licensed — don't rely on it.)" 'DarkYellow'
        return
    }
    Write-Host "Edition OK: $($os.Caption)" -ForegroundColor Green

    # --- connectivity pre-check (clearer than a downstream Graph error) ---
    if (-not (Test-NetConnection graph.microsoft.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        Stop-Here "No HTTPS to graph.microsoft.com. Connect Wi-Fi/Ethernet at OOBE first, then re-run."
        return
    }

    # --- PSGallery prereqs (a fresh OOBE has no provider yet). -Force bypasses the untrusted-repo prompt,
    #     so we DON'T flip PSGallery to Trusted globally. ---
    $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue
    Install-Script -Name Get-WindowsAutopilotInfo -Force -Scope CurrentUser -ErrorAction Stop

    # --- resolve the script path robustly (this session's PATH isn't refreshed after Install-Script) ---
    $apScript = $null
    try { $apScript = (Get-Command Get-WindowsAutopilotInfo.ps1 -ErrorAction Stop).Source } catch {}
    if (-not $apScript) { try { $apScript = Join-Path (Get-InstalledScript Get-WindowsAutopilotInfo).InstalledLocation 'Get-WindowsAutopilotInfo.ps1' } catch {} }
    if (-not $apScript -or -not (Test-Path $apScript)) { Stop-Here "Couldn't locate Get-WindowsAutopilotInfo.ps1 after install. Re-run, or check PSGallery access."; return }

    Write-Host "`nUploading hardware hash + WAITING for profile assignment (can take ~10-15 min)..." -ForegroundColor Yellow
    Write-Host "At the sign-in: use an Intune Admin and pick 'No, sign in to this app only' (NOT a Windows sign-in)." -ForegroundColor Yellow

    # Run the community uploader in a CHILD PowerShell so its internal `exit` can't close THIS window.
    # The child appends its own transcript to the same log; release ours first to avoid a write lock.
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    $inner = "try { Start-Transcript -Path '$LogFile' -Append -Force | Out-Null } catch {}; try { & '$apScript' -Online -GroupTag '$tag' -Assign; `$ec=`$LASTEXITCODE } catch { Write-Host ('ERROR: ' + `$_.Exception.Message) -ForegroundColor Red; `$ec=99 }; try { Stop-Transcript | Out-Null } catch {}; if (`$null -eq `$ec) { `$ec = 0 }; exit `$ec"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $inner
    $code = $LASTEXITCODE
    try { Start-Transcript -Path $LogFile -Append -Force -ErrorAction Stop | Out-Null } catch {}
    if ($code -ne 0) { Stop-Here "Autopilot registration FAILED (uploader exit code $code). Open the log for the real error."; return }

    Write-Host "`nSUCCESS — registered to Autopilot (tag '$tag') and profile ASSIGNED." -ForegroundColor Green
    if ($env:AP_NOSHUTDOWN) {
        Stop-Here "AP_NOSHUTDOWN set — not powering off. Power off before shipping (don't sign into Windows); or for your OWN device, reboot into the Autopilot OOBE and sign in as yourself." 'Yellow'
    } else {
        Write-Host "Powering off in 20s so you can ship it. DO NOT sign into Windows.  (Log: $LogFile)" -ForegroundColor Green
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
        Start-Sleep -Seconds 20
        shutdown /s /t 0
    }
}
catch {
    Stop-Here "FAILED: $($_.Exception.Message)`nNot powered off so you can retry. Check: network connected? signed in as an Intune Admin? group-tag profile assigned in Intune?"
}
