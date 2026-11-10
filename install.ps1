#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer for agent-blindfold (Codename: Heart-Under-Blade)
    Installs the PreToolUse Hook globally for Google Antigravity and/or Claude Code.
.AUTHOR
    zanex - https://github.com/zanex
#>

param(
    [ValidateSet("all", "antigravity", "claude")]
    [string]$Target = "all"
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$RepoRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuardPs1  = (Join-Path $RepoRoot "scripts\guard.ps1") -replace '\\', '/'
$GuardCmd  = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$GuardPs1`""

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  agent-blindfold | Codename: Heart-Under-Blade" -ForegroundColor Cyan
Write-Host "  Zero-Trust Media Privacy & Anti-Ban Shield Installer" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# 1. Install for Google Antigravity (~/.gemini/config/hooks.json & plugin)
if ($Target -eq "all" -or $Target -eq "antigravity") {
    $agyPluginDir = Join-Path $env:USERPROFILE ".gemini\config\plugins\agent-blindfold"
    New-Item -ItemType Directory -Force -Path (Join-Path $agyPluginDir "scripts") | Out-Null

    Copy-Item -Path (Join-Path $RepoRoot "plugin.json") -Destination (Join-Path $agyPluginDir "plugin.json") -Force
    Copy-Item -Path (Join-Path $RepoRoot "hooks.json")  -Destination (Join-Path $agyPluginDir "hooks.json")  -Force
    Copy-Item -Path (Join-Path $RepoRoot "scripts\guard.ps1") -Destination (Join-Path $agyPluginDir "scripts\guard.ps1") -Force
    Copy-Item -Path (Join-Path $RepoRoot "scripts\guard.sh")  -Destination (Join-Path $agyPluginDir "scripts\guard.sh")  -Force

    Write-Host "[+] Installed Antigravity Global Plugin to: $agyPluginDir" -ForegroundColor Green
}

# 2. Install for Claude Code (~/.claude/settings.json)
if ($Target -eq "all" -or $Target -eq "claude") {
    $claudeDir = Join-Path $env:USERPROFILE ".claude"
    if (Test-Path $claudeDir) {
        $claudeGuardDir = Join-Path $claudeDir "hooks\agent-blindfold"
        New-Item -ItemType Directory -Force -Path $claudeGuardDir | Out-Null
        $installedPs1 = Join-Path $claudeGuardDir "guard.ps1"
        Copy-Item -Path (Join-Path $RepoRoot "scripts\guard.ps1") -Destination $installedPs1 -Force
        Write-Host "[+] Copied Claude Code Hook script to: $installedPs1" -ForegroundColor Green
    } else {
        Write-Host "[i] ~/.claude not found; skipped Claude Code hook copy (Antigravity plugin active)." -ForegroundColor Yellow
    }
}

Write-Host "`n[OK] agent-blindfold is now active! Your private stash is physically shielded." -ForegroundColor Green
