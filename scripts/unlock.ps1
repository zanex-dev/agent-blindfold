#Requires -Version 5.1
<#
.SYNOPSIS
    agent-blindfold (Codename: Heart-Under-Blade) v1.1 -- Pass Issuer & Auto-Grant Policy Controller
    Grants timed (TTL) or permanent '.allow_media' passes to a project workspace, revokes passes,
    or configures the global SessionStart auto-exemption policy (~/.gemini/config/agent-blindfold.json).
.EXAMPLE
    .\scripts\unlock.ps1 -Mode timed -TTL 2h -Workspace C:\path\to\my-app
    .\scripts\unlock.ps1 -Mode permanent -Workspace C:\path\to\my-app
    .\scripts\unlock.ps1 -Lock -Workspace C:\path\to\my-app
    .\scripts\unlock.ps1 -Status -Workspace C:\path\to\my-app
    .\scripts\unlock.ps1 -GlobalAutoGrant timed -TTL 4h
#>

param(
    [ValidateSet("", "timed", "permanent", "interactive")]
    [string]$Mode = "",

    [string]$TTL = "2h",

    [string]$Workspace = "",

    [switch]$Lock,

    [switch]$Status,

    [Alias("SetGlobalAutoGrant")]
    [ValidateSet("", "timed", "permanent", "off")]
    [string]$GlobalAutoGrant = ""
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

function Resolve-RealPath {
    param([string]$PathStr)
    if ([string]::IsNullOrWhiteSpace($PathStr)) { return "" }
    try {
        $current = [System.IO.Path]::GetFullPath($PathStr)
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
            if (-not $resolvedHop) { return $current.TrimEnd('\', '/') }
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

function Test-ValidTargetWorkspace {
    param([string]$PathStr)
    if ([string]::IsNullOrWhiteSpace($PathStr)) { return $false }
    $full = Resolve-RealPath $PathStr
    if ([string]::IsNullOrWhiteSpace($full) -or ($full -match '^[A-Za-z]:$')) { return $false }
    $homeFull = Resolve-RealPath (Get-EffectiveHomeDir)
    if (Test-IsSubPath -TargetNorm $homeFull -WorkspaceNorm $full) { return $false }
    $geminiRoot = Join-Path $homeFull '.gemini'
    $claudeRoot = Join-Path $homeFull '.claude'
    if ($full.ToLowerInvariant() -eq $geminiRoot.ToLowerInvariant()) { return $false }
    if (Test-IsSubPath -TargetNorm $full -WorkspaceNorm (Join-Path $geminiRoot 'config')) { return $false }
    if (Test-IsSubPath -TargetNorm $full -WorkspaceNorm $claudeRoot) { return $false }
    foreach ($fl in @('antigravity', 'antigravity-cli', 'antigravity-ide')) {
        $agyDir = Join-Path $geminiRoot $fl
        if ($full.ToLowerInvariant() -eq $agyDir.ToLowerInvariant()) { return $false }
        if (Test-IsSubPath -TargetNorm $full -WorkspaceNorm (Join-Path $agyDir 'brain')) { return $false }
    }
    foreach ($seg in ($full -split '[\\/]+')) {
        if (-not [string]::IsNullOrWhiteSpace($seg) -and ($HardVaultDirs -contains $seg.ToLowerInvariant())) {
            return $false
        }
    }
    $leaf = [System.IO.Path]::GetFileName($full).ToLowerInvariant()
    if ($PersonalContainerDirs -contains $leaf) { return $false }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return $false }
    if ($leaf -eq 'chat') { return $false }
    foreach ($ruleFile in @('AGENTS.md', 'GEMINI.md')) {
        $rp = Join-Path $full $ruleFile
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
    param([string]$WsFull)
    $excludeFile = Join-Path (Join-Path (Join-Path $WsFull '.git') 'info') 'exclude'
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

function Set-GlobalPolicy {
    param([string]$GrantMode, [string]$DefaultTTLSpec)
    $cfgDir = Join-Path (Join-Path (Get-EffectiveHomeDir) '.gemini') 'config'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $polFile = Join-Path $cfgDir 'agent-blindfold.json'
    $polObj = [ordered]@{
        sessionAutoGrant = $GrantMode
        defaultTTL       = $DefaultTTLSpec
        updatedAt        = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    $jsonOut = ($polObj | ConvertTo-Json -Depth 4) + "`n"
    [System.IO.File]::WriteAllText($polFile, $jsonOut, $utf8NoBom)
    Write-Host "[OK] Global SessionStart policy saved -> $polFile (sessionAutoGrant=$GrantMode, defaultTTL=$DefaultTTLSpec)" -ForegroundColor Green
}

function Show-Status {
    param([string]$WsFull)
    $polFile = Join-Path (Join-Path (Join-Path (Get-EffectiveHomeDir) '.gemini') 'config') 'agent-blindfold.json'
    $gMode = "timed (default)"
    $gTTL  = "2h"
    if (Test-Path -LiteralPath $polFile -PathType Leaf) {
        try {
            $p = [System.IO.File]::ReadAllText($polFile, $utf8NoBom) | ConvertFrom-Json
            if ($p.sessionAutoGrant) { $gMode = $p.sessionAutoGrant }
            if ($p.defaultTTL) { $gTTL = $p.defaultTTL }
        } catch {}
    }
    Write-Host "Global SessionStart Auto-Grant : $gMode (Default TTL: $gTTL)" -ForegroundColor Cyan

    if (-not [string]::IsNullOrWhiteSpace($WsFull) -and (Test-Path -LiteralPath $WsFull -PathType Container)) {
        $marker = Join-Path $WsFull '.allow_media'
        Write-Host "Target Workspace               : $WsFull" -ForegroundColor Cyan
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
            Write-Host "Workspace Pass Status          : LOCKED (no .allow_media)" -ForegroundColor Yellow
            return
        }
        $raw = [System.IO.File]::ReadAllText($marker, $utf8NoBom).Trim()
        $now = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($raw.StartsWith('{')) {
            $tok = $raw | ConvertFrom-Json
            if ($tok.mode -eq 'permanent') {
                Write-Host "Workspace Pass Status          : UNLOCKED (PERMANENT)" -ForegroundColor Green
                return
            }
            if ($tok.expires_at) {
                $rem = [int64]$tok.expires_at - $now
                if ($rem -gt 0) {
                    $mins = [Math]::Round($rem / 60.0, 1)
                    Write-Host "Workspace Pass Status          : UNLOCKED (TIMED, ${mins} min remaining)" -ForegroundColor Green
                } else {
                    Write-Host "Workspace Pass Status          : EXPIRED" -ForegroundColor Yellow
                }
                return
            }
        } elseif ($raw -match '^(?i)(permanent|forever)$') {
            Write-Host "Workspace Pass Status          : UNLOCKED (PERMANENT)" -ForegroundColor Green
            return
        }
        Write-Host "Workspace Pass Status          : PRESENT ($raw)" -ForegroundColor Green
    }
}

function Issue-WorkspacePass {
    param([string]$WsFull, [string]$PassMode, [string]$TTLSpec)
    if (-not (Test-ValidTargetWorkspace $WsFull)) {
        Write-Error "Refused: '$WsFull' is a personal vault/container root, read-only chat folder, or does not exist. Choose a dedicated engineering project subfolder."
    }
    $WsFull = Resolve-RealPath $WsFull
    $marker = Join-Path $WsFull '.allow_media'
    $now = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($PassMode -eq 'permanent') {
        $obj = [ordered]@{
            version   = 1
            mode      = "permanent"
            issued_at = $now
            issued_by = "cli_user"
        }
        $msg = "PERMANENT media exemption granted -> $marker"
    } else {
        $sec = Convert-DurationToSeconds $TTLSpec
        if ($null -eq $sec -or $sec -le 0) {
            Write-Error "Invalid TTL '$TTLSpec'. Use formats like 30m, 2h, 8h, 1d."
        }
        $obj = [ordered]@{
            version     = 1
            mode        = "timed"
            ttl         = $TTLSpec.Trim().ToLowerInvariant()
            ttl_seconds = $sec
            issued_at   = $now
            expires_at  = ($now + $sec)
            issued_by   = "cli_user"
        }
        $msg = "TIMED media exemption ($TTLSpec) granted -> $marker"
    }
    $jsonOut = ($obj | ConvertTo-Json -Depth 4) + "`n"
    [System.IO.File]::WriteAllText($marker, $jsonOut, $utf8NoBom)
    Ensure-GitLocalExclude -WsFull $WsFull
    Write-Host "[OK] $msg" -ForegroundColor Green
}

$targetWs = if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
    ([System.IO.Path]::GetFullPath($Workspace)).TrimEnd('\', '/')
} else {
    (Get-Location).Path.TrimEnd('\', '/')
}

if (-not [string]::IsNullOrWhiteSpace($GlobalAutoGrant)) {
    Set-GlobalPolicy -GrantMode $GlobalAutoGrant -DefaultTTLSpec $TTL
    if (-not $Lock -and -not $Status -and [string]::IsNullOrWhiteSpace($Mode)) {
        exit 0
    }
}

if ($Status) {
    Show-Status -WsFull $targetWs
    exit 0
}

if ($Lock) {
    $marker = Join-Path $targetWs '.allow_media'
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        Remove-Item -LiteralPath $marker -Force
        Write-Host "[OK] Workspace media re-locked (removed $marker)" -ForegroundColor Green
    } else {
        Write-Host "[i] Already locked ($targetWs)" -ForegroundColor DarkGray
    }
    exit 0
}

if ($Mode -eq 'timed' -or $Mode -eq 'permanent') {
    Issue-WorkspacePass -WsFull $targetWs -PassMode $Mode -TTLSpec $TTL
    exit 0
}

# Interactive console wizard when invoked with no flags (e.g. double-clicking blindfold-control.cmd)
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  agent-blindfold (Heart-Under-Blade) Exemption Controller" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Show-Status -WsFull $targetWs
Write-Host ""
Write-Host "  [1] Grant TIMED exemption (2h) to workspace"
Write-Host "  [2] Grant TIMED exemption (custom TTL, e.g. 30m / 8h / 1d)"
Write-Host "  [3] Grant PERMANENT exemption to workspace"
Write-Host "  [4] LOCK workspace immediately (remove .allow_media)"
Write-Host "  [5] Configure Global SessionStart Policy (timed / permanent / off)"
Write-Host "  [Q] Quit"
Write-Host ""
$choice = (Read-Host "Select action [1-5/Q]").Trim().ToUpperInvariant()

switch ($choice) {
    "1" {
        $wsIn = (Read-Host "Workspace path [Enter for '$targetWs']").Trim()
        if ($wsIn) { $targetWs = ([System.IO.Path]::GetFullPath($wsIn)).TrimEnd('\', '/') }
        Issue-WorkspacePass -WsFull $targetWs -PassMode 'timed' -TTLSpec '2h'
    }
    "2" {
        $wsIn = (Read-Host "Workspace path [Enter for '$targetWs']").Trim()
        if ($wsIn) { $targetWs = ([System.IO.Path]::GetFullPath($wsIn)).TrimEnd('\', '/') }
        $customTtl = (Read-Host "Enter TTL (e.g. 30m, 2h, 8h, 1d) [default: 2h]").Trim()
        if (-not $customTtl) { $customTtl = "2h" }
        Issue-WorkspacePass -WsFull $targetWs -PassMode 'timed' -TTLSpec $customTtl
    }
    "3" {
        $wsIn = (Read-Host "Workspace path [Enter for '$targetWs']").Trim()
        if ($wsIn) { $targetWs = ([System.IO.Path]::GetFullPath($wsIn)).TrimEnd('\', '/') }
        Issue-WorkspacePass -WsFull $targetWs -PassMode 'permanent' -TTLSpec $TTL
    }
    "4" {
        $wsIn = (Read-Host "Workspace path [Enter for '$targetWs']").Trim()
        if ($wsIn) { $targetWs = ([System.IO.Path]::GetFullPath($wsIn)).TrimEnd('\', '/') }
        $marker = Join-Path $targetWs '.allow_media'
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            Remove-Item -LiteralPath $marker -Force
            Write-Host "[OK] Workspace media re-locked ($marker)" -ForegroundColor Green
        } else {
            Write-Host "[i] No .allow_media found in $targetWs" -ForegroundColor DarkGray
        }
    }
    "5" {
        $gChoice = (Read-Host "Global SessionStart mode (timed / permanent / off) [default: timed]").Trim().ToLowerInvariant()
        if (-not $gChoice) { $gChoice = "timed" }
        if ($gChoice -notin @('timed', 'permanent', 'off')) {
            Write-Error "Invalid mode '$gChoice'."
        }
        $gTtl = "2h"
        if ($gChoice -eq 'timed') {
            $inTtl = (Read-Host "Default TTL for SessionStart timed passes [default: 2h]").Trim()
            if ($inTtl) { $gTtl = $inTtl }
        }
        Set-GlobalPolicy -GrantMode $gChoice -DefaultTTLSpec $gTtl
    }
}
