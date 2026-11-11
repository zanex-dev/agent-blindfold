#Requires -Version 5.1
<#
.SYNOPSIS
    agent-blindfold (Codename: Heart-Under-Blade) v1.1
    Zero-trust local media privacy & anti-ban PreToolUse Hook for Google Antigravity & Claude Code.
    Includes Tier 0 Engineering Sandbox Auto-Exemption, Timed/Permanent .allow_media v2 Passes, and Anti-Tamper Guard.
.AUTHOR
    zanex-dev - https://github.com/zanex-dev
.LICENSE
    MIT License - Copyright (c) 2026 zanex
#>

$ErrorActionPreference = 'Stop'

# Force UTF-8 without BOM for stdin/stdout to guarantee clean JSON without encoding corruption or extra escaping
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom

$MediaExtensions = @(
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.ico', '.heic', '.heif', '.avif',
    '.mp4', '.mkv', '.avi', '.mov', '.webm', '.flv', '.wmv',
    '.mp3', '.wav', '.flac', '.m4a', '.ogg', '.aac'
)

# Tier 1A: Always-locked personal vaults (never unlockable even as a workspace or with .allow_media)
$HardVaultDirs = @('pictures', 'videos', 'music', 'appdata')

# Tier 1B: Personal container directories (locked when accessed directly or opened as root workspace;
# dedicated project subdirectories inside them follow Tier 3 workspace rules)
$PersonalContainerDirs = @('desktop', 'downloads', 'documents')

# Protected control files that AI Agents must never forge, modify, or delete
$ProtectedControlLeaves = @('.allow_media', 'agent-blindfold.json')
$ReadOnlyToolNames = @(
    'read_file', 'view_file', 'read_resource', 'list_dir', 'find_by_name', 'grep_search',
    'Read', 'View', 'NotebookRead', 'Glob', 'Grep', 'LS'
)

# Decode UTF-8 Chinese messages from Base64 so PowerShell 5.1 without BOM never misparses source literals
$EnPersonal  = "Blocked by agent-blindfold (Heart-Under-Blade): Access to personal or external media files is strictly forbidden."
$ZhPersonal  = $utf8NoBom.GetString([Convert]::FromBase64String("6Kem5Y+R5YWo5bGA5aqS5L2T6ZqQ56eB6ZqU56a76ZOB5b6L77ya5Lil56aB6K+75Y+W5oiW6Kem56Kw5Liq5Lq655uu5b2V5Y+K5aSW6YOo55uu5b2V55qE5Zu+54mH5LiO6Z+z6KeG6aKR5paH5Lu244CC"))

$EnWorkspace = "Blocked by agent-blindfold (Heart-Under-Blade): Workspace media is isolated by default. Ask the user to grant a timed or permanent '.allow_media' pass via the unlock script (Agents must never create it themselves)."
$ZhWorkspace = $utf8NoBom.GetString([Convert]::FromBase64String("6Kem5Y+R5YWo5bGA5aqS5L2T6ZqQ56eB6ZqU56a76ZOB5b6L77ya5bel5L2c5Yy65YaF5aqS5L2T5paH5Lu26buY6K6k6ZqU56a75oum5oiq77yI5aaC6ZyA5pS+6KGM77yM6K+35o+Q56S655So5oi35Zyo5pys5Zyw6L+Q6KGMIHVubG9jayDohJrmnKzkuIvlj5HpmZDml7bmiJbmsLjkuYUgLmFsbG93X21lZGlhIOmAmuihjOivge+8jOS4peemgSBBZ2VudCDoh6rooYzliJvlu7rvvInjgII="))

$EnExpired   = "Blocked by agent-blindfold (Heart-Under-Blade): Workspace '.allow_media' timed pass has expired and was automatically cleaned up. Ask the user to renew it if still needed."
$ZhExpired   = $utf8NoBom.GetString([Convert]::FromBase64String("6Kem5Y+R5YWo5bGA5aqS5L2T6ZqQ56eB6ZqU56a76ZOB5b6L77ya5b2T5YmN5bel5L2c5Yy655qEIC5hbGxvd19tZWRpYSDpmZDml7bosYHlhY3pgJrooYzor4Hlt7LliLDmnJ/lpLHmlYjlubboh6rliqjlm57mlLbvvIjlpoLku43pnIDor7vlj5bvvIzor7fmj5DnpLrnlKjmiLfph43mlrDkuIvlj5HvvInjgII="))

$EnTamper    = "Blocked by agent-blindfold (Heart-Under-Blade): AI Agents are strictly forbidden from creating, modifying, or forging '.allow_media' passes or firewall policy files."
$ZhTamper    = $utf8NoBom.GetString([Convert]::FromBase64String("6Kem5Y+R5YWo5bGA5aqS5L2T6ZqQ56eB6ZqU56a76ZOB5b6L77ya5Lil56aBIEFJIOaZuuiDveS9k+iHquihjOWIm+W7uuOAgeS/ruaUueaIluS8qumAoCAuYWxsb3dfbWVkaWEg6LGB5YWN6YCa6KGM6K+B5Y+K6Ziy54Gr5aKZ562W55Wl6YWN572u44CC"))

$langMode = if ($env:AGENT_BLINDFOLD_LANG) { $env:AGENT_BLINDFOLD_LANG.Trim().ToLowerInvariant() } else { "bilingual" }
switch ($langMode) {
    "en" {
        $ReasonPersonalOrExternal = $EnPersonal
        $ReasonWorkspaceDefault   = $EnWorkspace
        $ReasonWorkspaceExpired   = $EnExpired
        $ReasonTamper             = $EnTamper
    }
    "zh" {
        $ReasonPersonalOrExternal = $ZhPersonal
        $ReasonWorkspaceDefault   = $ZhWorkspace
        $ReasonWorkspaceExpired   = $ZhExpired
        $ReasonTamper             = $ZhTamper
    }
    default {
        $ReasonPersonalOrExternal = "$EnPersonal | $ZhPersonal"
        $ReasonWorkspaceDefault   = "$EnWorkspace | $ZhWorkspace"
        $ReasonWorkspaceExpired   = "$EnExpired | $ZhExpired"
        $ReasonTamper             = "$EnTamper | $ZhTamper"
    }
}

function Get-EffectiveHomeDir {
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $env:USERPROFILE }
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { return $env:HOME }
    return [Environment]::GetFolderPath('UserProfile')
}

function Get-NowUnixSeconds {
    return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
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

function Emit-Response {
    param(
        [Parameter(Mandatory = $true)][string]$Decision,
        [Parameter(Mandatory = $false)][string]$Reason = "",
        [Parameter(Mandatory = $false)][bool]$IsClaudeCode = $false
    )
    if ($IsClaudeCode) {
        if ($Decision -eq 'deny') {
            $payload = [ordered]@{
                hookSpecificOutput = [ordered]@{
                    hookEventName            = "PreToolUse"
                    permissionDecision       = "deny"
                    permissionDecisionReason = $Reason
                }
            }
            $jsonLine = ($payload | ConvertTo-Json -Compress -Depth 5) + "`n"
            $bytes = $utf8NoBom.GetBytes($jsonLine)
            $stdout = [Console]::OpenStandardOutput()
            $stdout.Write($bytes, 0, $bytes.Length)
            $stdout.Flush()
        }
        # On allow in Claude Code: exit 0 with empty stdout (neutral pass-through; preserves user permission prompts)
        exit 0
    } else {
        $payload = [ordered]@{
            decision = $Decision
        }
        if (-not [string]::IsNullOrEmpty($Reason)) {
            $payload['reason'] = $Reason
        }
        $jsonLine = ($payload | ConvertTo-Json -Compress -Depth 5) + "`n"
        $bytes = $utf8NoBom.GetBytes($jsonLine)
        $stdout = [Console]::OpenStandardOutput()
        $stdout.Write($bytes, 0, $bytes.Length)
        $stdout.Flush()
        exit 0
    }
}

function Test-IsWebOrNonLocalUri {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $true }
    $t = $Raw.Trim().Trim('"').Trim("'")
    return $t -match '^(?i)(https?|wss?|data|mailto|about|chrome|javascript|blob):'
}

function Normalize-LocalPath {
    param(
        [string]$RawPath,
        [string]$BaseDir = ""
    )
    if ([string]::IsNullOrWhiteSpace($RawPath)) { return "" }
    $cleaned = $RawPath.Trim().Trim('"').Trim("'")

    if ($cleaned -match '^(?i)file://') {
        $cleaned = $cleaned -replace '[?#].*$', ''
        try {
            $cleaned = [Uri]::UnescapeDataString($cleaned)
        } catch {}
        if ($cleaned -match '^(?i)file:///+([A-Za-z]:.*)$') {
            $cleaned = $Matches[1]
        } else {
            $cleaned = $cleaned -replace '^(?i)file://+', '/'
        }
    }

    $cleaned = [Environment]::ExpandEnvironmentVariables($cleaned)
    $homeDir = Get-EffectiveHomeDir
    if ($cleaned -match '^\$HOME([\\/].*)?$') {
        $sub = if ($Matches[1]) { $Matches[1].TrimStart('/', '\') } else { "" }
        $cleaned = if ($sub) { Join-Path $homeDir $sub } else { $homeDir }
    } elseif ($cleaned -match '^\$env:USERPROFILE([\\/].*)?$') {
        $sub = if ($Matches[1]) { $Matches[1].TrimStart('/', '\') } else { "" }
        $cleaned = if ($sub) { Join-Path $homeDir $sub } else { $homeDir }
    } elseif ($cleaned.StartsWith('~')) {
        $rest = $cleaned.Substring(1)
        if ($rest.Length -eq 0 -or $rest.StartsWith('/') -or $rest.StartsWith('\')) {
            $cleaned = Join-Path $homeDir $rest.TrimStart('/', '\')
        }
    }

    # Strip Windows NTFS Alternate Data Streams (e.g. foo.png::$DATA) and trailing Win32 dots/spaces
    $cleaned = $cleaned -replace '(?<=.{2})::?[A-Za-z0-9_.$]+$', ''
    $cleaned = $cleaned.TrimEnd('.', ' ')

    # Replace shell wildcards temporarily so .NET 4.8 Path APIs never throw on '*.png'
    $cleanedSafe = ($cleaned -replace '\*', '__WC_STAR__') -replace '\?', '__WC_Q__'

    try {
        if (-not [System.IO.Path]::IsPathRooted($cleanedSafe) -and -not [string]::IsNullOrWhiteSpace($BaseDir)) {
            $cleanedSafe = Join-Path $BaseDir $cleanedSafe
        }
        $current = [System.IO.Path]::GetFullPath($cleanedSafe)

        # Iteratively resolve up to 16 hops of file symlinks and directory junctions/reparse points
        for ($hop = 0; $hop -lt 16; $hop++) {
            $resolvedHop = $false
            $probe = $current
            $tailParts = New-Object System.Collections.Generic.List[string]
            while (-not [string]::IsNullOrWhiteSpace($probe)) {
                if (($probe -notmatch '__WC_') -and (Test-Path -LiteralPath $probe)) {
                    $item = Get-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                    if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and $item.Target) {
                        $targetVal = if ($item.Target -is [array]) { [string]$item.Target[0] } else { [string]$item.Target }
                        $targetVal = ($targetVal -replace '^(?i)\\\\\?\\UNC\\', '\\') -replace '^(?i)(?:\\\\\?\\|\\\?\?\\)', ''
                        if (-not [string]::IsNullOrWhiteSpace($targetVal)) {
                            if (-not [System.IO.Path]::IsPathRooted($targetVal)) {
                                $parentOfProbe = Split-Path -Parent $probe
                                $targetVal = Join-Path $parentOfProbe $targetVal
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
            if (-not $resolvedHop) {
                return $current
            }
        }
        # Circular symlink/junction loop (>16 hops): fail closed into HardVault sentinel
        return (Join-Path (Join-Path (Get-EffectiveHomeDir) 'Pictures') '__reparse_loop_blocked__.png')
    } catch {
        return $cleanedSafe
    }
}

function Get-PathSegmentsLower {
    param([string]$NormPath)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($seg in ($NormPath -split '[\\/]+')) {
        if (-not [string]::IsNullOrWhiteSpace($seg)) {
            $result.Add($seg.ToLowerInvariant())
        }
    }
    return $result
}

function Test-InHardVault {
    param([string]$NormPath)
    foreach ($seg in (Get-PathSegmentsLower $NormPath)) {
        if ($HardVaultDirs -contains $seg) { return $true }
    }
    return $false
}

function Test-InPersonalContainer {
    param([string]$NormPath)
    foreach ($seg in (Get-PathSegmentsLower $NormPath)) {
        if ($PersonalContainerDirs -contains $seg) { return $true }
    }
    return $false
}

function Test-IsSubPath {
    param(
        [string]$TargetNorm,
        [string]$WorkspaceNorm
    )
    $t = $TargetNorm.TrimEnd('\', '/').ToLowerInvariant()
    $w = $WorkspaceNorm.TrimEnd('\', '/').ToLowerInvariant()
    if ([string]::IsNullOrEmpty($t) -or [string]::IsNullOrEmpty($w)) { return $false }
    if ($t -eq $w) { return $true }
    return $t.StartsWith($w + "\") -or $t.StartsWith($w + "/")
}

function Test-IsValidProjectWorkspace {
    param([string]$WsPath)
    if ([string]::IsNullOrWhiteSpace($WsPath)) { return $false }
    $normWs = (Normalize-LocalPath $WsPath).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($normWs)) { return $false }

    if ($normWs -match '^[A-Za-z]:$') { return $false }

    $homeNorm = (Normalize-LocalPath (Get-EffectiveHomeDir)).TrimEnd('\', '/')
    # Reject $HOME itself AND any ancestor of $HOME (e.g. C:\, C:\Users, /, /Users, /home)
    if (Test-IsSubPath -TargetNorm $homeNorm -WorkspaceNorm $normWs) { return $false }

    # Reject internal agent config/hook/brain roots as workspaces (while allowing scratch/<subproject>)
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

    if (Test-InHardVault $normWs) { return $false }

    $leaf = [System.IO.Path]::GetFileName($normWs).ToLowerInvariant()
    if ($PersonalContainerDirs -contains $leaf) { return $false }

    return $true
}

function Test-IsProtectedControlTarget {
    param(
        [string]$RawTarget,
        [string]$BaseDir
    )
    if (Test-IsWebOrNonLocalUri $RawTarget) { return $false }
    $norm = (Normalize-LocalPath -RawPath $RawTarget -BaseDir $BaseDir).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($norm)) { return $false }
    $leaf = [System.IO.Path]::GetFileName($norm).ToLowerInvariant()
    if ($ProtectedControlLeaves -contains $leaf) { return $true }

    # Protect installed plugin/hook directories and host hook configuration manifests from self-tampering
    $homeNorm = (Normalize-LocalPath (Get-EffectiveHomeDir)).TrimEnd('\', '/')
    $agyPluginInstalled = Join-Path (Join-Path (Join-Path $homeNorm '.gemini') 'config') 'plugins\agent-blindfold'
    $agyGlobalHooks     = Join-Path (Join-Path (Join-Path $homeNorm '.gemini') 'config') 'hooks.json'
    $claudeHookInstalled = Join-Path (Join-Path $homeNorm '.claude') 'hooks\agent-blindfold'
    $claudeSettingsFile  = Join-Path (Join-Path $homeNorm '.claude') 'settings.json'
    $claudeLocalSettings = Join-Path (Join-Path $homeNorm '.claude') 'settings.local.json'

    if (Test-IsSubPath -TargetNorm $norm -WorkspaceNorm $agyPluginInstalled) { return $true }
    if (Test-IsSubPath -TargetNorm $norm -WorkspaceNorm $claudeHookInstalled) { return $true }
    if ($norm.ToLowerInvariant() -in @($agyGlobalHooks.ToLowerInvariant(), $claudeSettingsFile.ToLowerInvariant(), $claudeLocalSettings.ToLowerInvariant())) {
        return $true
    }
    if ($leaf -eq 'hooks.json') {
        $parentLeaf = [System.IO.Path]::GetFileName((Split-Path -Parent $norm)).ToLowerInvariant()
        if ($parentLeaf -eq '.agents') { return $true }
    }
    return $false
}

function Test-InOtherBrainSession {
    param(
        [string]$NormTarget,
        [string]$ArtifactDirNorm,
        [string]$ConversationId
    )
    if (-not [string]::IsNullOrWhiteSpace($ArtifactDirNorm) -and (Test-IsSubPath -TargetNorm $NormTarget -WorkspaceNorm $ArtifactDirNorm)) {
        return $false
    }
    $homeNorm = (Normalize-LocalPath (Get-EffectiveHomeDir)).TrimEnd('\', '/')
    foreach ($flavor in @('antigravity', 'antigravity-cli', 'antigravity-ide')) {
        $brainRoot = Join-Path (Join-Path (Join-Path $homeNorm '.gemini') $flavor) 'brain'
        if (Test-IsSubPath -TargetNorm $NormTarget -WorkspaceNorm $brainRoot) {
            $rel = $NormTarget.Substring($brainRoot.Length).TrimStart('\', '/')
            $relParts = @($rel -split '[\\/]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($relParts.Count -ge 1) {
                if (-not [string]::IsNullOrWhiteSpace($ConversationId) -and $relParts[0].ToLowerInvariant() -eq $ConversationId.Trim().ToLowerInvariant()) {
                    return $false
                }
            }
            return $true
        }
    }
    return $false
}

function Test-IsAutoExemptEngineeringSandbox {
    <#
    Tier 0: Auto-exempts Agent-generated engineering artifacts & frontend visual verification screenshots:
      1. Current conversation's artifactDirectoryPath (and ~/.gemini/<antigravity*>/brain/<current-convId>)
      2. Antigravity official project scratchpad subdirectories (~/.gemini/<antigravity*>/scratch/<subproject>/...)
      3. Playwright MCP screenshot directories (<workspace>/.playwright-mcp/...) inside valid project workspaces
    Note: Always called AFTER multi-hop symlink/junction resolution and HardVault rejection.
    #>
    param(
        [string]$NormTarget,
        [AllowEmptyCollection()][string[]]$MatchedWorkspaces = @(),
        [string]$ArtifactDirNorm,
        [string]$ConversationId
    )
    $segs = Get-PathSegmentsLower $NormTarget
    $hasUserUploaded = ($segs -contains '.user_uploaded')

    # 0A: Explicit current session artifactDirectoryPath from Antigravity hook payload
    if (-not [string]::IsNullOrWhiteSpace($ArtifactDirNorm)) {
        if (Test-IsSubPath -TargetNorm $NormTarget -WorkspaceNorm $ArtifactDirNorm) {
            return $true
        }
    }

    # 0B: Antigravity official sandbox roots under ~/.gemini/(antigravity|antigravity-cli|antigravity-ide)
    $homeNorm = (Normalize-LocalPath (Get-EffectiveHomeDir)).TrimEnd('\', '/')
    $agyFlavors = @('antigravity', 'antigravity-cli', 'antigravity-ide')
    foreach ($flavor in $agyFlavors) {
        $agyBase = Join-Path (Join-Path $homeNorm '.gemini') $flavor

        # scratch/<subproject>/<file> (requires at least a dedicated subproject folder, not loose files at scratch root)
        $scratchRoot = Join-Path $agyBase 'scratch'
        if (Test-IsSubPath -TargetNorm $NormTarget -WorkspaceNorm $scratchRoot) {
            $rel = $NormTarget.Substring($scratchRoot.Length).TrimStart('\', '/')
            $relParts = @($rel -split '[\\/]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($relParts.Count -ge 2 -and -not $hasUserUploaded) {
                return $true
            }
        }

        # brain/<convDir>/<file> -- strictly limited to the active ConversationId
        $brainRoot = Join-Path $agyBase 'brain'
        if (Test-IsSubPath -TargetNorm $NormTarget -WorkspaceNorm $brainRoot) {
            $rel = $NormTarget.Substring($brainRoot.Length).TrimStart('\', '/')
            $relParts = @($rel -split '[\\/]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($relParts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($ConversationId) -and $relParts[0].ToLowerInvariant() -eq $ConversationId.Trim().ToLowerInvariant()) {
                return $true
            }
        }
    }

    # 0C: Frontend visual regression & browser preview screenshots (<workspace>/.playwright-mcp/...)
    foreach ($ws in $MatchedWorkspaces) {
        if ($NormTarget.Length -gt $ws.Length) {
            $relWs = $NormTarget.Substring($ws.Length).TrimStart('\', '/')
            $relWsSegs = Get-PathSegmentsLower $relWs
            if ($relWsSegs -contains '.playwright-mcp') {
                return $true
            }
        }
    }

    return $false
}

function Evaluate-AllowMediaPass {
    <#
    Evaluates <workspace>/.allow_media pass v2:
      Returns: 'valid' | 'expired' | 'missing'
      Supports:
        - JSON: {"mode":"permanent"} or {"mode":"timed","expires_at":1794350000}
        - Plain text: "permanent" / "forever" or duration like "30m" / "2h" / "1d" (relative to file mtime)
        - Empty file (legacy compatible): defaults to AGENT_BLINDFOLD_EMPTY_TTL (default "2h", or "permanent")
    #>
    param([string]$MarkerPath)
    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
        return 'missing'
    }

    $nowSec = Get-NowUnixSeconds
    try {
        $item = Get-Item -LiteralPath $MarkerPath -Force
        $mtimeSec = [int64]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
        $rawContent = [System.IO.File]::ReadAllText($MarkerPath, $utf8NoBom).Trim()
    } catch {
        return 'missing'
    }

    # 1. Empty file -> legacy compatibility with safe automatic expiry
    if ([string]::IsNullOrEmpty($rawContent)) {
        $emptySpec = if ($env:AGENT_BLINDFOLD_EMPTY_TTL) { $env:AGENT_BLINDFOLD_EMPTY_TTL.Trim().ToLowerInvariant() } else { '2h' }
        if ($emptySpec -eq 'permanent' -or $emptySpec -eq 'forever' -or $emptySpec -eq '0') {
            return 'valid'
        }
        $ttlSec = Convert-DurationToSeconds $emptySpec
        if ($null -eq $ttlSec) { $ttlSec = 7200 }
        if ($nowSec -le ($mtimeSec + $ttlSec)) {
            return 'valid'
        }
        Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
        return 'expired'
    }

    # 2. Structured JSON token
    if ($rawContent.StartsWith('{')) {
        try {
            $tok = $rawContent | ConvertFrom-Json
            $mode = if ($null -ne $tok.PSObject.Properties['mode'] -and $tok.mode) { ([string]$tok.mode).Trim().ToLowerInvariant() } else { '' }
            if ($mode -eq 'permanent' -or $mode -eq 'forever') {
                return 'valid'
            }
            if ($null -ne $tok.PSObject.Properties['expires_at'] -and $null -ne $tok.expires_at) {
                $exp = [int64]$tok.expires_at
                if ($exp -gt 100000000000) { $exp = [int64][Math]::Floor($exp / 1000) }
                if ($nowSec -le $exp) {
                    return 'valid'
                }
                Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
                return 'expired'
            }
            if ($mode -eq 'timed' -and $null -ne $tok.PSObject.Properties['ttl_seconds'] -and $null -ne $tok.ttl_seconds) {
                $ttl = [int64]$tok.ttl_seconds
                $base = if ($null -ne $tok.PSObject.Properties['issued_at'] -and $null -ne $tok.issued_at) { [int64]$tok.issued_at } else { $mtimeSec }
                if ($nowSec -le ($base + $ttl)) {
                    return 'valid'
                }
                Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
                return 'expired'
            }
        } catch {
            return 'missing'
        }
        return 'missing'
    }

    # 3. Plain-text shorthand ("permanent" or duration "2h" / "30m" / "86400")
    $lowerText = $rawContent.ToLowerInvariant()
    if ($lowerText -eq 'permanent' -or $lowerText -eq 'forever') {
        return 'valid'
    }
    $durSec = Convert-DurationToSeconds $lowerText
    if ($null -ne $durSec) {
        if ($durSec -gt 0 -and $nowSec -le ($mtimeSec + $durSec)) {
            return 'valid'
        }
        Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
        return 'expired'
    }

    # Unrecognized malformed content -> zero-trust fail-closed
    return 'missing'
}

function Test-IsTier0DirectoryAnchor {
    param(
        [string]$NormDir,
        [AllowEmptyCollection()][string[]]$ValidWorkspaces = @(),
        [string]$ArtifactDirNorm = "",
        [string]$ConversationId = ""
    )
    if ([string]::IsNullOrWhiteSpace($NormDir)) { return $false }
    if (Test-InHardVault $NormDir) { return $false }
    if (Test-InOtherBrainSession -NormTarget $NormDir -ArtifactDirNorm $ArtifactDirNorm -ConversationId $ConversationId) { return $false }

    $matchedWs = New-Object System.Collections.Generic.List[string]
    foreach ($ws in $ValidWorkspaces) {
        if (Test-IsSubPath -TargetNorm $NormDir -WorkspaceNorm $ws) {
            $matchedWs.Add($ws)
        }
    }
    $probeFile = Join-Path $NormDir '__tier0_probe__.png'
    return (Test-IsAutoExemptEngineeringSandbox -NormTarget $probeFile -MatchedWorkspaces $matchedWs -ArtifactDirNorm $ArtifactDirNorm -ConversationId $ConversationId)
}

function Test-IsUnlockedWorkspaceDir {
    param(
        [string]$NormDir,
        [AllowEmptyCollection()][string[]]$ValidWorkspaces = @()
    )
    if ([string]::IsNullOrWhiteSpace($NormDir)) { return $false }
    if (Test-InHardVault $NormDir) { return $false }
    foreach ($ws in $ValidWorkspaces) {
        if (Test-IsSubPath -TargetNorm $NormDir -WorkspaceNorm $ws) {
            if ((Evaluate-AllowMediaPass -MarkerPath (Join-Path $ws '.allow_media')) -eq 'valid') {
                return $true
            }
        }
    }
    return $false
}

function Test-IsRelativeNonTraversalToken {
    param([string]$RawTok)
    if ([string]::IsNullOrWhiteSpace($RawTok)) { return $false }
    $t = $RawTok.Trim().Trim('"').Trim("'")
    if ($t -match '^(?i)(?:[A-Za-z]:|[\\/]|~|\$HOME|\$env:USERPROFILE|%USERPROFILE%|file://)') {
        return $false
    }
    foreach ($seg in ($t -split '[\\/]+')) {
        if ($seg -eq '..') { return $false }
    }
    return $true
}

function Evaluate-MediaPath {
    param(
        [string]$RawTarget,
        [string]$BaseDir,
        [AllowEmptyCollection()][string[]]$ValidWorkspaces = @(),
        [string]$ArtifactDirNorm = "",
        [string]$ConversationId = ""
    )
    if (Test-IsWebOrNonLocalUri $RawTarget) { return $null }

    $normTarget = Normalize-LocalPath -RawPath $RawTarget -BaseDir $BaseDir
    if ([string]::IsNullOrWhiteSpace($normTarget)) { return $null }

    $ext = [System.IO.Path]::GetExtension($normTarget).ToLowerInvariant()
    $inHardVault = Test-InHardVault $normTarget
    $inPersonalContainer = Test-InPersonalContainer $normTarget

    $matchedWs = New-Object System.Collections.Generic.List[string]
    foreach ($ws in $ValidWorkspaces) {
        if (Test-IsSubPath -TargetNorm $normTarget -WorkspaceNorm $ws) {
            $matchedWs.Add($ws)
        }
    }

    # Tier 1 Hard Vaults and cross-session brain/<other-id> ALWAYS win before any .svg or Tier 0 sandbox check
    if ($inHardVault -or (Test-InOtherBrainSession -NormTarget $normTarget -ArtifactDirNorm $ArtifactDirNorm -ConversationId $ConversationId)) {
        if ($ext -eq '.svg' -or ($MediaExtensions -contains $ext)) {
            return $ReasonPersonalOrExternal
        }
        return $null
    }

    # Tier 0: Auto-exempted Engineering Sandboxes (scratch/<proj>, current brain/<convId>, .playwright-mcp)
    if (($ext -eq '.svg' -or ($MediaExtensions -contains $ext)) -and (Test-IsAutoExemptEngineeringSandbox -NormTarget $normTarget -MatchedWorkspaces $matchedWs -ArtifactDirNorm $ArtifactDirNorm -ConversationId $ConversationId)) {
        return $null
    }

    # Plain-text vector code (.svg) outside HardVaults and outside raw non-workspace personal containers
    if ($ext -eq '.svg') {
        if ($inPersonalContainer -and $matchedWs.Count -eq 0) { return $ReasonPersonalOrExternal }
        return $null
    }

    if (-not ($MediaExtensions -contains $ext)) {
        return $null
    }

    # Tier 2: Outside any valid dedicated project workspace
    if ($matchedWs.Count -eq 0) {
        return $ReasonPersonalOrExternal
    }

    # Tier 3: Inside a valid dedicated project workspace -> check timed/permanent .allow_media pass
    $sawExpired = $false
    foreach ($ws in $matchedWs) {
        $marker = Join-Path $ws '.allow_media'
        $state = Evaluate-AllowMediaPass -MarkerPath $marker
        if ($state -eq 'valid') {
            return $null
        } elseif ($state -eq 'expired') {
            $sawExpired = $true
        }
    }

    if ($sawExpired) {
        return $ReasonWorkspaceExpired
    }
    return $ReasonWorkspaceDefault
}

try {
    $rawInput = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        Emit-Response -Decision 'allow'
    }
    $data = $rawInput | ConvertFrom-Json
} catch {
    Emit-Response -Decision 'allow'
}

# Detect protocol: Google Antigravity vs Claude Code
$isClaude = ($null -ne $data.PSObject.Properties['tool_name']) -and ($null -eq $data.PSObject.Properties['toolCall'])

$toolName = ""
$argsObj = $null
if (-not $isClaude -and $null -ne $data.PSObject.Properties['toolCall'] -and $null -ne $data.toolCall) {
    if ($null -ne $data.toolCall.PSObject.Properties['name']) { $toolName = [string]$data.toolCall.name }
    if ($null -ne $data.toolCall.PSObject.Properties['args']) { $argsObj = $data.toolCall.args }
} elseif ($isClaude) {
    if ($null -ne $data.PSObject.Properties['tool_name']) { $toolName = [string]$data.tool_name }
    if ($null -ne $data.PSObject.Properties['tool_input']) { $argsObj = $data.tool_input }
}

if ($null -eq $argsObj) {
    Emit-Response -Decision 'allow' -IsClaudeCode $isClaude
}

$conversationId = ""
if ($null -ne $data.PSObject.Properties['conversationId'] -and $data.conversationId -is [string]) {
    $conversationId = $data.conversationId
} elseif ($null -ne $data.PSObject.Properties['session_id'] -and $data.session_id -is [string]) {
    $conversationId = $data.session_id
}

$artifactDirNorm = ""
if ($null -ne $data.PSObject.Properties['artifactDirectoryPath'] -and $data.artifactDirectoryPath -is [string] -and -not [string]::IsNullOrWhiteSpace($data.artifactDirectoryPath)) {
    $candArt = (Normalize-LocalPath $data.artifactDirectoryPath).TrimEnd('\', '/')
    if (-not [string]::IsNullOrWhiteSpace($candArt) -and -not (Test-InHardVault $candArt)) {
        $artifactDirNorm = $candArt
    }
}

# Collect raw workspace paths & determine base directory for relative path resolution
$rawWorkspaces = New-Object System.Collections.Generic.List[string]
if ($null -ne $data.PSObject.Properties['workspacePaths'] -and $null -ne $data.workspacePaths) {
    foreach ($ws in $data.workspacePaths) {
        if ($ws -is [string] -and -not [string]::IsNullOrWhiteSpace($ws)) {
            $rawWorkspaces.Add($ws)
        }
    }
}
$baseDir = ""
if ($null -ne $data.PSObject.Properties['cwd'] -and $data.cwd -is [string] -and -not [string]::IsNullOrWhiteSpace($data.cwd)) {
    $baseDir = Normalize-LocalPath $data.cwd
    $rawWorkspaces.Add($data.cwd)
} elseif ($rawWorkspaces.Count -gt 0) {
    $baseDir = Normalize-LocalPath $rawWorkspaces[0]
}

$validWorkspaces = New-Object System.Collections.Generic.List[string]
foreach ($ws in $rawWorkspaces) {
    if (Test-IsValidProjectWorkspace $ws) {
        $normWs = (Normalize-LocalPath $ws).TrimEnd('\', '/')
        if (-not ($validWorkspaces -contains $normWs)) {
            $validWorkspaces.Add($normWs)
        }
    }
}

# Branch A: Terminal / Shell Command Guard (run_command / Bash / execute_command)
$cmdLine = ""
foreach ($cmdKey in @('CommandLine', 'command', 'cmd')) {
    if ($null -ne $argsObj.PSObject.Properties[$cmdKey] -and $argsObj.$cmdKey -is [string]) {
        $cmdLine = $argsObj.$cmdKey
        break
    }
}

if (-not [string]::IsNullOrWhiteSpace($cmdLine)) {
    $hasChainOp = $cmdLine -match '[;|&<>`\r\n]|\$\(|@\('
    $isPureGitRead = (-not $hasChainOp) -and ($cmdLine -match '^\s*git\s+(?:status|log|diff|branch)\b')
    $isSafeGitRepoOp = (-not $hasChainOp) -and ($cmdLine -match '^\s*git\s+(?:add|mv|commit|status|log|diff|branch|tag|push|pull|fetch)\b')

    # A0: Anti-Tamper Guard -- block Agent attempts to forge/modify .allow_media, policy JSON, installed hooks, or invoke unlock scripts
    if (-not $isPureGitRead) {
        if ($cmdLine -match '(?i)(?:\.allow_media|agent-blindfold\.json|[\\/]\.gemini[\\/]config[\\/](?:plugins[\\/]agent-blindfold|hooks\.json)|[\\/]\.claude[\\/](?:hooks[\\/]agent-blindfold|settings(?:\.local)?\.json)|[\\/]\.agents[\\/]hooks\.json)') {
            Emit-Response -Decision 'deny' -Reason $ReasonTamper -IsClaudeCode $isClaude
        }
    }
    if (-not $isSafeGitRepoOp) {
        if ($cmdLine -match '(?i)(?:blindfold-control(?:\.cmd)?|(?:^|[\s"''`=/\\;|&(>])unlock(?:\.ps1|\.sh)?(?=$|[\s"''`/\\;|&)<]))') {
            Emit-Response -Decision 'deny' -Reason $ReasonTamper -IsClaudeCode $isClaude
        }
    }

    # A1: Block direct directory scans or touches of HardVaultDirs (Pictures, Videos, Music)
    $vaultScanPattern = '(?i)(?:^|[\s"''`=(]|[A-Za-z]:|~|\$HOME|\$env:USERPROFILE|%USERPROFILE%)[\\/](?:Pictures|Videos|Music)(?:[\\/]|[\s"''`;|&)]|$)'
    if ($cmdLine -match $vaultScanPattern) {
        Emit-Response -Decision 'deny' -Reason $ReasonPersonalOrExternal -IsClaudeCode $isClaude
    }

    # A2: Track directory changes (cd / Set-Location / Push-Location) and Tier 0 sandbox anchors in shell scripts
    $safeCdDirs   = New-Object System.Collections.Generic.List[string]
    $unsafeCdDirs = New-Object System.Collections.Generic.List[string]
    $cdPattern = '(?i)(?:^|[;|&(\r\n])\s*(?:cd(?:\s+/d)?|chdir|pushd|Set-Location|Push-Location|sl)\s+(?:-(?:Path|LiteralPath)\s+)?(?:"([^"\r\n]+)"|''([^''\r\n]+)''|([^\s"''`;|&<>()\r\n]+))'
    $runBase = $baseDir
    foreach ($cm in [regex]::Matches($cmdLine, $cdPattern)) {
        $cdRaw = if ($cm.Groups[1].Success) { $cm.Groups[1].Value } elseif ($cm.Groups[2].Success) { $cm.Groups[2].Value } else { $cm.Groups[3].Value }
        if ([string]::IsNullOrWhiteSpace($cdRaw) -or $cdRaw -eq '-') { continue }
        $cdNorm = (Normalize-LocalPath -RawPath $cdRaw -BaseDir $runBase).TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($cdNorm)) { continue }
        $runBase = $cdNorm
        if ((Test-IsTier0DirectoryAnchor -NormDir $cdNorm -ValidWorkspaces $validWorkspaces -ArtifactDirNorm $artifactDirNorm -ConversationId $conversationId) -or
            (Test-IsUnlockedWorkspaceDir -NormDir $cdNorm -ValidWorkspaces $validWorkspaces)) {
            if (-not ($safeCdDirs -contains $cdNorm)) { $safeCdDirs.Add($cdNorm) }
        } else {
            if (-not ($unsafeCdDirs -contains $cdNorm)) { $unsafeCdDirs.Add($cdNorm) }
        }
    }

    $tier0AnchorDirs = New-Object System.Collections.Generic.List[string]
    $anchorLiterals  = New-Object System.Collections.Generic.List[string]
    $rootedPrefixRe  = '^(?i)(?:[A-Za-z]:[\\/]|~[\\/]|\/|\$(?:HOME|env:USERPROFILE)[\\/]|%USERPROFILE%[\\/]|file://)'
    foreach ($qm in [regex]::Matches($cmdLine, '"([^"\r\n]+)"')) {
        $qv = $qm.Groups[1].Value.Trim()
        if ($qv -match $rootedPrefixRe) { $anchorLiterals.Add($qv) }
    }
    foreach ($qm in [regex]::Matches($cmdLine, '''([^''\r\n]+)''')) {
        $qv = $qm.Groups[1].Value.Trim()
        if ($qv -match $rootedPrefixRe) { $anchorLiterals.Add($qv) }
    }
    foreach ($um in [regex]::Matches($cmdLine, '(?i)(?<![A-Za-z0-9_.:/-])((?:[A-Za-z]:[\\/]|~[\\/]|\/(?![\/])|\$(?:HOME|env:USERPROFILE)[\\/]|%USERPROFILE%[\\/]|file://)[^\s"''`;|&<>(),=]+)')) {
        $anchorLiterals.Add($um.Groups[1].Value.Trim())
    }
    foreach ($al in $anchorLiterals) {
        $alNorm = (Normalize-LocalPath -RawPath $al -BaseDir $baseDir).TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($alNorm)) { continue }
        $candDirs = @($alNorm)
        $parentAl = Split-Path -Parent $alNorm
        if (-not [string]::IsNullOrWhiteSpace($parentAl)) { $candDirs += $parentAl }
        foreach ($cdCand in $candDirs) {
            if (Test-IsTier0DirectoryAnchor -NormDir $cdCand -ValidWorkspaces $validWorkspaces -ArtifactDirNorm $artifactDirNorm -ConversationId $conversationId) {
                if (-not ($tier0AnchorDirs -contains $cdCand)) { $tier0AnchorDirs.Add($cdCand) }
                break
            }
        }
    }

    # A3: Extract media file path tokens (double-quoted, single-quoted, or unquoted)
    $extGroup = 'jpg|jpeg|png|gif|webp|bmp|ico|heic|heif|avif|mp4|mkv|avi|mov|webm|flv|wmv|mp3|wav|flac|m4a|ogg|aac|svg'
    $shellTokens = New-Object System.Collections.Generic.List[string]

    foreach ($m in [regex]::Matches($cmdLine, "(?i)`"([^`"\r\n]+\.(?:$extGroup))`"")) {
        $shellTokens.Add($m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($cmdLine, "(?i)'([^'\r\n]+\.(?:$extGroup))'")) {
        $shellTokens.Add($m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($cmdLine, "(?i)(?<![A-Za-z0-9_.:/-])([^\s`"''`|;&<>(),=]+\.(?:$extGroup))(?![A-Za-z0-9_])")) {
        $shellTokens.Add($m.Groups[1].Value)
    }

    $isSafeGitMeta = (-not $hasChainOp) -and ($cmdLine -match '^\s*git\s+(?:commit|status|log|branch|tag|push|pull|fetch)\b')
    $isByteDumper  = (-not $isSafeGitRepoOp) -and ($cmdLine -match '(?i)\b(?:base64|certutil|xxd|hexdump|od|Format-Hex|AsByteStream|ReadAllBytes|ToBase64String|PIL|Pillow|Image\.open|cv2|imread|imageio|pytesseract|tesseract|easyocr|ffmpeg|ffprobe|magick|identify|exiftool|sips|markitdown|cp|mv|scp|rsync|Copy-Item|Move-Item|xcopy|robocopy|copy|move)\b|-Encoding\s+Byte')
    $effectiveBaseDir = if ($safeCdDirs.Count -gt 0 -and $unsafeCdDirs.Count -eq 0) { $safeCdDirs[$safeCdDirs.Count - 1] } else { $baseDir }

    foreach ($tok in $shellTokens) {
        if (Test-IsWebOrNonLocalUri $tok) { continue }
        if ($isSafeGitMeta -and ($tok -notmatch '[\\/]')) { continue }

        $isRelNonTrav = Test-IsRelativeNonTraversalToken $tok

        # Enforce unsafe cd targets first so 'cd ~/Downloads && base64 secret.jpg' is always caught even from an unlocked workspace
        if ($isRelNonTrav -and $unsafeCdDirs.Count -gt 0) {
            foreach ($uDir in $unsafeCdDirs) {
                $uVerdict = Evaluate-MediaPath -RawTarget $tok -BaseDir $uDir -ValidWorkspaces $validWorkspaces -ArtifactDirNorm $artifactDirNorm -ConversationId $conversationId
                if ($uVerdict -eq $ReasonPersonalOrExternal) {
                    Emit-Response -Decision 'deny' -Reason $ReasonPersonalOrExternal -IsClaudeCode $isClaude
                } elseif (($uVerdict -eq $ReasonWorkspaceDefault -or $uVerdict -eq $ReasonWorkspaceExpired) -and $isByteDumper) {
                    Emit-Response -Decision 'deny' -Reason $uVerdict -IsClaudeCode $isClaude
                }
            }
        }

        $verdict = Evaluate-MediaPath -RawTarget $tok -BaseDir $effectiveBaseDir -ValidWorkspaces $validWorkspaces -ArtifactDirNorm $artifactDirNorm -ConversationId $conversationId

        # Allow relative/template output tokens in inline scripts operating on Tier 0 sandboxes (e.g. PIL slicing into brain/<id>/scratch/slice_{idx}.png)
        if ($null -ne $verdict -and $isRelNonTrav -and $unsafeCdDirs.Count -eq 0 -and $tier0AnchorDirs.Count -gt 0) {
            $isTemplateTok = ($tok -match '\{[^}]+\}|%[0-9]*[sdxX]')
            $existsInLockedBase = $false
            if (-not [string]::IsNullOrWhiteSpace($effectiveBaseDir)) {
                $candLocked = Join-Path $effectiveBaseDir $tok
                if ($tok -match '[\*\?]') {
                    if (Get-ChildItem -Path $candLocked -Force -ErrorAction SilentlyContinue | Select-Object -First 1) {
                        $existsInLockedBase = $true
                    }
                } elseif (Test-Path -LiteralPath $candLocked) {
                    $existsInLockedBase = $true
                }
            }
            if (([string]::IsNullOrWhiteSpace($effectiveBaseDir) -or $isTemplateTok) -and (-not $existsInLockedBase)) {
                $verdict = Evaluate-MediaPath -RawTarget $tok -BaseDir $tier0AnchorDirs[0] -ValidWorkspaces $validWorkspaces -ArtifactDirNorm $artifactDirNorm -ConversationId $conversationId
            }
        }

        if ($verdict -eq $ReasonPersonalOrExternal) {
            Emit-Response -Decision 'deny' -Reason $ReasonPersonalOrExternal -IsClaudeCode $isClaude
        } elseif (($verdict -eq $ReasonWorkspaceDefault -or $verdict -eq $ReasonWorkspaceExpired) -and $isByteDumper) {
            Emit-Response -Decision 'deny' -Reason $verdict -IsClaudeCode $isClaude
        }
    }
}

# Branch B: Direct File / Resource / Write / Edit / MCP Tool Argument Inspection
$argSources = New-Object System.Collections.Generic.List[object]
$argSources.Add($argsObj)
foreach ($nestedKey in @('Arguments', 'arguments')) {
    if ($null -ne $argsObj.PSObject.Properties[$nestedKey] -and $null -ne $argsObj.$nestedKey) {
        $argSources.Add($argsObj.$nestedKey)
    }
}

$targetPaths = New-Object System.Collections.Generic.List[string]
$candidateKeys = @(
    'Path', 'path', 'file_path', 'filePath', 'FilePath',
    'AbsolutePath', 'absolutePath', 'TargetFile', 'targetFile',
    'File', 'file', 'Uri', 'uri', 'url', 'Url', 'notebook_path',
    'source', 'destination'
)

foreach ($src in $argSources) {
    foreach ($key in $candidateKeys) {
        if ($null -ne $src.PSObject.Properties[$key]) {
            $val = $src.$key
            if ($val -is [string] -and -not [string]::IsNullOrWhiteSpace($val)) {
                $targetPaths.Add($val)
            }
        }
    }
    foreach ($arrKey in @('Paths', 'paths', 'Files', 'files', 'ImagePaths', 'imagePaths', 'image_paths')) {
        if ($null -ne $src.PSObject.Properties[$arrKey]) {
            $arrVal = $src.$arrKey
            if ($arrVal -is [System.Collections.IEnumerable] -and -not ($arrVal -is [string])) {
                foreach ($item in $arrVal) {
                    if ($item -is [string] -and -not [string]::IsNullOrWhiteSpace($item)) {
                        $targetPaths.Add($item)
                    }
                }
            }
        }
    }
}

$isReadOnlyTool = ($ReadOnlyToolNames -contains $toolName)

foreach ($rawTarget in $targetPaths) {
    # B0: Anti-Tamper Guard -- block any non-read-only tool touching .allow_media, policy JSON, or installed hook files
    if (-not $isReadOnlyTool -and (Test-IsProtectedControlTarget -RawTarget $rawTarget -BaseDir $baseDir)) {
        Emit-Response -Decision 'deny' -Reason $ReasonTamper -IsClaudeCode $isClaude
    }

    $isPureWriteCreateTool = $toolName -in @('write_file', 'write_to_file', 'edit_file', 'replace_file_content', 'multi_replace_file_content', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit')
    if (-not $isPureWriteCreateTool) {
        $verdict = Evaluate-MediaPath -RawTarget $rawTarget -BaseDir $baseDir -ValidWorkspaces $validWorkspaces -ArtifactDirNorm $artifactDirNorm -ConversationId $conversationId
        if ($null -ne $verdict) {
            Emit-Response -Decision 'deny' -Reason $verdict -IsClaudeCode $isClaude
        }
    }
}

Emit-Response -Decision 'allow' -IsClaudeCode $isClaude
