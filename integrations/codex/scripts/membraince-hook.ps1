# MemBraince hook for Codex on Windows. Same behavior as membraince-hook.sh.
# Usage: membraince-hook.ps1 session-start|prompt|transcript
param([string]$Action = "")
$ErrorActionPreference = "Stop"
if (-not $env:MEMBRAINCE_API_KEY) { exit 0 }
if ($Action -notin @("session-start", "prompt", "transcript")) { exit 0 }
$base = if ($env:MEMBRAINCE_URL) { $env:MEMBRAINCE_URL } else { "https://membraince.com" }
$user = if ($env:MEMBRAINCE_USER) { $env:MEMBRAINCE_USER } else { "default" }
$headers = @{ "X-API-Key" = $env:MEMBRAINCE_API_KEY; "X-MemBraince-User" = $user; "X-MemBraince-Project" = "$env:MEMBRAINCE_PROJECT" }
$uri = "$base/v1/integrations/codex/$Action"
$autoRecall = $env:MEMBRAINCE_AUTO_RECALL -ne "false"
$autoSave = $env:MEMBRAINCE_AUTO_SAVE -ne "false"
[Console]::InputEncoding = [Text.Encoding]::UTF8
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$hookInput = [Console]::In.ReadToEnd() -replace "[\r\n]", ""
$utf8 = New-Object Text.UTF8Encoding($false)

function Send([string]$ContentType, [byte[]]$Body, [int]$Seconds) {
    Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType $ContentType -Body $Body -TimeoutSec $Seconds -UseBasicParsing
}

function Recall {
    if (-not $autoRecall) { return }
    $response = Send "application/json" $utf8.GetBytes($hookInput) 8
    if ($response.Content) { [Console]::Out.Write($response.Content) }
}

# Creating a file that must not exist is atomic, so it works as a lock.
function Take-Lock([string]$Path) {
    try { [IO.File]::Open($Path, "CreateNew", "Write", "None").Close(); return $true } catch { return $false }
}

# The queue lock is held only while a prompt is added or a save takes the
# queue, never during an upload, so it waits milliseconds at most. One that
# outlives 2 seconds of retries was left by a crash.
function Lock-Queue([string]$Path) {
    for ($i = 0; $i -lt 40; $i++) {
        if (Take-Lock $Path) { return }
        Start-Sleep -Milliseconds 50
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    [void](Take-Lock $Path)
}

try {
    $hook = $hookInput | ConvertFrom-Json
    $session = "$($hook.session_id)" -replace "[^A-Za-z0-9_-]", ""
    $data = if ($env:PLUGIN_DATA) { $env:PLUGIN_DATA } else { $env:TEMP }
    # queue: prompts not yet picked up by a save. pending: prompts a save has
    # taken; a save that fails leaves them there for the next save.
    $queue = Join-Path $data "membraince-queue-$session.jsonl"
    $pending = "$queue.pending"
    $queueLock = "$queue.lock"
    if ($Action -eq "session-start") { Recall }
    if ($Action -eq "prompt") {
        if ($autoSave -and $session) {
            [void](New-Item -ItemType Directory -Force -Path $data)
            $line = '{"time":"' + [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") + '","hook":' + $hookInput + '}' + "`n"
            Lock-Queue $queueLock
            try { [IO.File]::AppendAllText($queue, $line, $utf8) } finally { Remove-Item -LiteralPath $queueLock -Force -ErrorAction SilentlyContinue }
        }
        Recall
    }
    if ($Action -eq "transcript" -and $autoSave -and $session) {
        $stamp = Join-Path $data "membraince-saved-$session"
        # Stop runs after every turn; save from it at most every 15 minutes per session.
        if ($hook.hook_event_name -eq "Stop" -and (Test-Path -LiteralPath $stamp) -and (Get-Item -LiteralPath $stamp).LastWriteTime -gt (Get-Date).AddMinutes(-15)) { exit 0 }
        # One save per session at a time: a save holding this lock is uploading right
        # now, so this one steps aside and the next save sends anything left over. A
        # lock older than 2 minutes was left by a save that died (uploads stop at 20 s).
        $saving = "$queue.saving"
        if ((Test-Path -LiteralPath $saving) -and (Get-Item -LiteralPath $saving).LastWriteTime -lt (Get-Date).AddMinutes(-2)) {
            Remove-Item -LiteralPath $saving -Force
        }
        if (-not (Take-Lock $saving)) { exit 0 }
        try {
            # Take the queue: its prompts join any a failed save left, in order.
            Lock-Queue $queueLock
            try {
                if ((Test-Path -LiteralPath $queue) -and (Get-Item -LiteralPath $queue).Length -gt 0) {
                    [IO.File]::AppendAllText($pending, [IO.File]::ReadAllText($queue, $utf8), $utf8)
                    Remove-Item -LiteralPath $queue -Force
                }
            } finally {
                Remove-Item -LiteralPath $queueLock -Force -ErrorAction SilentlyContinue
            }
            if (-not (Test-Path -LiteralPath $pending) -or (Get-Item -LiteralPath $pending).Length -eq 0) { exit 0 }
            # Codex gives SessionEnd hooks at most 3 seconds.
            $limit = if ($hook.hook_event_name -eq "SessionEnd") { 2 } else { 20 }
            [void](Send "application/x-ndjson" ([IO.File]::ReadAllBytes($pending)) $limit)
            Remove-Item -LiteralPath $pending -Force
            Set-Content -LiteralPath $stamp -Value "" -Encoding ascii
        } finally {
            Remove-Item -LiteralPath $saving -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    # A failed hook stays silent so it never blocks or clutters a session; a
    # failed save leaves its prompts pending for the next one.
}
exit 0
