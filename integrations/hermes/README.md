# MemBraince for Hermes

Long-term memory for [Hermes Agent](https://github.com/NousResearch/hermes-agent), backed by
[MemBraince](https://membraince.com).

- **Memory tools**: `membraince_recall`, `membraince_remember`, and `membraince_forget`, plus a `memory`
  skill for reviewing and correcting what is remembered (the skill needs Hermes 0.22 or later).
- **Recall automatically**: when a session starts, the memories most relevant to the project are added to
  the system prompt, with what earlier sessions in that folder learned about its code. Each prompt then
  adds what's relevant to it: in a folder MemBraince has learned, notes on the code it names; elsewhere,
  related memories (or nothing when none match).
- **Save automatically**: once Hermes has answered a prompt, the prompt you typed is queued on your
  machine. After a turn (at most every 15 minutes per session), before compaction, and when a session
  ends, the queue is sent as one save. Hermes's replies are never sent.
- **Learn the repository**: the files Hermes reads and edits and the commands it runs are queued with your
  prompts. MemBraince keeps only where code is defined, what changed and which tests passed, encrypted,
  and starts later sessions in the same folder with a short brief. Files named like secrets are never
  sent; turn the setting off for code that must not leave your machine.

Hermes uses one memory provider at a time, so MemBraince takes the place of any other you've chosen.
Hermes's own `MEMORY.md` and `USER.md` keep working.

## Setup

1. Create an account at https://membraince.com/portal, subscribe, and create an API key. The key is shown
   only once, and so is the recovery code that comes with your first key: store both in a password manager.
2. Run the installer and paste the key when it asks. It puts the key in Hermes's `.env` file, installs the
   plugin, and makes MemBraince your memory provider.

   macOS, Linux, and WSL:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/membraince/membraince-code/main/install.sh | sh
   ```

   Windows (PowerShell):

   ```powershell
   irm https://raw.githubusercontent.com/membraince/membraince-code/main/install.ps1 | iex
   ```

3. Start a new session.

Or install it with Hermes alone:

```bash
hermes plugins install membraince/membraince-code/integrations/hermes
```

Paste your key when asked (it stays hidden, and Hermes keeps it in its `.env` file), then answer `y` to
use MemBraince as your memory provider.

On older Hermes versions the last answer only enables the plugin. If `hermes memory status` doesn't show
`membraince` as the provider, run `hermes memory setup`, choose it, and press Enter to keep your key.

### Check it works

Tell Hermes "Remember that I prefer short commit messages." In a new session, ask "How do I like my commit
messages?" On Hermes 0.22 or later, when memories are added to a prompt, Hermes shows "MemBraince — recalled
relevant memory".

If MemBraince can't use your key, Hermes shows one MemBraince warning saying why: no subscription, a key it
doesn't accept, a project name it doesn't know, a key that can't unlock your memories, or a limit reached.
The warning repeats at most once a day. Until it's fixed, nothing is recalled, and what you type stays queued
on this computer for up to 30 days. To enter a new key, run `hermes memory setup` and choose MemBraince.

### Messaging platforms

In a direct message on Telegram, Discord, and the other platforms Hermes connects to, memory works as it does
in the terminal, except that nothing is learned about a repository. There, Hermes gives plugins no warning
line, so a key problem reaches you through Hermes's reply, also at most once a day.

In a group, channel, or thread, memory stays off: nothing is recalled or saved, and the memory tools aren't
offered, so other people's messages never reach your memories and your memories never come up in front of
them. Anyone you allow to message Hermes directly shares your memories.

### Settings

Set these in Hermes's `.env` file to change the defaults:

| Variable | Meaning | Default |
| --- | --- | --- |
| `MEMBRAINCE_API_KEY` | Your API key | none; memory is off without it |
| `MEMBRAINCE_USER` | Whose memories these are inside your account | `default` |
| `MEMBRAINCE_PROJECT` | A project name from the portal to save to and recall from | the key's home project |
| `MEMBRAINCE_AUTO_RECALL` | `false` turns off automatic recall | `true` |
| `MEMBRAINCE_AUTO_SAVE` | `false` turns off automatic save | `true` |
| `MEMBRAINCE_LEARN_CODE` | `false` turns off Learn the repository, to send only your prompts | `true` |
| `MEMBRAINCE_URL` | Where requests go | `https://membraince.com` |

To stop using MemBraince, run `hermes memory off`.

## What the plugin sends

Everything goes to `MEMBRAINCE_URL` (by default `https://membraince.com`), with your API key in the
`X-API-Key` header. Nothing is sent to any other service.

| When | Request | Contents |
| --- | --- | --- |
| A session starts, with automatic recall on | `POST /v1/integrations/hermes/session-start` | The session id and project folder path |
| A session starts, if an earlier session's save failed | `POST /v1/integrations/hermes/transcript` | That session's queued prompts and tool calls |
| You send a prompt, with automatic recall on | `POST /v1/integrations/hermes/prompt` | The prompt, session id, and project folder path. In a folder earlier sessions learned, MemBraince answers with notes on the code the prompt names; elsewhere, with memories related to it |
| Hermes answers a prompt | nothing | The prompt is added to the queue on your machine |
| Hermes read or edited a file, or ran a command, in that turn, with Learn the repository on | nothing | The tool call and its result (the file's contents, the edit, the command's output) are added to the queue on your machine |
| After a turn (at most every 15 minutes), before compaction, and when a session ends | `POST /v1/integrations/hermes/transcript` | The queued prompts and tool calls, each with its session id, project folder path, and time |
| Hermes calls a memory tool | `recall`, `remember`, or `forget` on `/v1/mcp` | What Hermes passes to the tool |

A turn you interrupt isn't saved. Cron jobs and subagents recall but save nothing, and neither do turns
another bot wrote. Nothing else Hermes does, such as web searches or messages it sends, is queued.

### The local queue

Automatic save keeps each prompt you type, and each tool call with Learn the repository on, as its own small
file until a save sends it: `membraince-queue-<hash>/<session>/` inside Hermes's home folder. `<hash>` is
derived from your API key, memory owner, project, and the server address (never the key itself), so a leftover
queue is only ever sent with the key that queued it, to the server it was meant for. The folder is readable by
your account only: on macOS and Linux through file permissions, on Windows by replacing the folder's inherited
permissions with full control for your account alone. A save deletes exactly the files it sent, once the server
confirms; a failed save keeps them, and a later session sends anything an earlier session couldn't, once that
queue has been left alone for an hour.

Each queued line carries an id. If a save reaches the server but its answer is lost, the files stay queued and
the next save resends the same lines with the same ids; the server stores each prompt once, recognizing lines
it already saved for the session. A session's queue left untouched for 30 days is deleted instead of kept
forever.

Automatic save sends every prompt you type, including anything sensitive you paste, and with Learn the
repository on, what Hermes reads and runs. Files named like secrets (`.env`, keys, credentials) are never
queued, and the server replaces credentials it recognizes in commands with `[redacted]`, but anything else
Hermes reads is sent. The `memory` skill's rule against saving secrets covers what the agent saves on purpose,
not automatic save. Don't paste secrets into a session, or turn automatic save off.

The plugin is one short Python file with no dependencies, [`__init__.py`](__init__.py), so you can read exactly
what runs.

Memories are encrypted with a key only your API keys and recovery code can unlock. See the
[privacy policy](https://membraince.com/privacy), [terms](https://membraince.com/terms), and
[support](https://membraince.com/support).
