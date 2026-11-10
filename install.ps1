#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer & uninstaller for agent-blindfold (Codename: Heart-Under-Blade)
    Supports Google Antigravity (Plugin + Hook + Rule) and Claude Code (Non-destructive settings.json merge).
.AUTHOR
    zanex - https://github.com/zanex
#>

param(
    [ValidateSet("all", "antigravity", "claude")]
    [string]$Target = "all",

    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  agent-blindfold | Codename: Heart-Under-Blade" -ForegroundColor Cyan
if ($Uninstall) {
    Write-Host "  Mode: UNINSTALL" -ForegroundColor Yellow
} else {
    Write-Host "  Mode: INSTALL (Target: $Target)" -ForegroundColor Cyan
}
Write-Host "================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Google Antigravity (~/.gemini/config/plugins/agent-blindfold)
# ------------------------------------------------------------------------------
if ($Target -eq "all" -or $Target -eq "antigravity") {
    $agyPluginDir = Join-Path $env:USERPROFILE ".gemini\config\plugins\agent-blindfold"

    if ($Uninstall) {
        if (Test-Path -LiteralPath $agyPluginDir) {
            Remove-Item -LiteralPath $agyPluginDir -Recurse -Force
            Write-Host "[-] Removed Antigravity plugin: $agyPluginDir" -ForegroundColor Green
        } else {
            Write-Host "[i] Antigravity plugin not found (already clean)." -ForegroundColor DarkGray
        }
    } else {
        New-Item -ItemType Directory -Force -Path (Join-Path $agyPluginDir "scripts") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $agyPluginDir "rules")   | Out-Null

        Copy-Item -LiteralPath (Join-Path $RepoRoot "plugin.json")       -Destination (Join-Path $agyPluginDir "plugin.json")       -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "hooks.json")        -Destination (Join-Path $agyPluginDir "hooks.json")        -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "rules\AGENTS.md")   -Destination (Join-Path $agyPluginDir "rules\AGENTS.md")   -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\guard.ps1") -Destination (Join-Path $agyPluginDir "scripts\guard.ps1") -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\guard.sh")  -Destination (Join-Path $agyPluginDir "scripts\guard.sh")  -Force

        Write-Host "[+] Installed Antigravity Global Plugin (Hook + Rule): $agyPluginDir" -ForegroundColor Green
    }
}

# ------------------------------------------------------------------------------
# 2. Claude Code (~/.claude/settings.json + ~/.claude/hooks/agent-blindfold)
# ------------------------------------------------------------------------------
if ($Target -eq "all" -or $Target -eq "claude") {
    $claudeDir      = Join-Path $env:USERPROFILE ".claude"
    $claudeGuardDir = Join-Path $claudeDir "hooks\agent-blindfold"
    $claudeSettings = Join-Path $claudeDir "settings.json"

    if ($Uninstall) {
        if (Test-Path -LiteralPath $claudeGuardDir) {
            Remove-Item -LiteralPath $claudeGuardDir -Recurse -Force
            Write-Host "[-] Removed Claude Code hook scripts: $claudeGuardDir" -ForegroundColor Green
        }
        if (Test-Path -LiteralPath $claudeSettings) {
            try {
                $rawJson = [System.IO.File]::ReadAllText($claudeSettings, $utf8NoBom)
                $cfg = $rawJson | ConvertFrom-Json
                if ($null -ne $cfg.PSObject.Properties['hooks'] -and $null -ne $cfg.hooks.PSObject.Properties['PreToolUse']) {
                    $filtered = @()
                    foreach ($entry in $cfg.hooks.PreToolUse) {
                        $isBlindfold = $false
                        if ($null -ne $entry.PSObject.Properties['hooks']) {
                            foreach ($h in $entry.hooks) {
                                if ($null -ne $h.PSObject.Properties['command'] -and $h.command -match 'agent-blindfold') {
                                    $isBlindfold = $true
                                }
                            }
                        }
                        if (-not $isBlindfold) { $filtered += $entry }
                    }
                    $cfg.hooks.PreToolUse = $filtered
                    $updatedJson = ($cfg | ConvertTo-Json -Depth 10) + "`n"
                    [System.IO.File]::WriteAllText($claudeSettings, $updatedJson, $utf8NoBom)
                    Write-Host "[-] Cleaned agent-blindfold entry from: $claudeSettings" -ForegroundColor Green
                }
            } catch {
                Write-Host "[!] Could not auto-clean ${claudeSettings}: $_" -ForegroundColor Yellow
            }
        }
    } else {
        if ((Test-Path -LiteralPath $claudeDir) -or ($Target -eq "claude")) {
            New-Item -ItemType Directory -Force -Path $claudeGuardDir | Out-Null
            $installedPs1 = Join-Path $claudeGuardDir "guard.ps1"
            Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\guard.ps1") -Destination $installedPs1 -Force

            $normPs1 = ($installedPs1 -replace '\\', '/') -replace "'", "''"
            # Use dot-sourcing with single quotes (no double quotes or '&') so Windows 'cmd /c' CreateProcess never injects '\"'
            $hookCmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command . '$normPs1'"

            $cfg = [ordered]@{}
            if (Test-Path -LiteralPath $claudeSettings) {
                Copy-Item -LiteralPath $claudeSettings -Destination ($claudeSettings + ".bak") -Force
                $rawJson = [System.IO.File]::ReadAllText($claudeSettings, $utf8NoBom)
                if (-not [string]::IsNullOrWhiteSpace($rawJson)) {
                    $cfg = $rawJson | ConvertFrom-Json
                }
            } else {
                $cfg = New-Object PSObject
            }

            if ($null -eq $cfg.PSObject.Properties['hooks']) {
                $cfg | Add-Member -MemberType NoteProperty -Name 'hooks' -Value (New-Object PSObject)
            }
            if ($null -eq $cfg.hooks.PSObject.Properties['PreToolUse']) {
                $cfg.hooks | Add-Member -MemberType NoteProperty -Name 'PreToolUse' -Value @()
            }

            # Remove any existing agent-blindfold entry for idempotency
            $retained = @()
            foreach ($entry in $cfg.hooks.PreToolUse) {
                $isBlindfold = $false
                if ($null -ne $entry.PSObject.Properties['hooks']) {
                    foreach ($h in $entry.hooks) {
                        if ($null -ne $h.PSObject.Properties['command'] -and $h.command -match 'agent-blindfold') {
                            $isBlindfold = $true
                        }
                    }
                }
                if (-not $isBlindfold) { $retained += $entry }
            }

            $newEntry = [ordered]@{
                matcher = "Read|View|NotebookRead|Bash|mcp__.*"
                hooks   = @(
                    [ordered]@{
                        type    = "command"
                        command = $hookCmd
                    }
                )
            }
            $retained += ([PSCustomObject]$newEntry)
            $cfg.hooks.PreToolUse = $retained

            $outJson = ($cfg | ConvertTo-Json -Depth 10) + "`n"
            [System.IO.File]::WriteAllText($claudeSettings, $outJson, $utf8NoBom)
            Write-Host "[+] Merged PreToolUse hook into Claude Code settings: $claudeSettings" -ForegroundColor Green
        } else {
            Write-Host "[i] ~/.claude not detected; skipped Claude Code setup (pass '-Target claude' to force)." -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
if ($Uninstall) {
    Write-Host "[OK] agent-blindfold has been cleanly uninstalled." -ForegroundColor Green
} else {
    Write-Host "[OK] agent-blindfold is active! Your private stash is physically shielded." -ForegroundColor Green
}
