# The MemBraince MCP endpoint

Every integration in this repository talks to one [Model Context Protocol](https://modelcontextprotocol.io)
endpoint, `https://membraince.com/v1/mcp` (Streamable HTTP, JSON responses). It has three tools:

| Tool | What it does |
| --- | --- |
| `recall` | Searches memory and returns matching memories with their ids |
| `remember` | Saves one statement; it becomes searchable a few seconds later |
| `forget` | Deletes one memory by id |

## Authentication

MCP clients can connect in two ways:

- **Sign in in the browser.** Clients that support MCP sign-in (OAuth) need only the URL. They open a
  MemBraince sign-in page, where you choose the project the connection saves to and, if you've created
  API keys, unlock your memories once with one of them or your recovery code. The connection then
  appears in the portal as an API key; revoke it there to disconnect.
- **An API key.** Send a key from https://membraince.com/portal in the `X-API-Key` header.

Either way, calls count toward your plan and need an active subscription. Without one, the tools
answer with a message saying so.

## Optional headers

| Header | Meaning | Default |
| --- | --- | --- |
| `X-MemBraince-User` | Whose memories to use inside the account; use different values for different people or agents | `default` |
| `X-MemBraince-Project` | One project to save to and recall from, by name | The key's home project for saves, every linked project for recall |

A project is a separate memory space in your account. Every key has a home project, where its
new memories go, and can be linked to more projects it recalls from. Keys that share a project
share its memories.

## Any MCP client

Create an account at https://membraince.com/portal and subscribe. Then add a Streamable HTTP server
with the URL `https://membraince.com/v1/mcp`. If the client supports
MCP sign-in, that's all: it asks you to sign in the first time. In Claude Code without the plugin,
for example:

```bash
claude mcp add --transport http membraince https://membraince.com/v1/mcp
```

then run `/mcp`, choose membraince, and sign in.

For a client that can't sign in, send an API key instead:

```json
{
  "mcpServers": {
    "membraince": {
      "type": "http",
      "url": "https://membraince.com/v1/mcp",
      "headers": { "X-API-Key": "<your key>", "X-MemBraince-User": "default" }
    }
  }
}
```

Keep the key out of files you commit. Most clients can read it from an environment variable.

## claude.ai and the Claude apps

1. Create an account at https://membraince.com/portal and subscribe.
2. In Claude's settings, open Connectors and add a custom connector with the URL
   `https://membraince.com/v1/mcp`. Leave the OAuth fields empty.
3. Click Connect, sign in with your MemBraince account, and choose the project the connection saves to.
4. The first time, MemBraince shows a recovery code once: store it in a password manager. If the account
   already has API keys, enter one of them (or your recovery code) to unlock your memories instead.

The connection appears in the portal as an API key; revoke it there to disconnect.

The endpoint implements the MCP authorization spec: protected-resource metadata
(`/.well-known/oauth-protected-resource`), authorization-server metadata
(`/.well-known/oauth-authorization-server`), dynamic client registration (`/oauth/register`),
the authorization code grant with PKCE S256 (`/oauth/authorize`, `/oauth/token`), and rotating
refresh tokens. Access tokens last an hour.
