# MemBraince setup for Windows. Saves your API key once and adds MemBraince to
# each coding agent it finds on this computer:
#
#   irm https://raw.githubusercontent.com/membraince/membraince-code/main/install.ps1 | iex
#
# Run it again to change the key or to update the integrations.
#
# What it does, and nothing else:
#   - asks for your API key (or takes MEMBRAINCE_API_KEY), checks it with
#     MemBraince, and saves it in ~\.config\membraince\api-key, readable by your
#     account only;
#   - OpenCode: puts membraince.js in OpenCode's plugins folder;
#   - Hermes: puts the key in Hermes's .env file, installs the plugin with
#     `hermes plugins install`, and makes MemBraince the memory provider;
#   - Codex: installs the plugin with `codex plugin add`.

& {
    $ErrorActionPreference = "Continue"
    $ProgressPreference = "SilentlyContinue"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $base = if ($env:MEMBRAINCE_URL) { $env:MEMBRAINCE_URL.TrimEnd("/") } else { "https://membraince.com" }
    $source = if ($env:MEMBRAINCE_SOURCE) { $env:MEMBRAINCE_SOURCE.TrimEnd("/") } else { "https://raw.githubusercontent.com/membraince/membraince-code/main" }
    $portal = "https://membraince.com/portal"
    $repo = "https://github.com/membraince/membraince-code"
    $keyFolder = Join-Path $HOME ".config\membraince"
    $keyFile = Join-Path $keyFolder "api-key"
    $noBom = New-Object Text.UTF8Encoding($false)
    $found = $false

    # The answer MemBraince gives this key, as an HTTP status (0 when it can't be reached).
    function Test-Key([string]$Key) {
        try {
            $response = Invoke-WebRequest -Uri "$base/v1/integrations/opencode/session-start" -Method Post `
                -Headers @{ "X-API-Key" = $Key } -ContentType "application/json" -Body '{"cwd":""}' -TimeoutSec 15 -UseBasicParsing
            return [int]$response.StatusCode
        } catch {
            if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
            return 0
        }
    }

    # Runs one of an agent's own commands with an empty standard input, so it
    # never waits for an answer. True when the command succeeded.
    function Invoke-Quiet([string]$Command, [string[]]$Arguments) {
        $null | & $Command @Arguments *> $null
        return $LASTEXITCODE -eq 0
    }

    Write-Host "MemBraince setup"
    $key = "$($env:MEMBRAINCE_API_KEY)".Trim()
    if (-not $key -and (Test-Path -LiteralPath $keyFile)) {
        $key = "$(Get-Content -LiteralPath $keyFile -Raw)".Trim()
        if ($key) { Write-Host "Using the key already saved in ~\.config\membraince\api-key." }
    }
    $status = 0
    for ($tries = 0; ; $tries++) {
        if ($tries -ge 3) {
            Write-Host "Create a key at $portal and run this again."
            return
        }
        if (-not $key) {
            if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
                Write-Host "No API key to use. Set MEMBRAINCE_API_KEY to a key from $portal and run this again."
                return
            }
            $secure = Read-Host -AsSecureString "Paste your MemBraince API key (create one at $portal). It stays hidden"
            $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)).Trim()
        }
        if ($key -notmatch '^[A-Za-z0-9._-]+$') {
            Write-Host "That doesn't look like a MemBraince API key."
            $key = ""
            continue
        }
        $status = Test-Key $key
        if ($status -eq 401) {
            Write-Host "MemBraince didn't accept that key."
            $key = ""
            continue
        }
        if ($status -eq 423) {
            Write-Host "That key can't unlock your encrypted MemBraince memories. Create a new key at $portal and run this again."
            return
        }
        break
    }
    if ($status -eq 402) {
        Write-Host "This account has no subscription yet, so memory stays off until you subscribe at $portal."
    } elseif ($status -notin 200, 403, 429) {
        Write-Host "Couldn't reach MemBraince to check the key, so it's saved unchecked."
    }

    # The key file is limited to this account: inherited permissions are
    # replaced by full control for the current user only.
    [void](New-Item -ItemType Directory -Force -Path $keyFolder)
    [IO.File]::WriteAllText($keyFile, $key, $noBom)
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($me, "FullControl", "Allow")))
    [IO.File]::SetAccessControl($keyFile, $acl)
    Write-Host "Key saved in ~\.config\membraince\api-key."

    # OpenCode loads every file in its plugins folder; the plugin reads the saved
    # key and adds the memory tools itself, so opencode.json stays untouched.
    $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME ".config" }
    $opencode = Join-Path $configHome "opencode"
    if ((Test-Path -LiteralPath $opencode) -or (Get-Command opencode -ErrorAction SilentlyContinue)) {
        $found = $true
        $target = Join-Path $opencode "plugins\membraince.js"
        $older = Join-Path $opencode "plugin\membraince.js"
        if (Test-Path -LiteralPath $older) { $target = $older }
        try {
            [void](New-Item -ItemType Directory -Force -Path (Split-Path $target))
            Invoke-WebRequest -Uri "$source/integrations/opencode/membraince.js" -OutFile "$target.new" -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
            Move-Item -Force -LiteralPath "$target.new" -Destination $target -ErrorAction Stop
            Write-Host "OpenCode: MemBraince added. Restart OpenCode to use it."
        } catch {
            Remove-Item -Force -LiteralPath "$target.new" -ErrorAction SilentlyContinue
            Write-Host "OpenCode: couldn't download the plugin. Check your connection and run this again."
        }
    }

    # Hermes reads the key from its own .env file.
    if (Get-Command hermes -ErrorAction SilentlyContinue) {
        $found = $true
        $done = $false
        $envFile = "$($null | & hermes config env-path 2>$null | Select-Object -Last 1)".Trim()
        if ($envFile) {
            try {
                [void](New-Item -ItemType Directory -Force -Path (Split-Path $envFile))
                $lines = @()
                if (Test-Path -LiteralPath $envFile) {
                    $lines = @(Get-Content -LiteralPath $envFile | Where-Object { $_ -notmatch '^MEMBRAINCE_API_KEY=' })
                }
                [IO.File]::WriteAllLines($envFile, [string[]]($lines + "MEMBRAINCE_API_KEY=$key"), $noBom)
                $done = (Invoke-Quiet hermes @("plugins", "install", "membraince/membraince-code/integrations/hermes", "--force", "--enable")) -and
                    (Invoke-Quiet hermes @("config", "set", "memory.provider", "membraince"))
            } catch {
                $done = $false
            }
        }
        if ($done) {
            Write-Host "Hermes: MemBraince is now your memory provider. Start a new session to use it."
        } else {
            Write-Host "Hermes: setup didn't finish. Run ``hermes plugins install membraince/membraince-code/integrations/hermes`` to see why."
        }
    }

    # Codex's hooks read the saved key. Signing in and trusting the hooks are
    # yours to do, inside Codex.
    if (Get-Command codex -ErrorAction SilentlyContinue) {
        $found = $true
        [void](Invoke-Quiet codex @("plugin", "marketplace", "add", "membraince/membraince-code"))
        [void](Invoke-Quiet codex @("plugin", "marketplace", "upgrade", "membraince"))
        if (Invoke-Quiet codex @("plugin", "add", "membraince@membraince")) {
            Write-Host "Codex: MemBraince added. Open Codex, sign in when it asks to connect MemBraince, then run /hooks and trust the MemBraince hooks."
        } else {
            Write-Host "Codex: couldn't add the plugin. Add it from /plugins in Codex: $repo/tree/main/integrations/codex"
        }
    } elseif (Test-Path -LiteralPath (Join-Path $HOME ".codex")) {
        $found = $true
        Write-Host "Codex: add MemBraince from Plugins in the Codex app. Steps: $repo/tree/main/integrations/codex"
    }

    if (Get-Command claude -ErrorAction SilentlyContinue) {
        $found = $true
        Write-Host "Claude Code: run /plugin marketplace add membraince/membraince-code, then /plugin install membraince@membraince, and paste your key when asked."
    }

    if ($found) {
        Write-Host 'Check it works: tell your agent "Remember that I prefer short commit messages", then ask about it in a new session.'
    } else {
        Write-Host "No OpenCode, Hermes, Codex, or Claude Code found on this computer. Install one and run this again; other tools are listed at $repo"
    }
}
