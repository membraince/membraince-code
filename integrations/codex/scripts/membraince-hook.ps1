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

try {
    $hook = $hookInput | ConvertFrom-Json
    $session = "$($hook.session_id)" -replace "[^A-Za-z0-9_-]", ""
    $data = if ($env:PLUGIN_DATA) { $env:PLUGIN_DATA } else { $env:TEMP }
    $queue = Join-Path $data "membraince-queue-$session.jsonl"
    $sending = "$queue.sending"
    if ($Action -eq "session-start") { Recall }
    if ($Action -eq "prompt") {
        if ($autoSave -and $session) {
            [void](New-Item -ItemType Directory -Force -Path $data)
            $line = '{"time":"' + [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") + '","hook":' + $hookInput + '}' + "`n"
            [IO.File]::AppendAllText($queue, $line, $utf8)
        }
        Recall
    }
    if ($Action -eq "transcript" -and $autoSave -and $session) {
        # One save per session at a time: a save holding the lock is uploading right
        # now, so this one steps aside and the next save sends anything left over. A
        # lock older than 2 minutes was left by a save that died (uploads stop at 20 s).
        $lock = "$queue.lock"
        if ((Test-Path -LiteralPath $lock) -and (Get-Item -LiteralPath $lock).LastWriteTime -lt (Get-Date).AddMinutes(-2)) {
            Remove-Item -LiteralPath $lock -Force
        }
        try { [IO.File]::Open($lock, "CreateNew", "Write", "None").Close() } catch { exit 0 }
        try {
            # Prompts left over from a save that didn't finish go out with this one.
            if (Test-Path -LiteralPath $sending) {
                if (Test-Path -LiteralPath $queue) { [IO.File]::AppendAllText($sending, [IO.File]::ReadAllText($queue, $utf8), $utf8) }
                Move-Item -LiteralPath $sending -Destination $queue -Force
            }
            if (-not (Test-Path -LiteralPath $queue) -or (Get-Item -LiteralPath $queue).Length -eq 0) { exit 0 }
            $stamp = Join-Path $data "membraince-saved-$session"
            # Stop runs after every turn; save from it at most every 15 minutes per session.
            if ($hook.hook_event_name -eq "Stop" -and (Test-Path -LiteralPath $stamp) -and (Get-Item -LiteralPath $stamp).LastWriteTime -gt (Get-Date).AddMinutes(-15)) { exit 0 }
            # Codex gives SessionEnd hooks at most 3 seconds.
            $limit = if ($hook.hook_event_name -eq "SessionEnd") { 2 } else { 20 }
            # Prompts typed while this save is in flight go to a fresh queue.
            Move-Item -LiteralPath $queue -Destination $sending -Force
            try {
                [void](Send "application/x-ndjson" ([IO.File]::ReadAllBytes($sending)) $limit)
                Remove-Item -LiteralPath $sending -Force
                Set-Content -LiteralPath $stamp -Value "" -Encoding ascii
            } catch {
                if (Test-Path -LiteralPath $queue) { [IO.File]::AppendAllText($sending, [IO.File]::ReadAllText($queue, $utf8), $utf8) }
                Move-Item -LiteralPath $sending -Destination $queue -Force
            }
        } finally {
            Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    # A failed hook stays silent so it never blocks or clutters a session.
}
exit 0
