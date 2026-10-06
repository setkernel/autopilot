#!/usr/bin/env bash
# Offline checks: parse register.ps1, and lint it when PSScriptAnalyzer is installed.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v pwsh >/dev/null 2>&1 || { echo "check: pwsh is not installed" >&2; exit 1; }
pwsh -NoProfile -NonInteractive -Command '
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path register.ps1), [ref]$null, [ref]$errors) | Out-Null
  if ($errors) { $errors | ForEach-Object { Write-Error $_.ToString() }; exit 1 }
  "check: register.ps1 parses"
  if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $findings = Invoke-ScriptAnalyzer -Path register.ps1 -Severity Error
    if ($findings) { $findings | Format-Table -AutoSize | Out-String | Write-Error; exit 1 }
    "check: PSScriptAnalyzer found no errors"
  } else {
    "check: PSScriptAnalyzer not installed; lint skipped (Install-Module PSScriptAnalyzer -Scope CurrentUser)"
  }
'
echo "check: ok"
