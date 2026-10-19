# MemBraince hook for Codex on Windows. Same behavior as membraince-hook.sh.
# Usage: membraince-hook.ps1 session-start|prompt|transcript
param([string]$Action = "")
$ErrorActionPreference = "Stop"
if (-not $env:MEMBRAINCE_API_KEY) { exit 0 }
if ($Action -notin @("session-start", "prompt", "transcript")) { exit 0 }
if ($Action -ne "transcript" -and $env:MEMBRAINCE_AUTO_RECALL -eq "false") { exit 0 }
if ($Action -eq "transcript" -and $env:MEMBRAINCE_AUTO_SAVE -eq "false") { exit 0 }
$base = if ($env:MEMBRAINCE_URL) { $env:MEMBRAINCE_URL } else { "https://membraince.com" }
$user = if ($env:MEMBRAINCE_USER) { $env:MEMBRAINCE_USER } else { "default" }
$headers = @{ "X-API-Key" = $env:MEMBRAINCE_API_KEY; "X-MemBraince-User" = $user; "X-MemBraince-Project" = "$env:MEMBRAINCE_PROJECT" }
$uri = "$base/v1/integrations/codex/$Action"
[Console]::InputEncoding = [Text.Encoding]::UTF8
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$hookInput = [Console]::In.ReadToEnd() -replace "[\r\n]", ""
try {
    if ($Action -eq "transcript") {
        $hook = $hookInput | ConvertFrom-Json
        $path = $hook.transcript_path
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { exit 0 }
        if ($hook.hook_event_name -eq "Stop") {
            # Stop runs after every turn; save from it at most every 15 minutes per session.
            $folder = if ($env:PLUGIN_DATA) { $env:PLUGIN_DATA } else { $env:TEMP }
            $stamp = Join-Path $folder ("membraince-saved-" + ($hook.session_id -replace "[^A-Za-z0-9_-]", ""))
            if ((Test-Path -LiteralPath $stamp) -and (Get-Item -LiteralPath $stamp).LastWriteTime -gt (Get-Date).AddMinutes(-15)) { exit 0 }
            [void](New-Item -ItemType Directory -Force -Path $folder)
            Set-Content -LiteralPath $stamp -Value "" -Encoding ascii
        }
        # Codex gives SessionEnd hooks at most 3 seconds.
        $limit = if ($hook.hook_event_name -eq "SessionEnd") { 2 } else { 20 }
        $stream = [IO.File]::Open($path, "Open", "Read", "ReadWrite")
        [void]$stream.Seek([Math]::Max(0, $stream.Length - 2000000), "Begin")
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        $tail = $reader.ReadToEnd()
        $reader.Close()
        # Only the lines holding your own messages leave this machine: Codex's replies,
        # tool calls, and tool output are filtered out here, before anything is sent.
        $mine = ($tail -split "`n") | Where-Object { $_.Contains('"role":"user"') }
        $body = [Text.Encoding]::UTF8.GetBytes((@($hookInput) + $mine) -join "`n")
        [void](Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType "application/x-ndjson" -Body $body -TimeoutSec $limit -UseBasicParsing)
    } else {
        $body = [Text.Encoding]::UTF8.GetBytes($hookInput)
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType "application/json" -Body $body -TimeoutSec 8 -UseBasicParsing
        if ($response.Content) { [Console]::Out.Write($response.Content) }
    }
} catch {
    # A failed hook stays silent so it never blocks or clutters a session.
}
exit 0
