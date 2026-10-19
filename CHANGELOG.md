# Changelog

## Unreleased

- First public release of the MemBraince integrations, under the MIT license.
- Claude Code plugin 0.5.0: installs from this repository (`/plugin marketplace add membraince/membraince-code`)
  and documents exactly what it sends.
- Claude Desktop extension 0.3.2: bundles are built with `scripts/build-desktop.py` and attached to releases.
- Codex plugin 0.1.0 (testing): memory tools, `memory` skill, and hooks for automatic recall and save on macOS, Linux, and Windows.
- OpenCode plugin (testing): automatic recall and save, with the MCP server for the memory tools.
- Claude Code plugin 0.5.1 and Codex plugin 0.1.1: the hooks filter the session file on your machine, so only lines holding your own messages are sent.
- Codex plugin 0.1.1: also saves after a turn (at most every 15 minutes per session), so saving no longer depends on the 3-second session-end hook; shorter listing tagline.
- Claude Code plugin 0.6.0 and Codex plugin 0.2.0: automatic save no longer reads the session file. The prompt hook queues each prompt you type on your machine, and saves send that queue, clearing it (and, for Codex, starting the 15-minute timer) only after the save succeeds.
- Claude Code plugin 0.6.1 and Codex plugin 0.2.1: one save per session at a time. Saves take a per-session lock around recovery, upload, and cleanup; a save that finds another in progress steps aside, and a lock left by a crashed save expires after 2 minutes.
- Claude Code plugin 0.6.2 and Codex plugin 0.2.2: no prompt can be lost between queueing and saving. A brief queue lock covers adding a prompt and a save taking the queue (never the upload), and a failed save keeps its prompts pending instead of copying them back over the queue.
- Claude Code plugin 0.7.0 and Codex plugin 0.3.0: queued prompts are one file each, written atomically, so
  no lock is needed to add one and a save deletes exactly what it sent. The save lock records its owner and
  is cleared only when that process is gone. A new session sends prompts an earlier session's failed save
  left, but only with the same key (and, for Claude Code, the same memory owner and project). Queue files
  are readable by your account only, and a queue untouched for 30 days is deleted. Session end never waits
  on a lock. The Claude Code hooks are now one script, `membraince-hook.sh`.
- Codex plugin 0.3.0: the hooks no longer take `MEMBRAINCE_USER` or `MEMBRAINCE_PROJECT`, so automatic
  recall and save always use the same memories as the memory tools.
- OpenCode: the MCP entry passes `MEMBRAINCE_USER` and `MEMBRAINCE_PROJECT` too, matching the plugin.
- `memory` skills: a correction saves the new memory before forgetting the old one.
- Tests for the hook scripts (`tests/`), run in CI on Linux, macOS, and Windows.
- Claude Code plugin 0.7.1 and Codex plugin 0.3.1: each queued line carries an explicit id, and a save
  whose answer is lost resends the same lines. A save builds its upload in one file first, so a failed
  read never deletes unsent prompts. On Windows the queue folder's permissions are limited to your
  account. Session start shares one 15-second deadline between recall and recovery. The queue's
  identity includes the server address, so a queue is never sent to a different server.
- Codex plugin 0.4.0: the MCP server connects by signing in to MemBraince (OAuth) instead of with an API
  key. ChatGPT and remote Codex plugins can't send custom API keys, so with 0.3.x the memory tools never
  connected there. The hooks still use `MEMBRAINCE_API_KEY`.

