<#
register.ps1 - one-shot Windows Autopilot registration, run at OOBE (Shift+F10). SetKernel Digital Inc.

Registers the device CORPORATE to your Intune/Autopilot tenant, waits for the deployment profile to be
assigned, then powers off ready to ship. The end user then powers on and completes the Autopilot OOBE.

  Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://setkernel.net/ap | iex

Flow: edition check (Pro/Enterprise required) -> install Get-WindowsAutopilotInfo ->
      Get-WindowsAutopilotInfo -Online -GroupTag <tag> -Assign  (upload hash, wait for profile) -> power off.
Sign in ONCE at the Graph prompt as an Intune Admin (API auth only - it does NOT put that account on the
device). Don't sign into Windows during build, and never add a work account from Settings (= Personal).

Generic + tenant-agnostic (tenant = whoever signs in) and secret-free - safe to host publicly.
Options (env vars, set before running):
  $env:AP_TAG        group tag / OrderID   (default 'corp'; letters/digits/.-_ only)
  $env:AP_PROKEY     a PURCHASED Windows Pro key to upgrade a Home device (changepk + reboot, then re-run)
  $env:AP_NOSHUTDOWN '1' to skip the power-off (reboot straight into the Autopilot OOBE - e.g. your own device)
                                                                  https://github.com/setkernel/autopilot
#>
$ErrorActionPreference = 'Stop'
$tag = if ($env:AP_TAG) { $env:AP_TAG } else { 'corp' }

# Auto-log everything to a temp file so the error survives even if a sub-script `exit`s the host.
$LogFile = Join-Path $env:TEMP 'setkernel-autopilot.log'
$script:Logging = $false
try { Start-Transcript -Path $LogFile -Force -ErrorAction Stop | Out-Null; $script:Logging = $true } catch {}

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

# Under `irm | iex`, `exit` would close the whole host and the message would vanish - pause + return instead.
function Stop-Here($msg, $color = 'Red') {
    if ($msg) { Write-Host "`n$msg" -ForegroundColor $color }
    if ($script:Logging) {
        Write-Host "`nFull log saved to: $LogFile   (open with: notepad `"$LogFile`")" -ForegroundColor DarkGray
    } else {
        Write-Host "`n(No log file was written - transcript could not start; the on-screen text above is the only record.)" -ForegroundColor DarkGray
    }
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    [void](Read-Host "`nPress Enter to close")
}

Show-Banner
Write-Host "  Registering this device to Autopilot  (group tag: $tag)`n" -ForegroundColor Cyan

# group tag sanity: Autopilot OrderID/GroupTag = ASCII alnum plus . _ - (no spaces, no quoting/shell metachars,
# so '$tag' is always a clean literal inside the child -Command string built below).
if ($tag -notmatch '^[A-Za-z0-9._-]{1,250}$') {
    Stop-Here "Invalid group tag '$tag' - use letters, digits, dot, underscore or hyphen only (no spaces). Fix `$env:AP_TAG and re-run."
    return
}

try {
    Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # --- EDITION GATE (SKU-based, not localized Caption): Autopilot needs Pro/Enterprise; Home is unsupported ---
    $os = Get-CimInstance Win32_OperatingSystem
    $homeSkus = 98, 99, 100, 101    # 98 CoreN, 99 CoreCountrySpecific, 100 CoreSingleLanguage, 101 Core (all "Home")
    $isHome = ($homeSkus -contains [int]$os.OperatingSystemSKU) -or ($os.Caption -match 'Home')
    if ($isHome) {
        Write-Host "This device is '$($os.Caption)' (Home). Windows HOME cannot Entra-join or run Autopilot." -ForegroundColor Red
        if ($env:AP_PROKEY) {
            Write-Host "Upgrading to Pro with AP_PROKEY (changepk) - it will reboot; RE-RUN this one-liner after reboot." -ForegroundColor Yellow
            changepk.exe /productkey $env:AP_PROKEY
            Remove-Item Env:\AP_PROKEY -ErrorAction SilentlyContinue   # license secret: shrink in-session lifetime
            if ($LASTEXITCODE -ne 0) {
                Stop-Here "changepk failed (exit $LASTEXITCODE) - key invalid or the edition upgrade was blocked. Use a real, purchased Pro key, or apply it in Settings > Activation."
                return
            }
            Stop-Here "If it didn't reboot automatically, reboot manually, then re-run the one-liner." 'Yellow'
            return
        }
        Write-Host "M365 Business Premium does NOT include Home->Pro upgrade rights - you need a PURCHASED Windows 11 Pro key." -ForegroundColor Red
        Write-Host "Then: set `$env:AP_PROKEY='<your-real-Pro-key>' and re-run, or apply Pro in Settings>Activation, reboot, re-run." -ForegroundColor Red
        Stop-Here "(The generic VK7JG-... key only gives UNACTIVATED Pro and won't be licensed - don't rely on it.)" 'DarkYellow'
        return
    }
    Write-Host "Edition OK: $($os.Caption)" -ForegroundColor Green

    # --- connectivity pre-check: proxy-aware HTTPS probe (the uploader honors the system proxy; a raw TCP probe does not).
    #     ANY HTTP status back (200/401/403/405/407...) proves reachability; only a total no-response is a real failure. ---
    $ProgressPreference = 'SilentlyContinue'
    try {
        $null = Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec 20 -Uri 'https://graph.microsoft.com/v1.0/$metadata'
    } catch {
        if (-not $_.Exception.Response) {
            Stop-Here "Cannot reach graph.microsoft.com (no HTTP response). Connect Wi-Fi/Ethernet (or configure the OOBE proxy), then re-run."
            return
        }
    }

    # --- PSGallery prereqs (a fresh OOBE has no provider yet). -Force bypasses the untrusted-repo prompt,
    #     so we DON'T flip PSGallery to Trusted globally. (Production: add -RequiredVersion '<validated>'.) ---
    $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue
    Install-Script -Name Get-WindowsAutopilotInfo -Force -Scope CurrentUser -ErrorAction Stop

    # --- resolve the script path robustly (this session's PATH isn't refreshed after Install-Script) ---
    $apScript = $null
    try { $apScript = (Get-Command Get-WindowsAutopilotInfo.ps1 -ErrorAction Stop).Source } catch {}
    if (-not $apScript) { try { $apScript = Join-Path (Get-InstalledScript Get-WindowsAutopilotInfo).InstalledLocation 'Get-WindowsAutopilotInfo.ps1' } catch {} }
    if (-not $apScript -or -not (Test-Path $apScript)) { Stop-Here "Couldn't locate Get-WindowsAutopilotInfo.ps1 after install. Re-run, or check PSGallery access."; return }

    Write-Host "`nUploading hardware hash + WAITING for profile assignment (can take ~10-15 min)..." -ForegroundColor Yellow
    Write-Host "At the sign-in: use an Intune Admin and pick 'No, sign in to this app only' (NOT a Windows sign-in)." -ForegroundColor Yellow
    Write-Host "  ^ that is API auth ONLY; clicking 'OK/Yes' would register/contaminate THIS device with the admin identity." -ForegroundColor Yellow
    Write-Host "FIRST TIME ON THIS TENANT: a consent screen may appear. Tick 'Consent on behalf of your organization'" -ForegroundColor Cyan
    Write-Host "and Accept (needs a GLOBAL ADMIN, or consent already granted to 'Microsoft Graph Command Line Tools'). One-time per tenant." -ForegroundColor Cyan

    # Run the community uploader in a CHILD PowerShell so its internal `exit` can't close THIS window.
    # The child appends its own transcript to the same log; release ours first to avoid a write lock.
    # (TLS 1.2 is per-process, so re-assert it in the child that actually does the module/Graph downloads.)
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    $inner = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; try { Start-Transcript -Path '$LogFile' -Append -Force | Out-Null } catch {}; try { & '$apScript' -Online -GroupTag '$tag' -Assign; `$ec=`$LASTEXITCODE } catch { Write-Host ('ERROR: ' + `$_.Exception.Message) -ForegroundColor Red; `$ec=99 }; try { Stop-Transcript | Out-Null } catch {}; if (`$null -eq `$ec) { `$ec = 0 }; exit `$ec"
    $started = Get-Date
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $inner
    $code = $LASTEXITCODE
    $span = (Get-Date) - $started
    $elapsed = "{0}m {1}s" -f [int][math]::Floor($span.TotalMinutes), $span.Seconds
    try { Start-Transcript -Path $LogFile -Append -Force -ErrorAction Stop | Out-Null; $script:Logging = $true } catch {}

    if ($code -ne 0) {
        $logTail = ''
        try { $logTail = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue } catch {}
        if ($logTail -match 'AADSTS90094|AADSTS65001|need admin approval|admin approval is required|consent_required|admin consent') {
            Stop-Here "ADMIN CONSENT NOT GRANTED. 'Microsoft Graph Command Line Tools' needs one-time admin consent on this tenant. Have a GLOBAL ADMIN sign in (or grant it in Entra > Enterprise apps > 'Microsoft Graph Command Line Tools' > Permissions > Grant admin consent), then re-run. One-time per tenant."
        } elseif ($logTail -match '\b403\b|Forbidden|Authorization_RequestDenied') {
            Stop-Here "AUTHORIZED FAILURE (403/Forbidden). Sign-in worked but that account lacks Intune permission to import Autopilot devices. Sign in as an Intune Administrator (with Autopilot/enrollment rights), confirm consent to 'Microsoft Graph Command Line Tools', then re-run."
        } else {
            Stop-Here "Autopilot registration FAILED (uploader exit code $code) after $elapsed. Open the log for the real error: $LogFile"
        }
        return
    }

    Write-Host "`nSUCCESS - registered to Autopilot (tag '$tag') and profile ASSIGNED in $elapsed." -ForegroundColor Green
    if ($env:AP_NOSHUTDOWN) {
        Stop-Here "AP_NOSHUTDOWN set - not powering off. Power off before shipping (don't sign into Windows); or for your OWN device, reboot into the Autopilot OOBE and sign in as yourself." 'Yellow'
    } else {
        Write-Host "Powering off in 20s so you can ship it. DO NOT sign into Windows." -ForegroundColor Green
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
        Remove-Item $LogFile -Force -ErrorAction SilentlyContinue   # ship path only: don't leave the diagnostic transcript on the device
        Start-Sleep -Seconds 20
        shutdown /s /t 0
    }
}
catch {
    Stop-Here "FAILED: $($_.Exception.Message)`nNot powered off so you can retry. Check: network connected? signed in as an Intune Admin? group-tag profile assigned in Intune?"
}
