# Tests for install.ps1 against tests/fake_server.py, with a throwaway home folder and
# stand-ins for the `hermes` and `codex` commands that record how they were called.
# Run from the repository root: powershell -ExecutionPolicy Bypass -File tests/install.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ("membraince-test-" + [Guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $work)
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { $python = (Get-Command python3).Source }
$server = Start-Process -FilePath $python -ArgumentList @("`"$repo\tests\fake_server.py`"", "`"$work`"") -PassThru -WindowStyle Hidden
for ($i = 0; $i -lt 100 -and -not (Test-Path "$work\port"); $i++) { Start-Sleep -Milliseconds 100 }
$port = (Get-Content "$work\port").Trim()
$failures = 0

function Check([string]$Description, [scriptblock]$Condition) {
    if (& $Condition) { "  ok   $Description" } else { "  FAIL $Description"; $script:failures++ }
}

$bin = Join-Path $work "bin"
[void](New-Item -ItemType Directory -Path $bin)
foreach ($name in "hermes", "codex") {
    Set-Content -Encoding ascii -Path "$bin\$name.cmd" -Value @"
@echo off
echo $name %*>>"$work\calls.txt"
if "%1 %2"=="config env-path" echo %FAKE_HERMES_ENV%
exit /b 0
"@
}

# Runs the installer with no terminal, as another process, and returns what it says.
function Setup([string]$UserHome, [string]$Key, [string]$Url = "http://127.0.0.1:$port") {
    $saved = @{}
    $settings = @{
        USERPROFILE = $UserHome; HOMEDRIVE = $UserHome.Substring(0, 2); HOMEPATH = $UserHome.Substring(2)
        XDG_CONFIG_HOME = ""; PATH = "$bin;$env:PATH"; FAKE_HERMES_ENV = "$UserHome\.hermes\.env"
        MEMBRAINCE_API_KEY = $Key; MEMBRAINCE_URL = $Url; MEMBRAINCE_SOURCE = ([Uri]$repo).AbsoluteUri
    }
    foreach ($name in $settings.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $settings[$name])
    }
    try {
        return ($null | powershell -NoProfile -ExecutionPolicy Bypass -File "$repo\install.ps1" | Out-String)
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}
function Calls([string]$Text) {
    if (-not (Test-Path "$work\calls.txt")) { return 0 }
    return @(Get-Content "$work\calls.txt" | Where-Object { $_.Contains($Text) }).Count
}

try {
    "== install.ps1"
    $userHome = Join-Path $work "home"
    [void](New-Item -ItemType Directory -Force -Path "$userHome\.config\opencode", "$userHome\.hermes")
    [IO.File]::WriteAllText("$userHome\.hermes\.env", "OTHER=1`nMEMBRAINCE_API_KEY=old`n")
    $said = Setup $userHome "key-a"
    Check "the key is checked with MemBraince before it's saved" { @(Get-Content "$work\routes.txt" | Where-Object { $_ -match "session-start" }).Count -eq 1 }
    Check "the key is saved in ~\.config\membraince\api-key, with no byte-order mark" { [IO.File]::ReadAllBytes("$userHome\.config\membraince\api-key").Length -eq 5 -and (Get-Content -Raw "$userHome\.config\membraince\api-key") -eq "key-a" }
    Check "the key file is limited to this account" {
        $rules = @((Get-Acl "$userHome\.config\membraince\api-key").Access)
        $rules.Count -eq 1 -and $rules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -eq [Security.Principal.WindowsIdentity]::GetCurrent().User
    }
    Check "OpenCode gets the plugin file in its plugins folder" { (Get-FileHash "$userHome\.config\opencode\plugins\membraince.js").Hash -eq (Get-FileHash "$repo\integrations\opencode\membraince.js").Hash }
    Check "Hermes's .env gets the key once and keeps its other lines" { ((Get-Content "$userHome\.hermes\.env") -join "|") -eq "OTHER=1|MEMBRAINCE_API_KEY=key-a" }
    Check "Hermes installs the plugin without questions and makes it the memory provider" { (Calls "hermes plugins install membraince/membraince-code/integrations/hermes --force --enable") -eq 1 -and (Calls "hermes config set memory.provider membraince") -eq 1 }
    Check "Codex adds the marketplace and the plugin" { (Calls "codex plugin marketplace add membraince/membraince-code") -eq 1 -and (Calls "codex plugin add membraince@membraince") -eq 1 }
    Check "each agent found gets its own line" { $said -match "(?s)OpenCode: MemBraince added\..*Hermes: MemBraince is now your memory provider\..*Codex: MemBraince added\." }
    Check "the key itself is never printed" { $said -notmatch "key-a" }

    $said = Setup $userHome ""
    Check "run again with no key given, it uses the saved one" { $said -match "Using the key already saved" -and (Get-Content -Raw "$userHome\.config\membraince\api-key") -eq "key-a" }

    $fresh = Join-Path $work "fresh"
    [void](New-Item -ItemType Directory -Force -Path "$fresh\.config\opencode")
    Set-Content -Path "$work\status" -Value "401"
    $said = Setup $fresh "key-bad"
    Check "a key MemBraince doesn't accept is not saved, and nothing is installed" { -not (Test-Path "$fresh\.config\membraince\api-key") -and -not (Test-Path "$fresh\.config\opencode\plugins\membraince.js") }
    Set-Content -Path "$work\status" -Value "402"
    $said = Setup $fresh "key-b"
    Check "with no subscription the key is saved and the installer says memory is off" { $said -match "no subscription yet" -and (Get-Content -Raw "$fresh\.config\membraince\api-key") -eq "key-b" }
    Remove-Item "$work\status"
    $said = Setup $fresh "key-c" "http://127.0.0.1:1"
    Check "when MemBraince can't be reached the key is saved unchecked" { $said -match "saved unchecked" -and (Get-Content -Raw "$fresh\.config\membraince\api-key") -eq "key-c" }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
}
""
if ($failures -eq 0) { "all install tests passed" } else { "$failures install test(s) failed" }
exit $failures
