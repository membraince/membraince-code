# MemBraince for Claude Code

Long-term memory for Claude Code, backed by [MemBraince](https://membraince.com).

- **Recall automatically**: when a session starts, the memories most relevant to the project are
  added as context, and each prompt adds memories relevant to it (or nothing when none match).
- **Save automatically**: before compaction and when a session ends, the messages you typed
  since the last save are sent as one save. Claude's replies and tool output are not saved.
- **Tools**: `recall`, `remember`, and `forget` on the `membraince` MCP server, plus a `memory`
  skill for reviewing and correcting what is remembered.

## Setup

1. Create an account and an API key at https://membraince.com/portal.
2. In Claude Code, add this repository as a marketplace and install the plugin:

   ```
   /plugin marketplace add membraince/membraince-code
   /plugin install membraince@membraince
   ```

3. Paste the key when asked. It is kept in your system's credential store.

Settings (`/plugin`, then MemBraince): API key, memory owner, project, server URL, and the two
automatic behaviours. The hooks need `bash` and `curl`, which Claude Code already requires.

## What the plugin sends

Everything goes to the server URL in the settings (by default `https://membraince.com`), with your
API key in the `X-API-Key` header. Nothing is sent anywhere else.

| When | Request | Contents |
| --- | --- | --- |
| A session starts | `POST /v1/integrations/claude-code/session-start` | The hook's session details, including the project folder path |
| You send a prompt | `recall` on `/v1/mcp` | The prompt text, to search for related memories |
| Before compaction, and when a session ends | `POST /v1/integrations/claude-code/transcript` | The last 2 MB of the session transcript; the server keeps only the messages you typed and ignores Claude's replies and tool output |
| Claude calls a tool | `recall`, `remember`, or `forget` on `/v1/mcp` | What Claude passes to the tool |

Turn off "Recall automatically" or "Save automatically" to stop the first three. The scripts in
`scripts/` are plain `bash` and `curl`, so you can read exactly what runs.

Memories are encrypted with a key only your API keys and recovery code can unlock. See the
[privacy policy](https://membraince.com/privacy), [terms](https://membraince.com/terms),
and [support](https://membraince.com/support).
