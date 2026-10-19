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

## Supported tools

| Tool | Status | What it adds |
| --- | --- | --- |
| [Claude Code](integrations/claude-code) | Available | Plugin: memory tools, automatic recall, automatic save, `memory` skill |
| [Claude Desktop](integrations/claude-desktop) | Available | Extension: memory tools |
| claude.ai and the Claude apps | Available | Custom connector with OAuth sign-in ([setup](docs/mcp.md#claudeai-and-the-claude-apps)) |
| Any MCP client | Available | Memory tools over Streamable HTTP ([setup](docs/mcp.md#any-mcp-client)) |
| [OpenAI Codex](integrations/codex) | Testing | Plugin: memory tools, automatic recall, automatic save, `memory` skill |
| [OpenCode](integrations/opencode) | Testing | Plugin file and MCP server: memory tools, automatic recall, automatic save |
| Cursor, Gemini CLI, Qwen Code, GitHub Copilot, Windsurf, Cline, Kiro, Factory Droid | In progress | Native integrations with automatic recall and save |
| ChatGPT, Zed, Continue, Roo Code, Goose, Amp, Augment, JetBrains, Trae, Warp, Visual Studio | In progress | Memory tools plus instructions for when to use them |

## Get started

1. Create an account and an API key at https://membraince.com/portal.
2. Pick your tool in the table above and follow its page.

Claude Code, for example:

```
/plugin marketplace add membraince/membraince-code
/plugin install membraince@membraince
```

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
