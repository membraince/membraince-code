# MemBraince for Claude Code

Long-term memory for Claude Code, backed by [MemBraince](https://membraince.com).

- **Recall automatically**: when a session starts, the memories most relevant to the project are
  added as context, and each prompt adds memories relevant to it (or nothing when none match).
- **Save automatically**: each prompt you type is kept in a queue on your machine; before
  compaction and when a session ends, the queue is sent as one save. Only the prompts you typed
  are ever sent for saving; Claude's replies and tool output never leave your machine.
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

Everything goes to the Server URL setting (by default `https://membraince.com`), with your API key in
the `X-API-Key` header. Nothing is sent to any other service.

| When | Request | Contents |
| --- | --- | --- |
| A session starts | `POST /v1/integrations/claude-code/session-start` | The hook's session details, including the project folder path |
| You send a prompt | `recall` on `/v1/mcp` | The prompt text, to search for related memories |
| A session starts, if an earlier session's save failed | `POST /v1/integrations/claude-code/transcript` | That session's queued prompts |
| You send a prompt | nothing | The prompt is added to the queue on your machine |
| Before compaction, and when a session ends | `POST /v1/integrations/claude-code/transcript` | The queued prompts, each with its session id, project folder path, and time |
| Claude calls a tool | `recall`, `remember`, or `forget` on `/v1/mcp` | What Claude passes to the tool |

### The local queue

Automatic save keeps each prompt you type as its own small file until a save sends it:
`membraince-queue-<hash>/<session>/` inside the plugin's data folder (or your temporary folder if Claude Code doesn't
provide one). `<hash>` is derived from your API key, memory owner, project, and the server
address (never the key itself), so a leftover queue is only ever sent with the key that queued it, to the server it was
meant for. The folder is readable by your account only: on macOS and Linux through file
permissions, on Windows by replacing the folder's inherited permissions with full control for your
account alone. A save deletes exactly the files it sent, once the server confirms; a failed save
keeps them, and the next session sends anything an earlier session couldn't.

Each queued line carries an id. If a save reaches the server but its answer is lost, the files stay
queued and the next save resends the same lines with the same ids; the server stores each prompt
once, recognizing lines it already saved for the session. A session's
queue left untouched for 30 days is deleted instead of kept forever.

Automatic save sends every prompt you type, including anything sensitive you paste. The
`memory` skill's rule against saving secrets covers what the agent saves on purpose, not
automatic save. Don't paste secrets into a session, or turn automatic save off.

Turn off "Recall automatically" or "Save automatically" to stop the automatic requests. The hook
script, `scripts/membraince-hook.sh`, is plain `bash` and `curl`, so you can read exactly what runs.

Memories are encrypted with a key only your API keys and recovery code can unlock. See the
[privacy policy](https://membraince.com/privacy), [terms](https://membraince.com/terms),
and [support](https://membraince.com/support).
