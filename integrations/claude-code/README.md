# MemBraince for Claude Code

Long-term memory for Claude Code, backed by [MemBraince](https://membraince.com).

- **Recall automatically**: when a session starts, the memories most relevant to the project are
  added as context, and each prompt adds memories relevant to it (or nothing when none match).
- **Save automatically**: each prompt you type is kept in a queue on your machine; before
  compaction and when a session ends, the queue is sent as one save.
- **Learn the repository**: the files Claude reads and edits and the commands it runs are queued
  with your prompts. MemBraince keeps only where code is defined, what changed and which tests
  passed, encrypted, and starts later sessions in the same folder with a short brief. Files named
  like secrets are never sent; turn the setting off for code that must not leave your machine.
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

Settings (`/plugin`, then MemBraince): API key, memory owner, project, server URL, the two
automatic behaviours, and Learn the repository. The hooks need `bash` and `curl`, which Claude Code already requires.

## What the plugin sends

Everything goes to the Server URL setting (by default `https://membraince.com`), with your API key in
the `X-API-Key` header. Nothing is sent to any other service.

| When | Request | Contents |
| --- | --- | --- |
| A session starts | `POST /v1/integrations/claude-code/session-start` | The hook's session details, including the project folder path |
| You send a prompt | `recall` on `/v1/mcp` | The prompt text, to search for related memories |
| You send a prompt, with Learn the repository on | `POST /v1/integrations/claude-code/brief` | The prompt and the project folder path, to find what earlier sessions learned about the code it names |
| A session starts, if an earlier session's save failed | `POST /v1/integrations/claude-code/transcript` | That session's queued prompts and tool calls |
| You send a prompt | nothing | The prompt is added to the queue on your machine |
| Claude reads or edits a file, or runs a command, with Learn the repository on | nothing | The tool call and its result (the file's contents, the edit, the command's output) are added to the queue on your machine |
| Before compaction, and when a session ends | `POST /v1/integrations/claude-code/transcript` | The queued prompts and tool calls, each with its session id, project folder path, and time |
| Claude calls a tool | `recall`, `remember`, or `forget` on `/v1/mcp` | What Claude passes to the tool |

### The local queue

Automatic save keeps each prompt you type, and each tool call with Learn the repository on, as its
own small file until a save sends it:
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

Automatic save sends every prompt you type, including anything sensitive you paste, and with
Learn the repository on, what Claude reads and runs. Files named like secrets (`.env`, keys,
credentials) are never queued, and the server replaces credentials it recognizes in commands with
`[redacted]`, but anything else Claude reads is sent. The `memory` skill's rule against saving
secrets covers what the agent saves on purpose, not automatic save. Don't paste secrets into a
session, or turn automatic save off.

Turn off "Recall automatically" or "Save automatically" to stop the automatic requests, or "Learn
the repository" to send only your prompts. The hook
script, `scripts/membraince-hook.sh`, is plain `bash` and `curl`, so you can read exactly what runs.

Memories are encrypted with a key only your API keys and recovery code can unlock. See the
[privacy policy](https://membraince.com/privacy), [terms](https://membraince.com/terms),
and [support](https://membraince.com/support).
