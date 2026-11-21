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
. (Join-Path $PSScriptRoot 'grant_store.ps1')
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$HardVaultDirs = @('pictures', 'videos', 'music', 'appdata')
$PersonalContainerDirs = @('desktop', 'downloads', 'documents')

function Get-EffectiveHomeDir {
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $env:USERPROFILE }
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { return $env:HOME }
    return [Environment]::GetFolderPath('UserProfile')
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

function Test-ValidTargetWorkspace {
    param([string]$PathStr)
    if ([string]::IsNullOrWhiteSpace($PathStr)) { return $false }
    $full = Resolve-RealPath $PathStr
    if ([string]::IsNullOrWhiteSpace($full) -or ($full.TrimEnd('\','/') -eq [IO.Path]::GetPathRoot($full).TrimEnd('\','/'))) { return $false }
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

function Set-GlobalPolicy {
    param([string]$GrantMode, [string]$DefaultTTLSpec)
    $cfgDir = Join-Path (Join-Path (Get-EffectiveHomeDir) '.gemini') 'config'
    if ($GrantMode -eq 'timed' -and (Convert-DurationToSeconds $DefaultTTLSpec) -le 0) { throw 'Invalid policy duration' }
    $polFile = Join-Path $cfgDir 'agent-blindfold.json'
    $polObj = [ordered]@{
        sessionAutoGrant = $GrantMode
        defaultTTL       = $DefaultTTLSpec
        updatedAt        = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    Write-StateJson $polFile $polObj
    Write-Host "[OK] Global SessionStart policy saved -> $polFile (sessionAutoGrant=$GrantMode, defaultTTL=$DefaultTTLSpec)" -ForegroundColor Green
}

function Show-Status {
    param([string]$WsFull)
    $p = Get-GrantPolicy
    Write-Host "Global SessionStart Auto-Grant : $($p.Mode) ($($p.ModeSource)); TTL: $($p.TTL) ($($p.TTLSource))"
    if ($p.Error) { [Console]::Error.WriteLine($p.Error) }
    Write-Host "Target Workspace               : $WsFull"
    $wsReal = Resolve-RealPath $WsFull
    if (-not $wsReal) { throw 'Cannot resolve workspace path' }
    $token = Read-Grant (Get-GrantPath $wsReal)
    if (-not $token) { Write-Host 'Workspace Pass Status          : LOCKED' }
    elseif ($token.mode -eq 'permanent') { Write-Host 'Workspace Pass Status          : UNLOCKED (PERMANENT)' }
    elseif ($token.expires_at -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { Write-Host 'Workspace Pass Status          : EXPIRED' }
    else { Write-Host "Workspace Pass Status          : UNLOCKED (TIMED, until $($token.expires_at) UTC epoch)" }
    if (Test-Path -LiteralPath (Join-Path $WsFull '.allow_media')) {
        Write-Host 'Legacy project marker ignored. Confirm via -Mode timed or permanent to grant locally.'
    }
}

function Issue-WorkspacePass {
    param([string]$WsFull, [string]$PassMode, [string]$TTLSpec)
    if (-not (Test-ValidTargetWorkspace $WsFull)) {
        Write-Error "Refused: '$WsFull' is a personal vault/container root, read-only chat folder, or does not exist. Choose a dedicated engineering project subfolder."
    }
    $WsFull = Resolve-RealPath $WsFull
    $token = Set-WorkspaceGrant $WsFull $PassMode $TTLSpec 'cli_user'
    Write-Host "[OK] Local workspace grant: $($token.mode) -> $WsFull"
}

$targetWs = if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
    if ($Workspace -match '^[A-Za-z]:($|[^\\/])') { throw 'Ambiguous drive-relative workspace selector' }
    [System.IO.Path]::GetFullPath($Workspace)
} else {
    (Get-Location).Path
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
    Remove-WorkspaceGrant (Resolve-RealPath $targetWs)
    Write-Host "[OK] Workspace locked: $targetWs"
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
        if ($wsIn) { $targetWs = [System.IO.Path]::GetFullPath($wsIn) }
        Issue-WorkspacePass -WsFull $targetWs -PassMode 'timed' -TTLSpec '2h'
    }
    "2" {
        $wsIn = (Read-Host "Workspace path [Enter for '$targetWs']").Trim()
        if ($wsIn) { $targetWs = [System.IO.Path]::GetFullPath($wsIn) }
        $customTtl = (Read-Host "Enter TTL (e.g. 30m, 2h, 8h, 1d) [default: 2h]").Trim()
        if (-not $customTtl) { $customTtl = "2h" }
        Issue-WorkspacePass -WsFull $targetWs -PassMode 'timed' -TTLSpec $customTtl
    }
    "3" {
        $wsIn = (Read-Host "Workspace path [Enter for '$targetWs']").Trim()
        if ($wsIn) { $targetWs = [System.IO.Path]::GetFullPath($wsIn) }
        Issue-WorkspacePass -WsFull $targetWs -PassMode 'permanent' -TTLSpec $TTL
    }
    "4" {
        $wsIn = (Read-Host "Workspace path [Enter for '$targetWs']").Trim()
        if ($wsIn) { $targetWs = [System.IO.Path]::GetFullPath($wsIn) }
        Remove-WorkspaceGrant (Resolve-RealPath $targetWs)
        Write-Host "[OK] Workspace locked: $targetWs"
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
