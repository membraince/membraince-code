# MemBraince for Claude Desktop

A Claude Desktop extension that gives Desktop chats three memory tools: `recall`, `remember`,
and `forget`. It's a small Node bridge (`server/index.js`, no dependencies) that forwards
Desktop's local MCP messages to `https://membraince.com/v1/mcp`.

## Install

1. Create an account and an API key at https://membraince.com/portal.
2. Download `membraince-desktop-<version>.mcpb` from the
   [latest release](https://github.com/membraince/membraince-code/releases/latest).
3. Open the file in Claude Desktop and paste the key when asked.

Settings: API key, memory owner (use the same value as in Claude Code to share memories),
project, and server URL.

Prefer no download? On claude.ai and the Claude apps you can add MemBraince as a custom
connector instead: see [docs/mcp.md](../../docs/mcp.md#claudeai-and-the-claude-apps).

## What it sends

Only what Claude passes to a tool, sent to the server URL with your API key in `X-API-Key`.

## Build

```bash
python scripts/build-desktop.py
```

writes `dist/membraince-desktop-<version>.mcpb`.
