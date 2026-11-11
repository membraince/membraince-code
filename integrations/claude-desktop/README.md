# MemBraince for Claude Desktop

Long-term memory for Claude Desktop, backed by [MemBraince](https://membraince.com). Desktop chats get
three memory tools: `recall`, `remember`, and `forget`.

## Install

The simplest way is the MemBraince connector. It needs no download and no API key.

1. Create an account at https://membraince.com/portal and subscribe.
2. In Claude Desktop, add a custom connector (under Connectors in Claude's settings) with the URL
   `https://membraince.com/v1/mcp`, and leave the OAuth fields empty.
3. Click Connect, sign in with your MemBraince account, and choose the project the connection saves to.
4. The first time, MemBraince shows a recovery code once: store it in a password manager. If the account
   already has API keys, enter one of them (or your recovery code) to unlock your memories instead.

The connector also works in claude.ai and the Claude mobile apps. Free Claude plans allow one custom connector. On
Team and Enterprise plans, an owner adds it for the organization.

### Or install the extension

The extension runs on your computer and uses an API key instead of signing in. It's a small Node bridge
(`server/index.js`, no dependencies) that forwards Desktop's local MCP messages to
`https://membraince.com/v1/mcp`.

1. Create an API key at https://membraince.com/portal. The key is shown only once, and so is the recovery
   code that comes with your first key: store both in a password manager.
2. Download
   [membraince-desktop-0.3.3.mcpb](https://github.com/membraince/membraince-code/releases/download/claude-desktop-v0.3.3/membraince-desktop-0.3.3.mcpb).
3. In Claude Desktop's settings, open Extensions, then Advanced settings, click Install Extension, and
   choose the file you downloaded. Paste the key when asked.

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
