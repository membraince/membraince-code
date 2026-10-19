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

