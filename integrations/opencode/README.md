# MemBraince for OpenCode

Long-term memory for [OpenCode](https://opencode.ai), backed by [MemBraince](https://membraince.com).

- **Memory tools**: `recall`, `remember`, and `forget`, from the MemBraince MCP server, which the plugin
  adds for you.
- **Recall automatically**: with each message you send, memories related to it (and, on a session's
  first message, to the project) are added to the system prompt.
- **Save automatically**: when a session goes idle, the messages you typed since the last save are
  sent as one save, at most once every 15 minutes per session, and again when a session is
  compacted. OpenCode's replies and tool output are not saved.

## Setup

1. Create an account at https://membraince.com/portal, subscribe, and create an API key.
2. Run the installer and paste the key when it asks.

   macOS, Linux, and WSL:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/membraince/membraince-code/main/install.sh | sh
   ```

   Windows (PowerShell):

   ```powershell
   irm https://raw.githubusercontent.com/membraince/membraince-code/main/install.ps1 | iex
   ```

3. Restart OpenCode.

The installer saves the key in `~/.config/membraince/api-key`, readable by your account only, and puts
[`membraince.js`](membraince.js) in OpenCode's plugins folder. `opencode.json` stays as it is: the plugin
adds the memory tools' server when OpenCode starts. Run the installer again to change the key or update
the plugin. To remove MemBraince, delete `~/.config/opencode/plugins/membraince.js` and the key file.

### By hand

Copy [`membraince.js`](membraince.js) into `~/.config/opencode/plugins/` (or `.opencode/plugins/` in a
project) and give it a key: the `MEMBRAINCE_API_KEY` environment variable, or the file
`~/.config/membraince/api-key`. Then restart OpenCode.

To set the memory tools' server up yourself, add a `membraince` entry to your OpenCode config
(`~/.config/opencode/opencode.json`, or `opencode.json` in a project). The plugin leaves an entry with
that name alone:

   ```json
   {
     "$schema": "https://opencode.ai/config.json",
     "mcp": {
       "membraince": {
         "type": "remote",
         "url": "https://membraince.com/v1/mcp",
         "headers": {
           "X-API-Key": "{env:MEMBRAINCE_API_KEY}",
           "X-MemBraince-User": "{env:MEMBRAINCE_USER}",
           "X-MemBraince-Project": "{env:MEMBRAINCE_PROJECT}"
         },
         "oauth": false
       }
     }
   }
   ```

The plugin has no dependencies. Automatic recall uses OpenCode's
`experimental.chat.system.transform` hook, so a future OpenCode release may change how it works;
the memory tools keep working either way.

### Check it works

Tell OpenCode "Remember that I prefer short commit messages." In a new session, ask "How do I like my commit
messages?" If MemBraince can't use your key, OpenCode shows a MemBraince warning saying why.

### Settings

The plugin reads these for automatic recall and save and for the memory tools, so both use the same
memories. An unset variable falls back to the default.

| Variable | Meaning | Default |
| --- | --- | --- |
| `MEMBRAINCE_API_KEY` | Your API key | the key in `~/.config/membraince/api-key`; the plugin does nothing without a key |
| `MEMBRAINCE_USER` | Whose memories these are inside your account | `default` |
| `MEMBRAINCE_PROJECT` | A project name from the portal to save to and recall from | the key's home project |
| `MEMBRAINCE_AUTO_RECALL` | `false` turns off automatic recall | `true` |
| `MEMBRAINCE_AUTO_SAVE` | `false` turns off automatic save | `true` |

## What the plugin sends

The plugin and the memory tools send to `MEMBRAINCE_URL` (by default `https://membraince.com`), with
your API key in the `X-API-Key` header. Nothing is sent to any other service. Automatic save sends every message you
type, including anything sensitive you paste; don't paste secrets, or turn automatic save off.

| When | Request | Contents |
| --- | --- | --- |
| A session's first message | `POST /v1/integrations/opencode/session-start` | The project folder path |
| Each message you send | `POST /v1/integrations/opencode/prompt` | The message text |
| A session goes idle or is compacted | `POST /v1/integrations/opencode/messages` | The session id, project folder path, and the text of the messages you typed |
| OpenCode calls a tool | `recall`, `remember`, or `forget` on `/v1/mcp` | What OpenCode passes to the tool |

Memories are encrypted with a key only your API keys and recovery code can unlock. See the
[privacy policy](https://membraince.com/privacy), [terms](https://membraince.com/terms), and
[support](https://membraince.com/support).
