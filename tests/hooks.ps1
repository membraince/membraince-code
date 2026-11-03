# Tests for the Codex Windows hook (membraince-hook.ps1) against tests/fake_server.py.
# Run from the repository root: powershell -ExecutionPolicy Bypass -File tests/hooks.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repo "integrations\codex\scripts\membraince-hook.ps1"
$work = Join-Path ([IO.Path]::GetTempPath()) ("membraince-test-" + [Guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $work)
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { $python = (Get-Command python3).Source }
$server = Start-Process -FilePath $python -ArgumentList @("`"$repo\tests\fake_server.py`"", "`"$work`"") -PassThru -WindowStyle Hidden
for ($i = 0; $i -lt 100 -and -not (Test-Path "$work\port"); $i++) { Start-Sleep -Milliseconds 100 }
$port = (Get-Content "$work\port").Trim()
$data = Join-Path $work "data"
$failures = 0

function Check([string]$Description, [scriptblock]$Condition) {
    if (& $Condition) { "  ok   $Description" } else { "  FAIL $Description"; $script:failures++ }
}

$hostName = "127.0.0.1"
function Run([string]$Action, [string]$Key, [string]$Json) {
    $env:MEMBRAINCE_API_KEY = $Key
    $env:MEMBRAINCE_URL = "http://${hostName}:$port"
    $env:PLUGIN_DATA = $data
    $Json | powershell -NoProfile -ExecutionPolicy Bypass -File $script $Action | Out-Null
}
function Prompt([string]$Session, [string]$Text, [string]$Key = "key-a") {
    Run "prompt" $Key ('{"hook_event_name":"UserPromptSubmit","session_id":"' + $Session + '","cwd":"C:\\w\\app","prompt":"' + $Text + '"}')
}
function Save([string]$Session, [string]$Key = "key-a", [string]$Event = "PreCompact") {
    Run "transcript" $Key ('{"hook_event_name":"' + $Event + '","session_id":"' + $Session + '"}')
}
function Start-Session([string]$Session, [string]$Key = "key-a") {
    Run "session-start" $Key ('{"hook_event_name":"SessionStart","session_id":"' + $Session + '","cwd":"C:\\w\\app"}')
}
# A slow save whose hook gave up still lands when the server wakes; wait for it,
# so it can't show up in a later section's uploads.
function Wait-Idle {
    for ($i = 0; $i -lt 150 -and @(Get-ChildItem -Path $work -Filter "busy-*" -ErrorAction SilentlyContinue).Count; $i++) { Start-Sleep -Milliseconds 100 }
}
function Received { if (Test-Path "$work\received.txt") { [IO.File]::ReadAllText("$work\received.txt") } else { "" } }
function Uploaded { if (Test-Path "$work\uploaded.txt") { @(Get-Content "$work\uploaded.txt") } else { @() } }
function Queued { @(Get-ChildItem -Path $data -Recurse -Filter "*.json" -File -ErrorAction SilentlyContinue).Count }

try {
    "== codex (PowerShell)"
    Prompt "s1" "first prompt"
    Check "a prompt is queued as one file" { (Queued) -eq 1 }
    New-Item -ItemType File "$work\fail" | Out-Null
    Save "s1"
    Check "a failed save keeps the queue" { (Queued) -eq 1 }
    Remove-Item "$work\fail"
    Save "s1"
    Check "a successful save sends it and empties the queue" { ((Uploaded) -join "|") -eq "key-a first prompt" -and (Queued) -eq 0 }

    Prompt "s2" "behind a live lock"
    $root = (Get-ChildItem -Path $data -Directory -Filter "membraince-queue-*" | Select-Object -First 1).FullName
    [IO.File]::WriteAllText("$root\s2.saving", "$PID")
    Save "s2"
    Check "a save steps aside while the lock's owner runs" { (Queued) -eq 1 }
    $dead = Start-Process -FilePath "cmd.exe" -ArgumentList "/c exit" -PassThru -WindowStyle Hidden
    $dead.WaitForExit()
    [IO.File]::WriteAllText("$root\s2.saving", "$($dead.Id)")
    Save "s2"
    Check "a lock whose owner is gone is cleared" { (Queued) -eq 0 -and ((Uploaded) -contains "key-a behind a live lock") }

    Remove-Item "$work\uploaded.txt"
    Prompt "s3" "stranded with key a"
    Prompt "s4" "stranded with key b" "key-b"
    New-Item -ItemType File "$work\fail" | Out-Null
    Save "s3" "key-a" "SessionEnd"
    Remove-Item "$work\fail"
    Start-Session "s5"
    Check "a new session sends an earlier session's stranded queue" { ((Uploaded) -join "|") -eq "key-a stranded with key a" }
    Check "a queue made with another key is left alone" { (Queued) -eq 1 }

    # A response lost after the server stored the save: the prompt stays queued,
    # and the retry sends byte-identical lines with the same ids.
    Remove-Item "$work\received.txt" -ErrorAction SilentlyContinue
    Prompt "s9" "accepted then disconnected"
    New-Item -ItemType File "$work\drop" | Out-Null
    Save "s9"
    Remove-Item "$work\drop"
    Check "a save whose response is lost keeps its prompt" { (Queued) -eq 2 }
    $first = Received
    Remove-Item "$work\received.txt"
    Save "s9"
    Check "the retry resends the same lines, with the same id" { (Received) -eq $first -and $first -match '"id":' }
    Check "after the retry succeeds, nothing of that session is queued" { (Queued) -eq 1 }

    # A queue made for one server is never sent to another with the same key.
    Remove-Item "$work\uploaded.txt" -ErrorAction SilentlyContinue
    Prompt "s10" "meant for the first server"
    $hostName = "localhost"; Start-Session "s11"; $hostName = "127.0.0.1"
    Check "a queue isn't sent to a different server address" { -not ((Uploaded) -match "meant for the first server") }
    Save "s10"

    $acl = Get-Acl -LiteralPath $root
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
    Check "the queue folder is limited to this account" {
        $acl.AreAccessRulesProtected -and @($acl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -ne $me }).Count -eq 0
    }

    $old = (Get-ChildItem -Path $data -Recurse -Directory -Filter "s4").FullName
    $past = (Get-Date).AddDays(-40)
    Get-ChildItem $old -File | ForEach-Object { $_.LastWriteTime = $past }
    (Get-Item $old).LastWriteTime = $past
    Start-Session "s6" "key-b"
    Check "a 30-day-old queue is deleted, not sent" { -not (Test-Path $old) -and -not ((Uploaded) -match "key b") }

    # Recovery shares one deadline with recall: with a slow server and many
    # stranded queues, session start still ends inside the hook's 20 seconds.
    foreach ($i in 1..6) { Prompt "slow$i" "stranded $i" }
    New-Item -ItemType File "$work\slow" | Out-Null
    $took = (Measure-Command { Start-Session "s13" }).TotalSeconds
    Remove-Item "$work\slow"
    Check ("session start finishes within its time limit ({0:N0} s)" -f $took) { $took -lt 20 }
    Start-Session "s14"
    foreach ($i in 1..6) { Save "slow$i" }

    Remove-Item "$work\uploaded.txt" -ErrorAction SilentlyContinue
    $jobs = @()
    foreach ($i in 1..40) {
        if ($i -eq 10) { New-Item -ItemType File "$work\fail" | Out-Null }
        if ($i -eq 25) { Remove-Item "$work\fail" }
        $text = "stress {0:D2}" -f $i
        $jobs += Start-Job -ScriptBlock {
            param($script, $data, $port, $text)
            $env:MEMBRAINCE_API_KEY = "key-a"; $env:MEMBRAINCE_URL = "http://127.0.0.1:$port"; $env:PLUGIN_DATA = $data
            ('{"hook_event_name":"UserPromptSubmit","session_id":"s8","prompt":"' + $text + '"}') | powershell -NoProfile -ExecutionPolicy Bypass -File $script prompt | Out-Null
        } -ArgumentList $script, $data, $port, $text
        if ($i % 3 -eq 0) {
            $jobs += Start-Job -ScriptBlock {
                param($script, $data, $port)
                $env:MEMBRAINCE_API_KEY = "key-a"; $env:MEMBRAINCE_URL = "http://127.0.0.1:$port"; $env:PLUGIN_DATA = $data
                '{"hook_event_name":"PreCompact","session_id":"s8"}' | powershell -NoProfile -ExecutionPolicy Bypass -File $script transcript | Out-Null
            } -ArgumentList $script, $data, $port
        }
    }
    $jobs | Wait-Job | Remove-Job
    if (Test-Path "$work\fail") { Remove-Item "$work\fail" }
    foreach ($i in 1..5) { Save "s8" }
    # Only this test's prompts count: the slow test's uploads can still land late.
    $sent = @(Uploaded | Where-Object { $_ -match " stress " })
    Check "under load, every prompt is sent exactly once" { $sent.Count -eq 40 -and @($sent | Sort-Object -Unique).Count -eq 40 }
    Check "nothing is left queued" { (Queued) -eq 0 }

    "== codex (PowerShell): telling you when MemBraince refuses the key"
    Wait-Idle
    function Output([string]$Action, [string]$Json, [string]$Key = "key-r") {
        $env:MEMBRAINCE_API_KEY = $Key
        $env:MEMBRAINCE_URL = "http://127.0.0.1:$port"
        $env:PLUGIN_DATA = $data
        ($Json | powershell -NoProfile -ExecutionPolicy Bypass -File $script $Action | Out-String).Trim()
    }
    function Start-Output([string]$Session) { Output "session-start" ('{"hook_event_name":"SessionStart","session_id":"' + $Session + '","cwd":"C:\\w\\app"}') }
    # The output is one JSON warning and nothing else.
    function Is-Notice([string]$Text, [string]$Start) {
        try { $notice = $Text | ConvertFrom-Json } catch { return $false }
        @($notice.PSObject.Properties).Count -eq 1 -and $notice.systemMessage.StartsWith($Start)
    }
    $status = Join-Path $work "status"
    Check "a session start prints what recall returns" { (Start-Output "r1") -eq "Memories from MemBraince: (test)" }
    Set-Content -LiteralPath $status -Value "402" -Encoding ascii
    Check "a refused key makes session start print one warning, as JSON only" { Is-Notice (Start-Output "r2") "MemBraince memory is off until you subscribe" }
    Check "the same refusal again the same day prints nothing" { -not (Start-Output "r3") }
    Set-Content -LiteralPath $status -Value "401" -Encoding ascii
    Check "a different refusal is told" { Is-Notice (Start-Output "r4") "MemBraince didn't accept your API key" }
    $env:MEMBRAINCE_AUTO_SAVE = "false"
    Check "a refused prompt prints nothing" { -not (Output "prompt" '{"hook_event_name":"UserPromptSubmit","session_id":"r9","prompt":"why"}') }
    Remove-Item Env:\MEMBRAINCE_AUTO_SAVE
    Set-Content -LiteralPath $status -Value "500" -Encoding ascii
    Check "a server error stays silent" { -not (Start-Output "r5") }
    Set-Content -LiteralPath $status -Value "429" -Encoding ascii
    Remove-Item "$work\uploaded.txt" -ErrorAction SilentlyContinue
    Prompt "r6" "queued while refused" "key-r"
    Save "r6" "key-r"
    Check "a refused save keeps the queue" { (Queued) -eq 1 }
    $env:MEMBRAINCE_AUTO_RECALL = "false"
    Check "with recall off, session start tells about a refused save" { Is-Notice (Start-Output "r7") "This API key has reached a MemBraince limit" }
    Remove-Item Env:\MEMBRAINCE_AUTO_RECALL
    Remove-Item -LiteralPath $status
    [void](Start-Output "r8")
    Check "once MemBraince accepts the key, the queue is saved" { ((Uploaded) -join "|") -eq "key-r queued while refused" -and (Queued) -eq 0 }
    "== codex (PowerShell): the key file"
    Wait-Idle
    $keyHome = Join-Path $work "home"
    [void](New-Item -ItemType Directory -Force (Join-Path $keyHome ".config\membraince"))
    [IO.File]::WriteAllText((Join-Path $keyHome ".config\membraince\api-key"), "key-f`n")
    $realProfile = $env:USERPROFILE
    $env:USERPROFILE = $keyHome
    try {
        Remove-Item "$work\uploaded.txt" -ErrorAction SilentlyContinue
        Check "with no MEMBRAINCE_API_KEY, session start uses the key file" { (Output "session-start" '{"hook_event_name":"SessionStart","session_id":"f0","cwd":"C:\\w\\app"}' "") -eq "Memories from MemBraince: (test)" }
        Run "prompt" "" '{"hook_event_name":"UserPromptSubmit","session_id":"f1","prompt":"sent with the key file"}'
        Run "transcript" "" '{"hook_event_name":"PreCompact","session_id":"f1"}'
        Check "with no MEMBRAINCE_API_KEY, saves use the key file" { ((Uploaded) -join "|") -eq "key-f sent with the key file" }
        Remove-Item "$work\uploaded.txt"
        Run "prompt" "key-a" '{"hook_event_name":"UserPromptSubmit","session_id":"f2","prompt":"sent with the variable"}'
        Run "transcript" "key-a" '{"hook_event_name":"PreCompact","session_id":"f2"}'
        Check "MEMBRAINCE_API_KEY wins over the key file" { ((Uploaded) -join "|") -eq "key-a sent with the variable" }
    } finally {
        $env:USERPROFILE = $realProfile
    }
    "== codex (PowerShell): no key yet"
    $emptyHome = Join-Path $work "nokey-home"
    [void](New-Item -ItemType Directory -Force $emptyHome)
    $noKeyData = Join-Path $work "nokey-data"
    $realProfile = $env:USERPROFILE
    $env:USERPROFILE = $emptyHome
    try {
        function No-Key([string]$Action, [string]$Event) {
            $env:MEMBRAINCE_API_KEY = ""
            $env:MEMBRAINCE_URL = "http://127.0.0.1:$port"
            $env:PLUGIN_DATA = $noKeyData
            ('{"hook_event_name":"' + $Event + '","session_id":"n1","prompt":"hi"}' | powershell -NoProfile -ExecutionPolicy Bypass -File $script $Action | Out-String).Trim()
        }
        Check "with no key, session start says how to set up MemBraince" { Is-Notice (No-Key "session-start" "SessionStart") "MemBraince: automatic recall and save are off on this computer." }
        Check "the same day, it says it once" { -not (No-Key "session-start" "SessionStart") }
        Check "with no key, a prompt prints and queues nothing" { -not (No-Key "prompt" "UserPromptSubmit") -and @(Get-ChildItem -Path $noKeyData -Recurse -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 0 }
        Remove-Item -Recurse -Force $noKeyData
        $env:MEMBRAINCE_AUTO_RECALL = "false"; $env:MEMBRAINCE_AUTO_SAVE = "false"
        Check "with recall and save off, no key says nothing" { -not (No-Key "session-start" "SessionStart") }
        Remove-Item Env:\MEMBRAINCE_AUTO_RECALL; Remove-Item Env:\MEMBRAINCE_AUTO_SAVE
    } finally {
        $env:USERPROFILE = $realProfile
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
}
""
if ($failures -eq 0) { "all hook tests passed" } else { "$failures hook test(s) failed" }
exit $failures
