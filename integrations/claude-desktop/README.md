# MemBraince for Claude Desktop

A Claude Desktop extension that gives Desktop chats three memory tools: `recall`, `remember`,
and `forget`. It's a small Node bridge (`server/index.js`, no dependencies) that forwards
Desktop's local MCP messages to `https://membraince.com/v1/mcp`.

## Install

The simplest way is the MemBraince connector. It needs no download and no API key.

1. Create an account at https://membraince.com/portal and subscribe.
2. In Claude Desktop, add a custom connector (under Connectors in Claude's settings) with the URL
   `https://membraince.com/v1/mcp`, and leave the OAuth fields empty.
3. Click Connect, sign in with your MemBraince account, and choose the project the connection saves to. If you've
   already created API keys, enter one (or your recovery code) once to unlock your memories.

The connector also works in claude.ai and the Claude mobile apps. Free Claude plans allow one custom connector. On
Team and Enterprise plans, an owner adds it for the organization.

### Or install the extension

The extension runs on your computer and uses an API key instead of signing in.

1. Create an API key at https://membraince.com/portal.
2. Download
   [membraince-desktop-0.3.3.mcpb](https://github.com/membraince/membraince-code/releases/download/claude-desktop-v0.3.3/membraince-desktop-0.3.3.mcpb).
3. Open the file in Claude Desktop and paste the key when asked.

Settings: API key, memory owner (use the same value as in Claude Code to share memories),
project, and server URL.

### Check it works

Ask Claude "Remember that I prefer short commit messages." In a new chat, ask "How do I like my commit messages?"

## What it sends

Only what Claude passes to a tool, sent to the server URL with your API key in `X-API-Key`.

## Build

```bash
python scripts/build-desktop.py
```

writes `dist/membraince-desktop-<version>.mcpb`.
