# MemBraince for Codex

Long-term memory for [Codex](https://developers.openai.com/codex), backed by
[MemBraince](https://membraince.com).

- **Memory tools**: `recall`, `remember`, and `forget` on the `membraince` MCP server, plus a
  `memory` skill for reviewing and correcting what is remembered.
- **Recall automatically**: when a session starts, memories related to the project folder are added
  as context, and each prompt adds memories related to it (or nothing when none match).
- **Save automatically**: each prompt you type is queued on your machine. After a turn (at most
  every 15 minutes per session), before compaction, and when a session ends, the queue is sent as one
  save. Only the prompts you typed are ever sent for saving; Codex's replies and tool output never
  leave your machine.

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
| `MEMBRAINCE_AUTO_RECALL` | `false` turns off automatic recall | `true` |
| `MEMBRAINCE_AUTO_SAVE` | `false` turns off automatic save | `true` |
| `MEMBRAINCE_URL` | Where the hooks send requests | `https://membraince.com` |

The hooks and the memory tools always use the same memories: the key's home project and the
default memory owner. To keep separate memories, for example per client, use a separate API key
whose home project is that client's project.

## What the plugin sends

The hooks send everything to `MEMBRAINCE_URL` (by default `https://membraince.com`), and the memory
tools to `https://membraince.com`, with your API key in the `X-API-Key` header. Nothing is sent to
any other service.

| When | Request | Contents |
| --- | --- | --- |
| A session starts | `POST /v1/integrations/codex/session-start` | The hook input: session id, project folder path, model |
| A session starts, if an earlier session's save failed | `POST /v1/integrations/codex/transcript` | That session's queued prompts |
| You send a prompt | `POST /v1/integrations/codex/prompt` | The hook input, including the prompt text, to recall related memories; the prompt is also added to the local queue |
| After a turn (at most every 15 minutes), before compaction, and when a session ends | `POST /v1/integrations/codex/transcript` | The queued prompts (each with its session id, project folder path, and time) |
| Codex calls a tool | `recall`, `remember`, or `forget` on `/v1/mcp` | What Codex passes to the tool |

### The local queue

Automatic save keeps each prompt you type as its own small file until a save sends it:
`membraince-queue-<hash>/<session>/` inside Codex's data folder for the plugin (or your temporary folder if Codex doesn't
provide one). `<hash>` is derived from your API key (never the key
itself), so a leftover queue is only ever sent where it was meant to go. The files are readable by
your account only. A save deletes exactly the files it sent, once the server confirms; a failed
save keeps them, and the next session sends anything an earlier session couldn't. A session's
queue left untouched for 30 days is deleted instead of kept forever.

Automatic save sends every prompt you type, including anything sensitive you paste. The
`memory` skill's rule against saving secrets covers what the agent saves on purpose, not
automatic save. Don't paste secrets into a session, or turn automatic save off.

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
