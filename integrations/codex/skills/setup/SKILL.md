---
name: setup
description: Set up MemBraince on this computer, or find out why it isn't working. Use when the user asks to set up, install, connect, or fix MemBraince, or when a MemBraince warning says automatic recall and save are off.
---

Walk the user through these steps in order, doing what you can yourself. Never print, repeat, or ask for an API key: keys stay out of the conversation. Codex asks the user to approve commands that write outside the workspace or use the network; say so before running them.

1. **Check the memory tools.** Call `recall` with "MemBraince setup check".
   - If there are no MemBraince tools, MemBraince isn't connected: tell the user to connect it (Codex asks them to sign in when the tools are first used, or from `/plugins`) and to start a new session.
   - If the answer says the account has no active subscription, tell the user to subscribe at https://membraince.com/portal, then continue.
2. **Check for the hooks' key**, printing only yes or no:
   - Windows (PowerShell): `if ($env:MEMBRAINCE_API_KEY -or (Test-Path "$HOME\.config\membraince\api-key")) { "key: yes" } else { "key: no" }`
   - macOS and Linux: `if [ -n "${MEMBRAINCE_API_KEY:-}" ] || [ -s ~/.config/membraince/api-key ]; then echo "key: yes"; else echo "key: no"; fi`

   If there is one, go to step 5.
3. **Ask for a key.** Ask the user to create an API key at https://membraince.com/portal whose home project is the project they chose when connecting MemBraince, so the hooks and the memory tools use the same memories (the portal asks for their recovery code or another key). They should copy the key and reply "copied". Never ask them to paste it into the chat.
4. **Save the key from the clipboard.** These commands check that the clipboard holds a MemBraince key, save it where the hooks look, readable by the user's account only, and print only "saved":
   - Windows (PowerShell): `$k = "$(Get-Clipboard)".Trim(); if ($k -notmatch '^mb_live_[A-Za-z0-9_-]+$') { 'The clipboard does not hold a MemBraince API key.'; exit 1 }; New-Item -ItemType Directory -Force "$HOME\.config\membraince" | Out-Null; Set-Content -NoNewline -Path "$HOME\.config\membraince\api-key" -Value $k; 'saved'`
   - macOS: `k="$(pbpaste | tr -d '[:space:]')"; case "$k" in mb_live_*) ;; *) echo "The clipboard does not hold a MemBraince API key."; exit 1 ;; esac; mkdir -p ~/.config/membraince && (umask 077 && printf '%s' "$k" > ~/.config/membraince/api-key) && echo saved`
   - Linux: the macOS command with `{ wl-paste || xclip -o -selection clipboard || xsel -ob; } 2>/dev/null` in place of `pbpaste`.

   If `MEMBRAINCE_API_KEY` is set, the hooks use it instead of the file: tell the user to update or remove that variable.
5. **Check the key with MemBraince.** Send one request and print only the HTTP status:
   - Windows (PowerShell): `$k = if ($env:MEMBRAINCE_API_KEY) { $env:MEMBRAINCE_API_KEY } else { (Get-Content -Raw "$HOME\.config\membraince\api-key").Trim() }; try { (Invoke-WebRequest -Method Post -Uri https://membraince.com/v1/integrations/codex/session-start -Headers @{ "X-API-Key" = $k } -ContentType application/json -Body '{}' -UseBasicParsing).StatusCode } catch { [int]$_.Exception.Response.StatusCode }`
   - macOS and Linux: `k="${MEMBRAINCE_API_KEY:-$(cat ~/.config/membraince/api-key)}"; curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "X-API-Key: $k" -H 'Content-Type: application/json' -d '{}' https://membraince.com/v1/integrations/codex/session-start`

   Explain the answer: 200, the key works; 401, MemBraince doesn't accept it (back to step 3); 402, the account needs a subscription; 403, the key can't use its project, so check the key's projects in the portal; 423, the key can't unlock the account's encrypted memories, so create a new one (step 3); 429, the key has reached a limit, shown in the portal.
6. **Trust the hooks.** Tell the user to run `/hooks`, review and trust the MemBraince hooks, then quit and reopen Codex. Only they can do this.
7. **Try it.** In the new session, `remember` one thing the user tells you and `recall` it, or ask them to start a session and ask what you remember.
