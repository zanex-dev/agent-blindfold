function Convert-DurationToSeconds([string]$Spec) {
    if ([string]::IsNullOrWhiteSpace($Spec)) { return 0 }
    if ($Spec.Trim().ToLowerInvariant() -notmatch '^(\d{1,18})\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)?$') { return 0 }
    $amount = [decimal]$Matches[1]
    $unit = if ($Matches[2]) { $Matches[2][0] } else { 's' }
    $factor = switch ($unit) { 's' { 1 } 'm' { 60 } 'h' { 3600 } 'd' { 86400 } }
    $seconds = $amount * $factor
    if ($seconds -gt ([decimal][long]::MaxValue - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())) { return 0 }
    return [long]$seconds
}

# Shared grant operations for Windows PowerShell 5.1 and later.
function Get-GrantPath([string]$Workspace) {
    if ([string]::IsNullOrWhiteSpace($Workspace) -or -not [IO.Path]::IsPathRooted($Workspace) -or $Workspace -match '^[A-Za-z]:($|[^\\/])') {
        throw 'A fully qualified project directory is required'
    }
    $full = [IO.Path]::GetFullPath($Workspace)
    $key = $full.TrimEnd('\','/')
    if (-not $key -or $key -eq [IO.Path]::GetPathRoot($full).TrimEnd('\','/')) { throw 'Filesystem roots cannot hold workspace grants' }
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $key = [regex]::Replace($key.Replace('\','/'), '[A-Z]', { param($m) $m.Value.ToLowerInvariant() })
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return (Join-Path (Get-EffectiveHomeDir) ".gemini/config/agent-blindfold-grants/$digest.json")
}

function Assert-StatePath([string]$Path, [switch]$CreateParents) {
    $full = [IO.Path]::GetFullPath($Path)
    $base = [IO.Path]::GetFullPath((Get-EffectiveHomeDir)).TrimEnd('\','/')
    $prefix = $base + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid local state path' }
    $current = $base
    foreach ($part in ($full.Substring($prefix.Length) -split '[\\/]')) {
        $current = Join-Path $current $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if (-not $item -and $CreateParents -and $current -ne $full) {
            [IO.Directory]::CreateDirectory($current) | Out-Null
            $item = Get-Item -LiteralPath $current -Force
        }
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Redirected agent-blindfold configuration path'
        }
    }
}

function Write-StateJson([string]$Path, $Object) {
    Assert-StatePath $Path -CreateParents
    $tmp = Join-Path ([IO.Path]::GetDirectoryName($Path)) ([Guid]::NewGuid().ToString('N'))
    try {
        $stream = [IO.File]::Open($tmp, 'CreateNew', 'Write', 'None')
        try {
            $bytes = ([Text.UTF8Encoding]::new($false)).GetBytes(($Object | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
            $stream.Write($bytes,0,$bytes.Length)
        } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($tmp,$Path,[System.Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($tmp,$Path)
        }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

function Invoke-GrantLocked([string]$Path, [scriptblock]$Operation) {
    $lockPath = [IO.Path]::ChangeExtension($Path,'.lock')
    Assert-StatePath $lockPath -CreateParents
    $deadline = [DateTime]::UtcNow.AddSeconds(4)
    $file = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite',[IO.FileShare]::ReadWrite)
    $rangeLocked = $false
    try {
        while ($true) {
            try { $file.Lock(0,1); $rangeLocked = $true; break }
            catch [PlatformNotSupportedException] {
                $file.Dispose()
                $file = $null
                while ($true) {
                    try {
                        $file = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite',[IO.FileShare]::None)
                        break
                    } catch [IO.IOException] {
                        if ([DateTime]::UtcNow -ge $deadline) { throw }
                        Start-Sleep -Milliseconds 30
                    }
                }
                break
            }
            catch [IO.IOException] {
                if ([DateTime]::UtcNow -ge $deadline) { throw }
                Start-Sleep -Milliseconds 30
            }
        }
        try { & $Operation } finally { if ($rangeLocked -and $file) { $file.Unlock(0,1) } }
    } finally { if ($file) { $file.Dispose() } }
}

function Read-Grant([string]$Path) {
    Assert-StatePath $Path
    try {
        $f = [IO.File]::Open($Path,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    } catch [IO.FileNotFoundException] { return $null }
      catch [IO.DirectoryNotFoundException] { return $null }
    try {
        $reader = [IO.StreamReader]::new($f,[Text.Encoding]::UTF8)
        try { $token = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $f.Dispose() }
    if ($token.mode -notin @('permanent','timed')) { throw 'Invalid local media grant' }
    if ($token.mode -eq 'timed' -and ($token.expires_at -isnot [long] -and $token.expires_at -isnot [int])) {
        throw 'Invalid local media grant expiry'
    }
    return $token
}

function Get-GrantState([string]$Workspace) {
    $path = Get-GrantPath $Workspace
    $token = Read-Grant $path
    if ($null -eq $token) { return 'missing' }
    if ($token.mode -eq 'permanent' -or [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt $token.expires_at) { return 'valid' }
    return (Invoke-GrantLocked $path {
        $latest = Read-Grant $path
        if (-not $latest) { return 'missing' }
        if ($latest.mode -eq 'permanent' -or [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt $latest.expires_at) { return 'valid' }
        [IO.File]::Delete($path)
        return 'expired'
    })
}

function Set-WorkspaceGrant([string]$Workspace,[string]$Mode,[string]$TTL,[string]$Issuer) {
    $path = Get-GrantPath $Workspace
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $token = [ordered]@{version=2;mode=$Mode;issued_by=$Issuer;issued_at=$now}
    if ($Mode -eq 'timed') {
        $sec = Convert-DurationToSeconds $TTL
        if ($sec -le 0) { throw 'Invalid grant duration' }
        $token.ttl = $TTL
        $token.ttl_seconds = $sec
        $token.expires_at = $now + $sec
    }
    return (Invoke-GrantLocked $path {
        if ($Issuer -eq 'session_start') {
            $old = Read-Grant $path
            if ($old -and $old.mode -eq 'permanent') { return $old }
        }
        Write-StateJson $path $token
        return [PSCustomObject]$token
    })
}

function Remove-WorkspaceGrant([string]$Workspace) {
    $path = Get-GrantPath $Workspace
    Assert-StatePath $path
    if ([IO.File]::Exists($path)) { Invoke-GrantLocked $path { [IO.File]::Delete($path) } }
}

function Get-GrantPolicy {
    $path = Join-Path (Get-EffectiveHomeDir) '.gemini/config/agent-blindfold.json'
    $p = [PSCustomObject]@{Mode='timed';TTL='2h';ModeSource='default';TTLSource='default';Error=''}
    try {
        Assert-StatePath $path
        $data = $null
        try {
            $raw = [IO.File]::ReadAllText($path)
            if (-not $raw.TrimStart().StartsWith('{')) { throw 'Policy must be an object' }
            $data = $raw | ConvertFrom-Json
            if ($null -eq $data -or $data.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') { throw 'Policy must be an object' }
        } catch [IO.FileNotFoundException] {} catch [IO.DirectoryNotFoundException] {}
        if ($data -and $data.PSObject.Properties['sessionAutoGrant']) { $p.Mode = $data.sessionAutoGrant; $p.ModeSource='file' }
        if ($data -and $data.PSObject.Properties['defaultTTL']) { $p.TTL = $data.defaultTTL; $p.TTLSource='file' }
        if (-not [string]::IsNullOrWhiteSpace($env:AGENT_BLINDFOLD_AUTO_GRANT)) {
            $p.Mode=$env:AGENT_BLINDFOLD_AUTO_GRANT; $p.ModeSource='environment'
        }
        if (-not [string]::IsNullOrWhiteSpace($env:AGENT_BLINDFOLD_DEFAULT_TTL)) {
            $p.TTL=$env:AGENT_BLINDFOLD_DEFAULT_TTL; $p.TTLSource='environment'
        }
        $p.Mode=$p.Mode.Trim().ToLowerInvariant()
        $p.TTL=$p.TTL.Trim().ToLowerInvariant()
        if ($p.Mode -in @('false','none','manual','sandbox_only')) { $p.Mode='off' }
        if ($p.Mode -eq 'forever') { $p.Mode='permanent' }
        if (-not $p.TTL -or $p.Mode -notin @('timed','permanent','off') -or ($p.Mode -eq 'timed' -and (Convert-DurationToSeconds $p.TTL) -le 0)) {
            throw 'Invalid policy mode or duration'
        }
    } catch { $p.Mode='off'; $p.ModeSource='invalid policy'; $p.Error='Invalid or unreadable policy; new grants are paused.' }
    return $p
}

function Remove-UninstalledGrants {
    $directory = Join-Path (Get-EffectiveHomeDir) '.gemini/config/agent-blindfold-grants'
    Assert-StatePath $directory
    if (-not [IO.Directory]::Exists($directory)) { return }
    foreach ($file in [IO.Directory]::EnumerateFiles($directory)) {
        if ([IO.Path]::GetFileName($file) -cmatch '^[0-9a-f]{64}\.(json|lock)$') {
            Assert-StatePath $file
            [IO.File]::Delete($file)
        }
    }
    if (@([IO.Directory]::EnumerateFileSystemEntries($directory)).Count -eq 0) {
        [IO.Directory]::Delete($directory)
    }
}
