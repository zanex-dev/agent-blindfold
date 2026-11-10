#Requires -Version 5.1
<#
.SYNOPSIS
    agent-blindfold (Codename: Heart-Under-Blade) v1.1 -- SessionStart Auto-Exemption Hook
    Automatically issues a timed (TTL) or permanent '.allow_media' pass at session startup
    according to ~/.gemini/config/agent-blindfold.json (or environment overrides),
    while strictly skipping personal vaults and chat-only read-only workspaces.
.AUTHOR
    zanex-dev - https://github.com/zanex-dev
.LICENSE
    MIT License - Copyright (c) 2026 zanex
#>

$ErrorActionPreference = 'Stop'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom

$HardVaultDirs = @('pictures', 'videos', 'music', 'appdata')
$PersonalContainerDirs = @('desktop', 'downloads', 'documents')

function Get-EffectiveHomeDir {
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $env:USERPROFILE }
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { return $env:HOME }
    return [Environment]::GetFolderPath('UserProfile')
}

function Convert-DurationToSeconds {
    param([string]$Spec)
    if ([string]::IsNullOrWhiteSpace($Spec)) { return $null }
    $s = $Spec.Trim().ToLowerInvariant()
    if ($s -match '^(\d+)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)?$') {
        $val = [int64]$Matches[1]
        $unit = if ($Matches[2]) { $Matches[2] } else { 's' }
        switch -Regex ($unit) {
            '^s' { return $val }
            '^m' { return ($val * 60) }
            '^h' { return ($val * 3600) }
            '^d' { return ($val * 86400) }
        }
    }
    return $null
}

function Emit-SessionOutput {
    param(
        [bool]$IsClaudeCode,
        [string]$SystemNotice = ""
    )
    if ($IsClaudeCode) {
        # Neutral exit 0 with empty stdout on Claude Code
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($SystemNotice)) {
        $jsonLine = "{}`n"
    } else {
        $payload = [ordered]@{
            injectSteps = @(
                [ordered]@{
                    systemMessage = [ordered]@{
                        systemMessage = $SystemNotice
                    }
                }
            )
        }
        $jsonLine = ($payload | ConvertTo-Json -Compress -Depth 6) + "`n"
    }
    $bytes = $utf8NoBom.GetBytes($jsonLine)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
    exit 0
}

function Normalize-LocalPath {
    param([string]$RawPath)
    if ([string]::IsNullOrWhiteSpace($RawPath)) { return "" }
    $cleaned = $RawPath.Trim().Trim('"').Trim("'")
    if ($cleaned -match '^(?i)file://') {
        $cleaned = $cleaned -replace '[?#].*$', ''
        try { $cleaned = [Uri]::UnescapeDataString($cleaned) } catch {}
        if ($cleaned -match '^(?i)file:///+([A-Za-z]:.*)$') {
            $cleaned = $Matches[1]
        } else {
            $cleaned = $cleaned -replace '^(?i)file://+', '/'
        }
    }
    $cleaned = [Environment]::ExpandEnvironmentVariables($cleaned)
    $homeDir = Get-EffectiveHomeDir
    if ($cleaned.StartsWith('~')) {
        $rest = $cleaned.Substring(1)
        if ($rest.Length -eq 0 -or $rest.StartsWith('/') -or $rest.StartsWith('\')) {
            $cleaned = Join-Path $homeDir $rest.TrimStart('/', '\')
        }
    }
    try {
        $current = [System.IO.Path]::GetFullPath($cleaned)
        for ($hop = 0; $hop -lt 16; $hop++) {
            $resolvedHop = $false
            $probe = $current
            $tailParts = New-Object System.Collections.Generic.List[string]
            while (-not [string]::IsNullOrWhiteSpace($probe)) {
                if (Test-Path -LiteralPath $probe) {
                    $item = Get-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                    if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and $item.Target) {
                        $targetVal = if ($item.Target -is [array]) { [string]$item.Target[0] } else { [string]$item.Target }
                        $targetVal = ($targetVal -replace '^(?i)\\\\\?\\UNC\\', '\\') -replace '^(?i)(?:\\\\\?\\|\\\?\?\\)', ''
                        if (-not [string]::IsNullOrWhiteSpace($targetVal)) {
                            if (-not [System.IO.Path]::IsPathRooted($targetVal)) {
                                $targetVal = Join-Path (Split-Path -Parent $probe) $targetVal
                            }
                            $rebuilt = $targetVal
                            for ($i = $tailParts.Count - 1; $i -ge 0; $i--) {
                                $rebuilt = Join-Path $rebuilt $tailParts[$i]
                            }
                            $current = [System.IO.Path]::GetFullPath($rebuilt)
                            $resolvedHop = $true
                            break
                        }
                    }
                }
                $parent = Split-Path -Parent $probe
                if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
                $tailParts.Add((Split-Path -Leaf $probe))
                $probe = $parent
            }
            if (-not $resolvedHop) { return $current }
        }
        return ""
    } catch {
        return ""
    }
}

function Test-IsSubPath {
    param([string]$TargetNorm, [string]$WorkspaceNorm)
    $t = $TargetNorm.TrimEnd('\', '/').ToLowerInvariant()
    $w = $WorkspaceNorm.TrimEnd('\', '/').ToLowerInvariant()
    if ([string]::IsNullOrEmpty($t) -or [string]::IsNullOrEmpty($w)) { return $false }
    if ($t -eq $w) { return $true }
    return $t.StartsWith($w + "\") -or $t.StartsWith($w + "/")
}

function Test-IsValidEngineeringWorkspace {
    param([string]$WsPath)
    if ([string]::IsNullOrWhiteSpace($WsPath)) { return $false }
    $normWs = (Normalize-LocalPath $WsPath).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($normWs)) { return $false }
    if ($normWs -match '^[A-Za-z]:$') { return $false }

    $homeNorm = (Normalize-LocalPath (Get-EffectiveHomeDir)).TrimEnd('\', '/')
    # Reject $HOME itself AND any ancestor of $HOME (e.g. C:\, C:\Users, /, /Users, /home)
    if (Test-IsSubPath -TargetNorm $homeNorm -WorkspaceNorm $normWs) { return $false }

    $geminiRoot = Join-Path $homeNorm '.gemini'
    $claudeRoot = Join-Path $homeNorm '.claude'
    if ($normWs.ToLowerInvariant() -eq $geminiRoot.ToLowerInvariant()) { return $false }
    if (Test-IsSubPath -TargetNorm $normWs -WorkspaceNorm (Join-Path $geminiRoot 'config')) { return $false }
    if (Test-IsSubPath -TargetNorm $normWs -WorkspaceNorm $claudeRoot) { return $false }
    foreach ($fl in @('antigravity', 'antigravity-cli', 'antigravity-ide')) {
        $agyDir = Join-Path $geminiRoot $fl
        if ($normWs.ToLowerInvariant() -eq $agyDir.ToLowerInvariant()) { return $false }
        if (Test-IsSubPath -TargetNorm $normWs -WorkspaceNorm (Join-Path $agyDir 'brain')) { return $false }
    }

    foreach ($seg in ($normWs -split '[\\/]+')) {
        if (-not [string]::IsNullOrWhiteSpace($seg) -and ($HardVaultDirs -contains $seg.ToLowerInvariant())) {
            return $false
        }
    }

    $leaf = [System.IO.Path]::GetFileName($normWs).ToLowerInvariant()
    if ($PersonalContainerDirs -contains $leaf) { return $false }
    if (-not (Test-Path -LiteralPath $normWs -PathType Container)) { return $false }

    # Skip pure chat / read-only workspaces (e.g. 'chat' folder or AGENTS.md declaring read-only chat mode)
    if ($leaf -eq 'chat') { return $false }
    foreach ($ruleFile in @('AGENTS.md', 'GEMINI.md')) {
        $rp = Join-Path $normWs $ruleFile
        if (Test-Path -LiteralPath $rp -PathType Leaf) {
            try {
                $head = [System.IO.File]::ReadAllText($rp, $utf8NoBom)
                if ($head -match '(?i)(chat-only|read-only mode|\u7eaf\u65e5\u5e38\u5bf9\u8bdd|\u7eaf\u804a\u5929|\u4e25\u683c\u53ea\u8bfb)') {
                    return $false
                }
            } catch {}
        }
    }

    return $true
}

function Ensure-GitLocalExclude {
    param([string]$WorkspaceNorm)
    $excludeFile = Join-Path (Join-Path (Join-Path $WorkspaceNorm '.git') 'info') 'exclude'
    if (Test-Path -LiteralPath $excludeFile -PathType Leaf) {
        try {
            $existing = [System.IO.File]::ReadAllText($excludeFile, $utf8NoBom)
            if ($existing -notmatch '(?m)^\s*\.allow_media\s*$') {
                $prefix = if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { "`n" } else { "" }
                [System.IO.File]::AppendAllText($excludeFile, "${prefix}.allow_media`n", $utf8NoBom)
            }
        } catch {}
    }
}

try {
    $rawInput = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        Emit-SessionOutput -IsClaudeCode $false
    }
    $data = $rawInput | ConvertFrom-Json
} catch {
    Emit-SessionOutput -IsClaudeCode $false
}

$isClaude = (($null -ne $data.PSObject.Properties['hook_event_name']) -or ($null -ne $data.PSObject.Properties['session_id'])) -and ($null -eq $data.PSObject.Properties['conversationId'])

# Load global policy from ~/.gemini/config/agent-blindfold.json (with env overrides)
$autoGrantMode = "timed"
$defaultTTL = "2h"

$policyPath = Join-Path (Join-Path (Join-Path (Get-EffectiveHomeDir) '.gemini') 'config') 'agent-blindfold.json'
if (Test-Path -LiteralPath $policyPath -PathType Leaf) {
    try {
        $pol = [System.IO.File]::ReadAllText($policyPath, $utf8NoBom) | ConvertFrom-Json
        if ($null -ne $pol.PSObject.Properties['sessionAutoGrant'] -and -not [string]::IsNullOrWhiteSpace([string]$pol.sessionAutoGrant)) {
            $autoGrantMode = ([string]$pol.sessionAutoGrant).Trim().ToLowerInvariant()
        }
        if ($null -ne $pol.PSObject.Properties['defaultTTL'] -and -not [string]::IsNullOrWhiteSpace([string]$pol.defaultTTL)) {
            $defaultTTL = ([string]$pol.defaultTTL).Trim().ToLowerInvariant()
        }
    } catch {}
}

if (-not [string]::IsNullOrWhiteSpace($env:AGENT_BLINDFOLD_AUTO_GRANT)) {
    $autoGrantMode = $env:AGENT_BLINDFOLD_AUTO_GRANT.Trim().ToLowerInvariant()
}
if (-not [string]::IsNullOrWhiteSpace($env:AGENT_BLINDFOLD_DEFAULT_TTL)) {
    $defaultTTL = $env:AGENT_BLINDFOLD_DEFAULT_TTL.Trim().ToLowerInvariant()
}

if ($autoGrantMode -in @('off', 'false', 'none', 'manual', 'sandbox_only')) {
    Emit-SessionOutput -IsClaudeCode $isClaude
}

$rawWorkspaces = New-Object System.Collections.Generic.List[string]
if ($null -ne $data.PSObject.Properties['workspacePaths'] -and $null -ne $data.workspacePaths) {
    foreach ($ws in $data.workspacePaths) {
        if ($ws -is [string] -and -not [string]::IsNullOrWhiteSpace($ws)) {
            $rawWorkspaces.Add($ws)
        }
    }
}
if ($null -ne $data.PSObject.Properties['cwd'] -and $data.cwd -is [string] -and -not [string]::IsNullOrWhiteSpace($data.cwd)) {
    $rawWorkspaces.Add($data.cwd)
}

$grantedWorkspaces = New-Object System.Collections.Generic.List[string]
$effectiveSummaryMode = $autoGrantMode
$nowSec = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

foreach ($ws in $rawWorkspaces) {
    if (-not (Test-IsValidEngineeringWorkspace $ws)) { continue }
    $normWs = (Normalize-LocalPath $ws).TrimEnd('\', '/')
    if ($grantedWorkspaces -contains $normWs) { continue }

    $markerPath = Join-Path $normWs '.allow_media'

    # Preserve an existing explicit permanent pass if already present in this workspace
    $alreadyPermanent = $false
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        try {
            $existingRaw = [System.IO.File]::ReadAllText($markerPath, $utf8NoBom).Trim()
            if ($existingRaw -match '^(?i)(permanent|forever)$') {
                $alreadyPermanent = $true
            } elseif ($existingRaw.StartsWith('{')) {
                $existingObj = $existingRaw | ConvertFrom-Json
                if ($null -ne $existingObj.PSObject.Properties['mode'] -and ([string]$existingObj.mode).Trim().ToLowerInvariant() -in @('permanent', 'forever')) {
                    $alreadyPermanent = $true
                }
            }
        } catch {}
    }

    if ($alreadyPermanent) {
        $effectiveSummaryMode = "permanent"
        $grantedWorkspaces.Add($normWs)
        continue
    }

    if ($autoGrantMode -in @('permanent', 'forever')) {
        $tokenObj = [ordered]@{
            version   = 1
            mode      = "permanent"
            issued_at = $nowSec
            issued_by = "session_start"
        }
        $effectiveSummaryMode = "permanent"
    } else {
        $ttlSec = Convert-DurationToSeconds $defaultTTL
        if ($null -eq $ttlSec -or $ttlSec -le 0) {
            $ttlSec = 7200
            $defaultTTL = "2h"
        }
        $tokenObj = [ordered]@{
            version     = 1
            mode        = "timed"
            ttl         = $defaultTTL
            ttl_seconds = $ttlSec
            issued_at   = $nowSec
            expires_at  = ($nowSec + $ttlSec)
            issued_by   = "session_start"
        }
        $effectiveSummaryMode = "timed ($defaultTTL)"
    }

    try {
        $tokenJson = ($tokenObj | ConvertTo-Json -Depth 4) + "`n"
        [System.IO.File]::WriteAllText($markerPath, $tokenJson, $utf8NoBom)
        Ensure-GitLocalExclude -WorkspaceNorm $normWs
        $grantedWorkspaces.Add($normWs)
    } catch {}
}

if ($grantedWorkspaces.Count -gt 0) {
    $notice = "[agent-blindfold] Engineering media exemption automatically granted at session start (mode: $effectiveSummaryMode). Reading project media assets, .svg icons, and Playwright/sandbox screenshots inside the active workspace is permitted; personal directories and modifying .allow_media remain strictly blocked."
    Emit-SessionOutput -IsClaudeCode $isClaude -SystemNotice $notice
}

Emit-SessionOutput -IsClaudeCode $isClaude
