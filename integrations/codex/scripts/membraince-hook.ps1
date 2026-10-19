# MemBraince hook for Codex on Windows. Same behavior as membraince-hook.sh.
# Usage: membraince-hook.ps1 session-start|prompt|transcript
param([string]$Action = "")
$ErrorActionPreference = "Stop"
if (-not $env:MEMBRAINCE_API_KEY) { exit 0 }
if ($Action -notin @("session-start", "prompt", "transcript")) { exit 0 }
$started = [Diagnostics.Stopwatch]::StartNew()
$base = if ($env:MEMBRAINCE_URL) { $env:MEMBRAINCE_URL } else { "https://membraince.com" }
$headers = @{ "X-API-Key" = $env:MEMBRAINCE_API_KEY }
$autoRecall = $env:MEMBRAINCE_AUTO_RECALL -ne "false"
$autoSave = $env:MEMBRAINCE_AUTO_SAVE -ne "false"
[Console]::InputEncoding = [Text.Encoding]::UTF8
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$hookInput = [Console]::In.ReadToEnd() -replace "[\r\n]", ""
$utf8 = New-Object Text.UTF8Encoding($false)

function Send([string]$Route, [string]$ContentType, [byte[]]$Body, [int]$Seconds) {
    Invoke-WebRequest -Uri "$base/v1/integrations/codex/$Route" -Method Post -Headers $headers -ContentType $ContentType -Body $Body -TimeoutSec $Seconds -UseBasicParsing
}

function Recall([string]$Route) {
    if (-not $autoRecall) { return }
    try {
        $response = Send $Route "application/json" $utf8.GetBytes($hookInput) 8
        if ($response.Content) { [Console]::Out.Write($response.Content) }
    } catch {}
}

# Queues are kept per API key and server, so a leftover queue is only ever
# sent with the key that queued it, to the server it was meant for. The folder
# name holds a hash, never the key.
$sha = [Security.Cryptography.SHA256]::Create()
$fingerprint = (-join ($sha.ComputeHash($utf8.GetBytes($env:MEMBRAINCE_API_KEY + "`n" + $base)) | ForEach-Object { $_.ToString("x2") })).Substring(0, 16)
$data = if ($env:PLUGIN_DATA) { $env:PLUGIN_DATA } else { $env:TEMP }
$root = Join-Path $data "membraince-queue-$fingerprint"

# The queue folder is limited to this account: inherited permissions are
# replaced by full control for the current user only.
function Ensure-Root {
    if (Test-Path -LiteralPath $root) { return }
    [void](New-Item -ItemType Directory -Force -Path $root)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($me, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
    Set-Acl -LiteralPath $root -AclObject $acl
}

function Queue-Prompt([string]$Session) {
    Ensure-Root
    $dir = Join-Path $root $Session
    [void](New-Item -ItemType Directory -Force -Path $dir)
    $name = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfffffff") + "-$PID-" + (Get-Random)
    # Each line carries its own id, so a save resent after a lost response sends
    # the same ids and the server stores each prompt once.
    $line = '{"id":"' + $name + '","time":"' + [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") + '","hook":' + $hookInput + '}' + "`n"
    # Written under a hidden name, then renamed: a save only ever sees whole files.
    $temp = Join-Path $dir ".$name.tmp"
    [IO.File]::WriteAllText($temp, $line, $utf8)
    Move-Item -LiteralPath $temp -Destination (Join-Path $dir "$name.json")
}

# One save per session at a time. The lock file records its owner's process id;
# another save steps aside while that process runs. A lock is cleared only when
# its owner is gone, or after 10 minutes, far past any hook's time limit.
function Lock-Owner([string]$Lock) {
    try { return ([IO.File]::ReadAllText($Lock)).Trim() } catch { return $null }
}

function Try-Lock([string]$Lock) {
    try {
        $stream = [IO.File]::Open($Lock, "CreateNew", "Write", "None")
        $bytes = $utf8.GetBytes("$PID")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        return $true
    } catch {
        return $false
    }
}

function Acquire-Lock([string]$Lock) {
    if (Try-Lock $Lock) { return $true }
    $owner = Lock-Owner $Lock
    if ($null -eq $owner) { return $false }
    $gone = $owner -and -not (Get-Process -Id ([int]$owner) -ErrorAction SilentlyContinue)
    $old = (Get-Item -LiteralPath $Lock -ErrorAction SilentlyContinue).LastWriteTime -lt (Get-Date).AddMinutes(-10)
    if (-not ($gone -or $old)) { return $false }
    # Rename first, so of two saves clearing the same stale lock only one wins,
    # and check it is still the lock that was judged stale.
    $stale = "$Lock.stale.$PID"
    try { Move-Item -LiteralPath $Lock -Destination $stale } catch { return $false }
    if ((Lock-Owner $stale) -ne $owner) {
        try { Move-Item -LiteralPath $stale -Destination $Lock } catch {}
        return $false
    }
    Remove-Item -LiteralPath $stale -Force
    return (Try-Lock $Lock)
}

function Release-Lock([string]$Lock) {
    if ((Lock-Owner $Lock) -eq "$PID") { Remove-Item -LiteralPath $Lock -Force -ErrorAction SilentlyContinue }
}

# Sends a session's queued prompts as one save; true when nothing is left to send.
function Flush([string]$Dir, [int]$Seconds) {
    $lock = "$Dir.saving"
    if (-not (Acquire-Lock $lock)) { return $false }
    try {
        $files = @(Get-ChildItem -LiteralPath $Dir -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($files.Count -eq 0) { return $true }
        $body = New-Object IO.MemoryStream
        foreach ($file in $files) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $body.Write($bytes, 0, $bytes.Length)
        }
        try { [void](Send "transcript" "application/x-ndjson" $body.ToArray() $Seconds) } catch { return $false }
        foreach ($file in $files) { Remove-Item -LiteralPath $file.FullName -Force }
        return $true
    } finally {
        Release-Lock $lock
    }
}

# Queues from earlier sessions whose last save failed. A session folder left
# untouched for 30 days is deleted rather than kept forever.
function Recover([string]$Session) {
    if (-not (Test-Path -LiteralPath $root)) { return }
    $month = (Get-Date).AddDays(-30)
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory)) {
        if ($dir.Name -eq $Session) { continue }
        $recent = @(Get-ChildItem -LiteralPath $dir.FullName -File | Where-Object { $_.LastWriteTime -gt $month })
        if ($dir.LastWriteTime -lt $month -and $recent.Count -eq 0) {
            if (-not (Test-Path -LiteralPath "$($dir.FullName).saving")) { Remove-Item -LiteralPath $dir.FullName -Recurse -Force }
            continue
        }
        # One deadline for the whole hook: recall and recovery finish within 15
        # seconds, well inside the hook's 20-second limit.
        $left = [int][Math]::Floor(15 - $started.Elapsed.TotalSeconds)
        if ($left -lt 2) { break }
        [void](Flush $dir.FullName ([Math]::Min($left, 4)))
    }
    Get-ChildItem -LiteralPath $root -Filter "*.saved" -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Force
}

try {
    $hook = $hookInput | ConvertFrom-Json
    $session = "$($hook.session_id)" -replace "[^A-Za-z0-9_-]", ""
    if ($Action -eq "session-start") {
        Recall "session-start"
        if ($autoSave) { Recover $session }
    }
    if ($Action -eq "prompt") {
        if ($autoSave -and $session) { Queue-Prompt $session }
        Recall "prompt"
    }
    if ($Action -eq "transcript" -and $autoSave -and $session) {
        $dir = Join-Path $root $session
        if (-not (Test-Path -LiteralPath $dir)) { exit 0 }
        $stamp = Join-Path $root "$session.saved"
        # Stop runs after every turn; save from it at most every 15 minutes per session.
        if ($hook.hook_event_name -eq "Stop" -and (Test-Path -LiteralPath $stamp) -and (Get-Item -LiteralPath $stamp).LastWriteTime -gt (Get-Date).AddMinutes(-15)) { exit 0 }
        # Codex gives SessionEnd hooks at most 3 seconds, and taking the lock never waits.
        $limit = if ($hook.hook_event_name -eq "SessionEnd") { 2 } else { 20 }
        if (Flush $dir $limit) { Set-Content -LiteralPath $stamp -Value "" -Encoding ascii }
    }
} catch {
    # A failed hook stays silent so it never blocks or clutters a session; a
    # failed save keeps its prompts for the next one.
}
exit 0
