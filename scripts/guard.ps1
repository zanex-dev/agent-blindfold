#Requires -Version 5.1
<#
.SYNOPSIS
    agent-blindfold (Codename: Heart-Under-Blade)
    Zero-trust local media privacy & anti-ban PreToolUse Hook for Google Antigravity & Claude Code.
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

# Decode UTF-8 Chinese messages from Base64 so PowerShell 5.1 without BOM never misparses source literals
$EnPersonal = "Blocked by agent-blindfold (Heart-Under-Blade): Access to personal or external media files is strictly forbidden."
$ZhPersonal = $utf8NoBom.GetString([Convert]::FromBase64String("6Kem5Y+R5YWo5bGA5aqS5L2T6ZqQ56eB6ZqU56a76ZOB5b6L77ya5Lil56aB6K+75Y+W5oiW6Kem56Kw5Liq5Lq655uu5b2V5Y+K5aSW6YOo55uu5b2V55qE5Zu+54mH5LiO6Z+z6KeG6aKR5paH5Lu244CC"))

$EnWorkspace = "Blocked by agent-blindfold (Heart-Under-Blade): Workspace media is isolated by default. Create '.allow_media' in the workspace root to unlock temporarily."
$ZhWorkspace = $utf8NoBom.GetString([Convert]::FromBase64String("6Kem5Y+R5YWo5bGA5aqS5L2T6ZqQ56eB6ZqU56a76ZOB5b6L77ya5bel5L2c5Yy65YaF5aqS5L2T5paH5Lu26buY6K6k6ZqU56a75oum5oiq77yI5aaC6ZyA5Li05pe25pS+6KGM77yM6K+35Zyo5b2T5YmN5bel5L2c5Yy65qC555uu5b2V5Yib5bu6IC5hbGxvd19tZWRpYSDmoIforrDmlofku7bvvInjgII="))

$langMode = if ($env:AGENT_BLINDFOLD_LANG) { $env:AGENT_BLINDFOLD_LANG.Trim().ToLowerInvariant() } else { "bilingual" }
switch ($langMode) {
    "en" {
        $ReasonPersonalOrExternal = $EnPersonal
        $ReasonWorkspaceDefault   = $EnWorkspace
    }
    "zh" {
        $ReasonPersonalOrExternal = $ZhPersonal
        $ReasonWorkspaceDefault   = $ZhWorkspace
    }
    default {
        $ReasonPersonalOrExternal = "$EnPersonal | $ZhPersonal"
        $ReasonWorkspaceDefault   = "$EnWorkspace | $ZhWorkspace"
    }
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
    $homeDir = [Environment]::GetFolderPath('UserProfile')
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
        $full = [System.IO.Path]::GetFullPath($cleanedSafe)

        # Walk path and ancestors to resolve file symlinks and directory junctions/symlinks
        $probe = $full
        $tailParts = New-Object System.Collections.Generic.List[string]
        while (-not [string]::IsNullOrWhiteSpace($probe)) {
            if (($probe -notmatch '__WC_') -and (Test-Path -LiteralPath $probe)) {
                try {
                    $item = Get-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                    if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and $item.Target) {
                        $targetVal = if ($item.Target -is [array]) { [string]$item.Target[0] } else { [string]$item.Target }
                        $targetVal = $targetVal -replace '^\\\?\\', ''
                        if (-not [string]::IsNullOrWhiteSpace($targetVal)) {
                            if (-not [System.IO.Path]::IsPathRooted($targetVal)) {
                                $parentOfProbe = Split-Path -Parent $probe
                                $targetVal = Join-Path $parentOfProbe $targetVal
                            }
                            $rebuilt = $targetVal
                            for ($i = $tailParts.Count - 1; $i -ge 0; $i--) {
                                $rebuilt = Join-Path $rebuilt $tailParts[$i]
                            }
                            return [System.IO.Path]::GetFullPath($rebuilt)
                        }
                    }
                } catch {}
            }
            $parent = Split-Path -Parent $probe
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
            $tailParts.Add((Split-Path -Leaf $probe))
            $probe = $parent
        }
        return $full
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

function Test-IsValidProjectWorkspace {
    param([string]$WsPath)
    if ([string]::IsNullOrWhiteSpace($WsPath)) { return $false }
    $normWs = (Normalize-LocalPath $WsPath).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($normWs)) { return $false }

    # Reject drive root (e.g. "C:" or "")
    if ($normWs -match '^[A-Za-z]:$') { return $false }

    # Reject user profile root itself
    $homeNorm = (Normalize-LocalPath ([Environment]::GetFolderPath('UserProfile'))).TrimEnd('\', '/')
    if ($normWs.ToLowerInvariant() -eq $homeNorm.ToLowerInvariant()) { return $false }

    # Reject any workspace inside HardVaultDirs (Pictures, Videos, Music, AppData)
    if (Test-InHardVault $normWs) { return $false }

    # Reject PersonalContainerDirs opened directly as root workspace (e.g. ~/Downloads or ~/Desktop itself)
    $leaf = [System.IO.Path]::GetFileName($normWs).ToLowerInvariant()
    if ($PersonalContainerDirs -contains $leaf) { return $false }

    return $true
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

function Evaluate-MediaPath {
    <#
    Returns:
      $null                         -> Allowed
      $ReasonPersonalOrExternal     -> Tier 1 / Tier 2 Hard Deny
      $ReasonWorkspaceDefault       -> Tier 3 Default Deny (unlockable with .allow_media)
    #>
    param(
        [string]$RawTarget,
        [string]$BaseDir,
        [System.Collections.Generic.List[string]]$ValidWorkspaces
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

    if ($ext -eq '.svg') {
        # .svg is blocked in HardVaultDirs, or in PersonalContainerDirs outside a valid project workspace
        if ($inHardVault) { return $ReasonPersonalOrExternal }
        if ($inPersonalContainer -and $matchedWs.Count -eq 0) { return $ReasonPersonalOrExternal }
        return $null
    }

    if (-not ($MediaExtensions -contains $ext)) {
        return $null
    }

    # Tier 1: Hard personal vaults (Pictures / Videos / Music / AppData)
    if ($inHardVault) {
        return $ReasonPersonalOrExternal
    }

    # Tier 2: Outside any valid dedicated project workspace (includes raw Downloads/Desktop/Documents & external drives)
    if ($matchedWs.Count -eq 0) {
        return $ReasonPersonalOrExternal
    }

    # Tier 3: Inside a valid dedicated project workspace -> check .allow_media marker
    foreach ($ws in $matchedWs) {
        $marker = Join-Path $ws '.allow_media'
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            return $null
        }
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
    # A1: Block direct directory scans or touches of HardVaultDirs (Pictures, Videos, Music)
    $vaultScanPattern = '(?i)(?:^|[\s"''`=(]|[A-Za-z]:|~|\$HOME|\$env:USERPROFILE|%USERPROFILE%)[\\/](?:Pictures|Videos|Music)(?:[\\/]|[\s"''`;|&)]|$)'
    if ($cmdLine -match $vaultScanPattern) {
        Emit-Response -Decision 'deny' -Reason $ReasonPersonalOrExternal -IsClaudeCode $isClaude
    }

    # A2: Extract media file path tokens (double-quoted, single-quoted, or unquoted)
    $extGroup = 'jpg|jpeg|png|gif|webp|bmp|ico|heic|heif|avif|mp4|mkv|avi|mov|webm|flv|wmv|mp3|wav|flac|m4a|ogg|aac|svg'
    $shellTokens = New-Object System.Collections.Generic.List[string]

    foreach ($m in [regex]::Matches($cmdLine, "(?i)`"([^`"\r\n]+\.(?:$extGroup))`"")) {
        $shellTokens.Add($m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($cmdLine, "(?i)'([^'\r\n]+\.(?:$extGroup))'")) {
        $shellTokens.Add($m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($cmdLine, "(?i)(?<![A-Za-z0-9_.:/-])([^\s`"''`|;&<>()]+\.(?:$extGroup))(?![A-Za-z0-9_])")) {
        $shellTokens.Add($m.Groups[1].Value)
    }

    $isSafeGitMeta = $cmdLine -match '^\s*git\s+(?:commit|status|log|branch|tag|push|pull|fetch)\b'
    $isByteDumper  = $cmdLine -match '(?i)\b(?:base64|certutil|xxd|hexdump|od|Format-Hex|AsByteStream|ReadAllBytes|ToBase64String|PIL|Pillow|Image\.open|cv2|imread|imageio|pytesseract|tesseract|easyocr|ffmpeg|ffprobe|magick|identify|exiftool|sips|markitdown)\b|-Encoding\s+Byte'

    foreach ($tok in $shellTokens) {
        if (Test-IsWebOrNonLocalUri $tok) { continue }
        if ($isSafeGitMeta -and ($tok -notmatch '[\\/]')) { continue }

        $verdict = Evaluate-MediaPath -RawTarget $tok -BaseDir $baseDir -ValidWorkspaces $validWorkspaces
        if ($verdict -eq $ReasonPersonalOrExternal) {
            # Tier 1 / Tier 2 media referenced in shell command -> Hard Deny
            Emit-Response -Decision 'deny' -Reason $ReasonPersonalOrExternal -IsClaudeCode $isClaude
        } elseif ($verdict -eq $ReasonWorkspaceDefault -and $isByteDumper) {
            # Tier 3 workspace media without .allow_media + byte/content inspection tool -> Deny bypass
            Emit-Response -Decision 'deny' -Reason $ReasonWorkspaceDefault -IsClaudeCode $isClaude
        }
    }
}

# Branch B: Direct File / Resource / MCP Tool Argument Inspection
$argSources = New-Object System.Collections.Generic.List[object]
$argSources.Add($argsObj)
if ($null -ne $argsObj.PSObject.Properties['Arguments'] -and $null -ne $argsObj.Arguments) {
    $argSources.Add($argsObj.Arguments)
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
    foreach ($arrKey in @('Paths', 'paths', 'Files', 'files')) {
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

foreach ($rawTarget in $targetPaths) {
    $verdict = Evaluate-MediaPath -RawTarget $rawTarget -BaseDir $baseDir -ValidWorkspaces $validWorkspaces
    if ($null -ne $verdict) {
        Emit-Response -Decision 'deny' -Reason $verdict -IsClaudeCode $isClaude
    }
}

Emit-Response -Decision 'allow' -IsClaudeCode $isClaude
