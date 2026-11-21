#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer & uninstaller for agent-blindfold v1.2 (Codename: Heart-Under-Blade)
    Supports Google Antigravity (Plugin + SessionStart/PreToolUse Hooks + Rule) and Claude Code (Lossless settings.json merge).
.AUTHOR
    zanex-dev - https://github.com/zanex-dev
#>

param(
    [ValidateSet("all", "antigravity", "claude")]
    [string]$Target = "all",

    [ValidateSet("timed", "permanent", "off")]
    [string]$AutoGrant = "timed",

    [string]$DefaultTTL = "2h",

    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HomeRoot = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE } elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }

function Get-EffectiveHomeDir { return $HomeRoot }
. (Join-Path $RepoRoot 'scripts/grant_store.ps1')

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  agent-blindfold v1.2 | Codename: Heart-Under-Blade" -ForegroundColor Cyan
if ($Uninstall) {
    Write-Host "  Mode: UNINSTALL" -ForegroundColor Yellow
} else {
    Write-Host "  Mode: INSTALL (Target: $Target, AutoGrant: $AutoGrant, TTL: $DefaultTTL)" -ForegroundColor Cyan
}
Write-Host "================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 0. Global SessionStart Auto-Exemption Policy (~/.gemini/config/agent-blindfold.json)
# ------------------------------------------------------------------------------
$geminiConfigDir = Join-Path $HomeRoot ".gemini\config"
$policyFile      = Join-Path $geminiConfigDir "agent-blindfold.json"
$agyPluginDir    = Join-Path $HomeRoot ".gemini\config\plugins\agent-blindfold"
$claudeDir       = Join-Path $HomeRoot ".claude"
$claudeGuardDir  = Join-Path $claudeDir "hooks\agent-blindfold"

if (-not $Uninstall) {
    $explicitPolicyChange = $PSBoundParameters.ContainsKey('AutoGrant') -or $PSBoundParameters.ContainsKey('DefaultTTL')
    if ((-not (Test-Path -LiteralPath $policyFile)) -or $explicitPolicyChange) {
        New-Item -ItemType Directory -Force -Path $geminiConfigDir | Out-Null
        $polObj = [ordered]@{
            sessionAutoGrant = $AutoGrant
            defaultTTL       = $DefaultTTL
            updatedAt        = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        }
        if ($AutoGrant -eq 'timed' -and (Convert-DurationToSeconds $DefaultTTL) -le 0) { throw 'Invalid time-to-live' }
        Write-StateJson $policyFile $polObj
        Write-Host "[+] Configured SessionStart auto-exemption policy ($AutoGrant / $DefaultTTL): $policyFile" -ForegroundColor Green
    } else {
        Write-Host "[i] Preserved existing SessionStart policy: $policyFile" -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------------------------------
# 1. Google Antigravity (~/.gemini/config/plugins/agent-blindfold)
# ------------------------------------------------------------------------------
if ($Target -eq "all" -or $Target -eq "antigravity") {

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

        Copy-Item -LiteralPath (Join-Path $RepoRoot "plugin.json")               -Destination (Join-Path $agyPluginDir "plugin.json")               -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "hooks.json")                -Destination (Join-Path $agyPluginDir "hooks.json")                -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "blindfold-control.cmd")     -Destination (Join-Path $agyPluginDir "blindfold-control.cmd")     -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "rules\AGENTS.md")           -Destination (Join-Path $agyPluginDir "rules\AGENTS.md")           -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\guard.ps1")         -Destination (Join-Path $agyPluginDir "scripts\guard.ps1")         -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\guard.sh")          -Destination (Join-Path $agyPluginDir "scripts\guard.sh")          -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\session_start.ps1") -Destination (Join-Path $agyPluginDir "scripts\session_start.ps1") -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\session_start.sh")  -Destination (Join-Path $agyPluginDir "scripts\session_start.sh")  -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\unlock.ps1")        -Destination (Join-Path $agyPluginDir "scripts\unlock.ps1")        -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\unlock.sh")         -Destination (Join-Path $agyPluginDir "scripts\unlock.sh")         -Force

        foreach ($file in @('grant_store.ps1','grant_store.py','guard.py','session_start.py','unlock.py','python_runtime.sh')) {
            Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts/$file") -Destination (Join-Path $agyPluginDir "scripts/$file") -Force
        }
        Write-Host "[+] Installed Antigravity Global Plugin (SessionStart + PreToolUse + Rule): $agyPluginDir" -ForegroundColor Green
    }
}

# ------------------------------------------------------------------------------
# 2. Claude Code (~/.claude/settings.json + ~/.claude/hooks/agent-blindfold)
# ------------------------------------------------------------------------------
function Remove-BlindfoldEntries {
    param([object[]]$Entries, [string[]]$Owned)
    $out = @()
    foreach ($entry in $Entries) {
        if (-not $entry -or -not $entry.PSObject.Properties['hooks'] -or @($entry.hooks).Count -eq 0) {
            $out += $entry
            continue
        }
        $kept = @($entry.hooks | Where-Object { $_.type -ne 'command' -or $_.command -cnotin $Owned })
        if ($kept.Count -gt 0) {
            $entry.hooks = $kept
            $out += $entry
        }
    }
    return ,$out
}

if ($Target -eq "all" -or $Target -eq "claude") {
    $claudeDir      = Join-Path $HomeRoot ".claude"
    $claudeGuardDir = Join-Path $claudeDir "hooks\agent-blindfold"
    $claudeSettings = Join-Path $claudeDir "settings.json"

    $guardNorm = ((Join-Path $claudeGuardDir 'guard.ps1') -replace '\\','/') -replace "'", "''"
    $sessionNorm = ((Join-Path $claudeGuardDir 'session_start.ps1') -replace '\\','/') -replace "'", "''"
    $oldGuardCmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command . '$guardNorm'"
    $hookCmd = "$oldGuardCmd -HookHost claude"
    $sessionCmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command . '$sessionNorm'"
    if ($Uninstall) {
        if (Test-Path -LiteralPath $claudeSettings) {
            try {
                $rawJson = [System.IO.File]::ReadAllText($claudeSettings, $utf8NoBom)
                $cfg = $rawJson | ConvertFrom-Json
                if ($null -ne $cfg.PSObject.Properties['hooks']) {
                    if ($null -ne $cfg.hooks.PSObject.Properties['PreToolUse']) {
                        $filteredPre = Remove-BlindfoldEntries -Entries @($cfg.hooks.PreToolUse) -Owned @($oldGuardCmd,$hookCmd)
                        $cfg.hooks.PreToolUse = @($filteredPre)
                    }
                    if ($null -ne $cfg.hooks.PSObject.Properties['SessionStart']) {
                        $filteredSes = Remove-BlindfoldEntries -Entries @($cfg.hooks.SessionStart) -Owned @($sessionCmd)
                        if ($filteredSes.Count -eq 0) {
                            $cfg.hooks.PSObject.Properties.Remove('SessionStart')
                        } else {
                            $cfg.hooks.SessionStart = @($filteredSes)
                        }
                    }
                    Write-StateJson $claudeSettings $cfg
                    Write-Host "[-] Cleaned agent-blindfold entries from: $claudeSettings" -ForegroundColor Green
                }
            } catch {
                throw "Could not clean Claude settings. Hook scripts retained. $_"
            }
        }
        if (Test-Path -LiteralPath $claudeGuardDir) {
            Remove-Item -LiteralPath $claudeGuardDir -Recurse -Force
            Write-Host "[-] Removed Claude Code hook scripts: $claudeGuardDir" -ForegroundColor Green
        }
    } else {
        if ((Test-Path -LiteralPath $claudeDir) -or ($Target -eq "claude")) {
            New-Item -ItemType Directory -Force -Path $claudeGuardDir | Out-Null
            $installedGuardPs1   = Join-Path $claudeGuardDir "guard.ps1"
            $installedSessionPs1 = Join-Path $claudeGuardDir "session_start.ps1"
            $installedUnlockPs1  = Join-Path $claudeGuardDir "unlock.ps1"

            Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\guard.ps1")         -Destination $installedGuardPs1   -Force
            Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\session_start.ps1") -Destination $installedSessionPs1 -Force
            Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\unlock.ps1")        -Destination $installedUnlockPs1  -Force

            Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/grant_store.ps1') -Destination (Join-Path $claudeGuardDir 'grant_store.ps1') -Force

            $cfg = New-Object PSObject
            if (Test-Path -LiteralPath $claudeSettings) {
                Copy-Item -LiteralPath $claudeSettings -Destination ($claudeSettings + ".bak") -Force
                $rawJson = [System.IO.File]::ReadAllText($claudeSettings, $utf8NoBom)
                if (-not [string]::IsNullOrWhiteSpace($rawJson)) {
                    $cfg = $rawJson | ConvertFrom-Json
                }
            }

            if ($null -eq $cfg.PSObject.Properties['hooks']) {
                $cfg | Add-Member -MemberType NoteProperty -Name 'hooks' -Value (New-Object PSObject)
            }
            if ($null -eq $cfg.hooks.PSObject.Properties['PreToolUse']) {
                $cfg.hooks | Add-Member -MemberType NoteProperty -Name 'PreToolUse' -Value @()
            }
            if ($null -eq $cfg.hooks.PSObject.Properties['SessionStart']) {
                $cfg.hooks | Add-Member -MemberType NoteProperty -Name 'SessionStart' -Value @()
            }

            $retainedPre = Remove-BlindfoldEntries -Entries @($cfg.hooks.PreToolUse) -Owned @($oldGuardCmd,$hookCmd)
            $newPreEntry = [ordered]@{
                matcher = "Read|View|NotebookRead|Write|Edit|MultiEdit|NotebookEdit|Bash|mcp__.*"
                hooks   = @(
                    [ordered]@{
                        type    = "command"
                        command = $hookCmd
                    }
                )
            }
            $retainedPre += ([PSCustomObject]$newPreEntry)
            $cfg.hooks.PreToolUse = @($retainedPre)

            $retainedSes = Remove-BlindfoldEntries -Entries @($cfg.hooks.SessionStart) -Owned @($sessionCmd)
            $newSesEntry = [ordered]@{
                hooks = @(
                    [ordered]@{
                        type    = "command"
                        command = $sessionCmd
                    }
                )
            }
            $retainedSes += ([PSCustomObject]$newSesEntry)
            $cfg.hooks.SessionStart = @($retainedSes)

            Write-StateJson $claudeSettings $cfg
            Write-Host "[+] Merged SessionStart & PreToolUse hooks into Claude Code settings: $claudeSettings" -ForegroundColor Green
        } else {
            Write-Host "[i] ~/.claude not detected; skipped Claude Code setup (pass '-Target claude' to force)." -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
if ($Uninstall) {
    if ((-not (Test-Path -LiteralPath $agyPluginDir)) -and (-not (Test-Path -LiteralPath $claudeGuardDir))) {
        Remove-UninstalledGrants
        if (Test-Path -LiteralPath $policyFile) {
            Assert-StatePath $policyFile
            Remove-Item -LiteralPath $policyFile -Force
            Write-Host "[-] Removed global policy config: $policyFile" -ForegroundColor Green
        }
    }
    Write-Host "[OK] agent-blindfold has been cleanly uninstalled." -ForegroundColor Green
} else {
    Write-Host "[OK] agent-blindfold installed for the selected target ($Target). Check the effective policy with unlock.ps1 -Status." -ForegroundColor Green
}
