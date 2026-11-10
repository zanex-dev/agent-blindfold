#Requires -Version 5.1
<#
.SYNOPSIS
    agent-blindfold (Codename: Heart-Under-Blade)
    Zero-trust local media privacy & anti-ban PreToolUse Hook for Google Antigravity & Claude Code.
.AUTHOR
    zanex - https://github.com/zanex
.LICENSE
    MIT License - Copyright (c) 2026 zanex
#>

$ErrorActionPreference = 'Stop'

# Force UTF-8 without BOM for stdin/stdout to ensure clean JSON without encoding corruption or escaped quotes
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom

$MediaExtensions = @(
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.ico',
    '.mp4', '.mkv', '.avi', '.mov', '.webm', '.flv',
    '.mp3', '.wav', '.flac'
)

$ForbiddenDirs = @(
    'pictures', 'videos', 'desktop', 'downloads', 'documents', 'appdata'
)

# Use UTF-8 byte decoding for Chinese messages so Windows PowerShell 5.1 parses this file identically with or without BOM
$ReasonPersonalOrExternal = $utf8NoBom.GetString([Convert]::FromBase64String("6Kem5Y+R5YWo5bGA5aqS5L2T6ZqQ56eB6ZqU56a76ZOB5b6LIChhZ2VudC1ibGluZGZvbGQp77ya5Lil56aB6K+75Y+W5Liq5Lq655uu5b2V5oiW5aSW6YOo55uu5b2V55qE5Zu+54mH5LiO6Z+z6KeG6aKR5paH5Lu244CC"))
$ReasonWorkspaceDefault   = $utf8NoBom.GetString([Convert]::FromBase64String("6Kem5Y+R5YWo5bGA5aqS5L2T6ZqQ56eB6ZqU56a76ZOB5b6LIChhZ2VudC1ibGluZGZvbGQp77ya5bel5L2c5Yy65YaF5aqS5L2T5paH5Lu26buY6K6k6ZqU56a75oum5oiq77yI5aaC6ZyA5Li05pe25pS+6KGM77yM6K+35Zyo5b2T5YmN5bel5L2c5Yy65qC555uu5b2V5Yib5bu6IC5hbGxvd19tZWRpYSDmoIforrDmlofku7bvvInjgII="))

function Emit-Response {
    param(
        [Parameter(Mandatory = $true)][string]$Decision,
        [Parameter(Mandatory = $false)][string]$Reason = "",
        [Parameter(Mandatory = $false)][bool]$IsClaudeCode = $false
    )
    if ($IsClaudeCode) {
        if ($Decision -eq 'deny') {
            $payload = [ordered]@{
                decision = "block"
                reason   = $Reason
                hookSpecificOutput = [ordered]@{
                    hookEventName            = "PreToolUse"
                    permissionDecision       = "deny"
                    permissionDecisionReason = $Reason
                }
            }
        } else {
            $payload = [ordered]@{
                decision = "approve"
            }
        }
    } else {
        $payload = [ordered]@{
            decision = $Decision
        }
        if (-not [string]::IsNullOrEmpty($Reason)) {
            $payload['reason'] = $Reason
        }
    }

    $jsonLine = ($payload | ConvertTo-Json -Compress -Depth 5) + "`n"
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
    $cleaned = $cleaned -replace '^file:///+', ''
    $cleaned = [Environment]::ExpandEnvironmentVariables($cleaned)
    if ($cleaned.StartsWith('~')) {
        $homeDir = [Environment]::GetFolderPath('UserProfile')
        $cleaned = Join-Path $homeDir $cleaned.Substring(1).TrimStart('/', '\')
    }
    try {
        return [System.IO.Path]::GetFullPath($cleaned)
    } catch {
        return $cleaned
    }
}

function Test-InForbiddenPersonalDir {
    param([string]$NormPath)
    $segments = $NormPath -split '[\\/]+'
    foreach ($seg in $segments) {
        if ([string]::IsNullOrWhiteSpace($seg)) { continue }
        if ($ForbiddenDirs -contains $seg.ToLowerInvariant()) {
            return $true
        }
    }
    return $false
}

function Test-IsSubPath {
    param(
        [string]$TargetPath,
        [string]$WorkspacePath
    )
    $t = (Normalize-LocalPath $TargetPath).TrimEnd('\', '/').ToLowerInvariant()
    $w = (Normalize-LocalPath $WorkspacePath).TrimEnd('\', '/').ToLowerInvariant()
    if ([string]::IsNullOrEmpty($t) -or [string]::IsNullOrEmpty($w)) { return $false }
    if ($t -eq $w) { return $true }
    return $t.StartsWith($w + "\") -or $t.StartsWith($w + "/")
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

# Detect protocol: Antigravity vs Claude Code
$isClaude = ($null -ne $data.PSObject.Properties['tool_name']) -and ($null -eq $data.PSObject.Properties['toolCall'])

$argsObj = $null
if ($null -ne $data.PSObject.Properties['toolCall'] -and $null -ne $data.toolCall.PSObject.Properties['args']) {
    $argsObj = $data.toolCall.args
} elseif ($null -ne $data.PSObject.Properties['tool_input']) {
    $argsObj = $data.tool_input
}

if ($null -eq $argsObj) {
    Emit-Response -Decision 'allow' -IsClaudeCode $isClaude
}

# Extract candidate file paths from tool arguments
$targetPaths = New-Object System.Collections.Generic.List[string]
$candidateKeys = @(
    'Path', 'path', 'file_path', 'filePath', 'FilePath',
    'AbsolutePath', 'absolutePath', 'TargetFile', 'targetFile',
    'File', 'file', 'Uri', 'uri', 'notebook_path'
)

foreach ($key in $candidateKeys) {
    if ($null -ne $argsObj.PSObject.Properties[$key]) {
        $val = $argsObj.$key
        if ($val -is [string] -and -not [string]::IsNullOrWhiteSpace($val)) {
            $targetPaths.Add($val)
        }
    }
}

foreach ($arrKey in @('Paths', 'paths', 'Files', 'files')) {
    if ($null -ne $argsObj.PSObject.Properties[$arrKey]) {
        $arrVal = $argsObj.$arrKey
        if ($arrVal -is [System.Collections.IEnumerable] -and -not ($arrVal -is [string])) {
            foreach ($item in $arrVal) {
                if ($item -is [string] -and -not [string]::IsNullOrWhiteSpace($item)) {
                    $targetPaths.Add($item)
                }
            }
        }
    }
}

if ($targetPaths.Count -eq 0) {
    Emit-Response -Decision 'allow' -IsClaudeCode $isClaude
}

# Extract active workspace roots
$workspaces = New-Object System.Collections.Generic.List[string]
if ($null -ne $data.PSObject.Properties['workspacePaths'] -and $null -ne $data.workspacePaths) {
    foreach ($ws in $data.workspacePaths) {
        if ($ws -is [string] -and -not [string]::IsNullOrWhiteSpace($ws)) {
            $workspaces.Add($ws)
        }
    }
}
if ($null -ne $data.PSObject.Properties['cwd'] -and $data.cwd -is [string] -and -not [string]::IsNullOrWhiteSpace($data.cwd)) {
    $workspaces.Add($data.cwd)
}

foreach ($rawTarget in $targetPaths) {
    $normTarget = Normalize-LocalPath $rawTarget
    $ext = [System.IO.Path]::GetExtension($normTarget).ToLowerInvariant()
    $inPersonal = Test-InForbiddenPersonalDir $normTarget

    # Exempt .svg inside project workspaces, block .svg only in personal forbidden dirs
    $isBlockedMedia = ($MediaExtensions -contains $ext) -or ($ext -eq '.svg' -and $inPersonal)
    if (-not $isBlockedMedia) {
        continue
    }

    # Tier 1: Personal sensitive directories -> Unconditional Deny
    if ($inPersonal) {
        Emit-Response -Decision 'deny' -Reason $ReasonPersonalOrExternal -IsClaudeCode $isClaude
    }

    # Tier 2: Outside active workspace -> Unconditional Deny
    if ($workspaces.Count -eq 0) {
        Emit-Response -Decision 'deny' -Reason $ReasonPersonalOrExternal -IsClaudeCode $isClaude
    }

    $matchedWorkspaces = New-Object System.Collections.Generic.List[string]
    foreach ($ws in $workspaces) {
        if (Test-IsSubPath -TargetPath $normTarget -WorkspacePath $ws) {
            $matchedWorkspaces.Add((Normalize-LocalPath $ws))
        }
    }

    if ($matchedWorkspaces.Count -eq 0) {
        Emit-Response -Decision 'deny' -Reason $ReasonPersonalOrExternal -IsClaudeCode $isClaude
    }

    # Tier 3: Inside active workspace -> Default Deny unless .allow_media exists in workspace root
    $hasAllowMarker = $false
    foreach ($mws in $matchedWorkspaces) {
        $markerFile = Join-Path $mws '.allow_media'
        if (Test-Path -LiteralPath $markerFile -PathType Leaf) {
            $hasAllowMarker = $true
            break
        }
    }

    if (-not $hasAllowMarker) {
        Emit-Response -Decision 'deny' -Reason $ReasonWorkspaceDefault -IsClaudeCode $isClaude
    }
}

Emit-Response -Decision 'allow' -IsClaudeCode $isClaude
