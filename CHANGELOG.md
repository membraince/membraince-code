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
