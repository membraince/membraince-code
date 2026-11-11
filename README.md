<p align="center"><img src="docs/assets/logo.png" alt="MemBraince" width="160"></p>

# MemBraince integrations

**Memory with receipts, in the tools you already use.**

[MemBraince](https://membraince.com) is a hosted long-term memory service. This repository holds
the open-source pieces that connect it to coding agents and AI assistants: plugins, extensions,
and configuration for each one. The integrations are thin by design. They talk to one endpoint,
run no background service on your machine, and every script is short enough to read in a minute.

What you get in a connected agent:

- **Recall**: memories related to your project and your prompt, added as context.
- **Remember**: durable facts, preferences, and decisions saved across sessions and tools.
- **Receipts**: every memory links back to the conversation it came from, and a correction keeps
  the history instead of erasing it.
- **Your key, your data**: memories are encrypted with a key only your API keys and recovery code
  can unlock.

## Get started

Create an account at https://membraince.com/portal and subscribe, then follow the steps for your tool.

### Claude Code

1. In the portal, create an API key. The key is shown only once, and so is the recovery code that comes
   with your first key: store both in a password manager.
2. In Claude Code, run:

   ```
   /plugin marketplace add membraince/membraince-code
   /plugin install membraince@membraince
   ```

3. Paste the key when Claude Code asks for it. If it doesn't ask, run
   `/plugin configure membraince@membraince`.

### Claude Desktop and claude.ai

These sign in to MemBraince, so no API key is needed.

1. In Claude's settings, open Connectors and add a custom connector with the URL
   `https://membraince.com/v1/mcp`. Leave the OAuth fields empty.
2. Click Connect, sign in with your MemBraince account, and choose the project the connection saves to.
3. The first time, MemBraince shows a recovery code once: store it in a password manager. If the account
   already has API keys, enter one of them (or your recovery code) to unlock your memories instead.

The connector then works in the Claude mobile apps too. Claude Desktop can also use an
[extension](integrations/claude-desktop#or-install-the-extension) with an API key.

### OpenCode, Hermes, and Codex

1. In the portal, create an API key. The key is shown only once, and so is the recovery code that comes
   with your first key: store both in a password manager.
2. Open a terminal and run the installer. Paste the key when it asks; it stays hidden as you paste. The
   installer sets up each of the three agents it finds on your computer.

   macOS, Linux, and WSL:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/membraince/membraince-code/main/install.sh | sh
   ```

   Windows (PowerShell):

   ```powershell
   irm https://raw.githubusercontent.com/membraince/membraince-code/main/install.ps1 | iex
   ```

3. Finish in your agent:
   - **OpenCode**: restart it.
   - **Hermes**: start a new session.
   - **Codex**: open Codex and sign in when it asks to connect MemBraince (if it doesn't ask, connect
     it from `/plugins`). Choose the same home project as your key's, and enter the key to unlock your
     memories. Then run `/hooks` and trust the MemBraince hooks.

### Check it works

Tell your agent "Remember that I prefer short commit messages." Start a new session and ask "How do I like
my commit messages?" The answer comes from MemBraince. If something needs fixing, such as a key MemBraince
doesn't accept or a missing subscription, your agent shows a MemBraince warning that says what.

For any other tool, see [Any MCP client](docs/mcp.md#any-mcp-client). Each tool's page, linked below, lists
its settings and exactly what it sends.

## Supported tools

| Tool | Status | What it adds |
| --- | --- | --- |
| [Claude Code](integrations/claude-code) | Available | Plugin: memory tools, automatic recall, automatic save, `memory` skill |
| [Claude Desktop](integrations/claude-desktop) | Available | Connector or extension: memory tools |
| claude.ai and the Claude apps | Available | Custom connector with OAuth sign-in ([setup](docs/mcp.md#claudeai-and-the-claude-apps)) |
| Any MCP client | Available | Memory tools over Streamable HTTP ([setup](docs/mcp.md#any-mcp-client)) |
| [OpenAI Codex](integrations/codex) | Testing | Plugin: memory tools, automatic recall, automatic save, `memory` skill |
| [OpenCode](integrations/opencode) | Testing | Plugin file and MCP server: memory tools, automatic recall, automatic save |
| [Hermes Agent](integrations/hermes) | Testing | Plugin: memory tools, automatic recall, automatic save, Learn the repository, `memory` skill |

In progress: Cursor, Gemini CLI, Qwen Code, GitHub Copilot, Windsurf, Cline, Kiro, Factory Droid, ChatGPT,
Zed, Continue, Roo Code, Goose, Amp, Augment, JetBrains, Trae, Warp, and Visual Studio.

## How it works

```
your agent ──(plugin hooks, MCP tools)──▶ https://membraince.com/v1/mcp ──▶ your memory
```

Each integration connects the agent to the [MemBraince MCP endpoint](docs/mcp.md), which offers
three tools: `recall`, `remember`, and `forget`. Where an agent supports hooks, the integration
also recalls at the start of a session and with each prompt, and saves the messages you typed
when a session ends. Every integration's page lists exactly what it sends and when, and each
automatic behavior can be turned off.

The memory engine itself runs on membraince.com and isn't part of this repository.

## Repository layout

| Path | Contents |
| --- | --- |
| `integrations/<tool>/` | One folder per tool, in that tool's native format |
| `docs/` | The MCP endpoint, authentication, projects, and OAuth |
| `install.sh`, `install.ps1` | The installer: saves your key and sets up each agent it finds |
| `scripts/` | Build helpers, such as packaging the Desktop extension |
| `.claude-plugin/marketplace.json` | Lets Claude Code install the plugin straight from this repository |
| `.agents/plugins/marketplace.json` | Lets Codex install its plugin straight from this repository |

## Contributing

Issues and pull requests are welcome, especially integrations for tools that aren't listed yet.
Keep each integration dependency-free where the tool allows it, and document what it sends.
For security reports, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). The MemBraince service is covered by its own
[terms](https://membraince.com/terms) and [privacy policy](https://membraince.com/privacy).
