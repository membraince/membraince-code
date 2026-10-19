# MemBraince for Codex

Long-term memory for [Codex](https://developers.openai.com/codex), backed by
[MemBraince](https://membraince.com).

- **Memory tools**: `recall`, `remember`, and `forget` on the `membraince` MCP server, plus a
  `memory` skill for reviewing and correcting what is remembered.
- **Recall automatically**: when a session starts, memories related to the project folder are added
  as context, and each prompt adds memories related to it (or nothing when none match).
- **Save automatically**: before compaction and when a session ends, the messages you typed since the
  last save are sent as one save. Codex's replies and tool output are not saved.

## Setup

1. Create an account and an API key at https://membraince.com/portal.
2. Add this repository as a plugin marketplace:

   ```bash
   codex plugin marketplace add membraince/membraince-code
   ```

3. Open the plugin directory (`/plugins` in the CLI, or **Plugins** in the app), choose the
   MemBraince marketplace, and install **MemBraince**. Paste your API key when Codex asks you to
   connect the MCP server.
4. For automatic recall and save, also put the key in the `MEMBRAINCE_API_KEY` environment
   variable (hooks run as separate commands and can't read Codex's stored connection), then
   restart Codex.
5. Codex runs plugin hooks only after you trust them: run `/hooks`, review the MemBraince hooks, and
   trust them. Codex asks again whenever a hook changes.

Start a new session afterwards. The hooks need `bash` and `curl` on macOS and Linux, and Windows
PowerShell on Windows.

### Settings

Set these environment variables to change the defaults:

| Variable | Meaning | Default |
| --- | --- | --- |
| `MEMBRAINCE_API_KEY` | Your API key (hooks only) | none; hooks do nothing without it |
| `MEMBRAINCE_USER` | Whose memories these are inside your account | `default` |
| `MEMBRAINCE_PROJECT` | A project name from the portal to save to and recall from | the key's home project |
| `MEMBRAINCE_AUTO_RECALL` | `false` turns off automatic recall | `true` |
| `MEMBRAINCE_AUTO_SAVE` | `false` turns off automatic save | `true` |

## What the plugin sends

Everything goes to `https://membraince.com` with your API key in the `X-API-Key` header. Nothing is
sent anywhere else.

| When | Request | Contents |
| --- | --- | --- |
| A session starts | `POST /v1/integrations/codex/session-start` | The hook input: session id, project folder path, model |
| You send a prompt | `POST /v1/integrations/codex/prompt` | The hook input, including the prompt text |
| Before compaction, and when a session ends | `POST /v1/integrations/codex/transcript` | The hook input and the last 2 MB of the session file; the server keeps only the messages you typed |
| Codex calls a tool | `recall`, `remember`, or `forget` on `/v1/mcp` | What Codex passes to the tool |

The hook scripts in `scripts/` are short and readable: `membraince-hook.sh` (bash and curl) and
`membraince-hook.ps1` (Windows PowerShell).

## Without the plugin

Add the MCP server to `~/.codex/config.toml` to get the memory tools only:

```toml
[mcp_servers.membraince]
url = "https://membraince.com/v1/mcp"
env_http_headers = { "X-API-Key" = "MEMBRAINCE_API_KEY" }
```

Memories are encrypted with a key only your API keys and recovery code can unlock. See the
[privacy policy](https://membraince.com/privacy), [terms](https://membraince.com/terms), and
[support](https://membraince.com/support).
