# The MemBraince MCP endpoint

Every integration in this repository talks to one [Model Context Protocol](https://modelcontextprotocol.io)
endpoint, `https://membraince.com/v1/mcp` (Streamable HTTP, JSON responses). It has three tools:

| Tool | What it does |
| --- | --- |
| `recall` | Searches memory and returns matching memories with their ids |
| `remember` | Saves one statement; it becomes searchable a few seconds later |
| `forget` | Deletes one memory by id |

## Authentication

Send an API key from https://membraince.com/portal in the `X-API-Key` header. The key decides
the account, and calls count toward the same plan and quotas as the REST API.

Clients that can't set headers can sign in with OAuth instead (see
[claude.ai and the Claude apps](#claudeai-and-the-claude-apps)).

## Optional headers

| Header | Meaning | Default |
| --- | --- | --- |
| `X-MemBraince-User` | Whose memories to use inside the account; use different values for different people or agents | `default` |
| `X-MemBraince-Project` | One project to save to and recall from, by name | The key's home project for saves, every linked project for recall |

A project is a separate memory space in your account. Every key has a home project, where its
new memories go, and can be linked to more projects it recalls from. Keys that share a project
share its memories.

## Any MCP client

Point a client that supports Streamable HTTP with custom headers at the endpoint. A typical
configuration:

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

Add a custom connector (Settings, Connectors) with the URL `https://membraince.com/v1/mcp` and
leave the OAuth fields empty. Claude registers itself, you sign in with your MemBraince account,
choose the project the connection saves to and, if your memories are encrypted, enter an API key
or your recovery code once to unlock them. The connection appears in the portal as an API key;
revoke it there to disconnect.

The endpoint implements the MCP authorization spec: protected-resource metadata
(`/.well-known/oauth-protected-resource`), authorization-server metadata
(`/.well-known/oauth-authorization-server`), dynamic client registration (`/oauth/register`),
the authorization code grant with PKCE S256 (`/oauth/authorize`, `/oauth/token`), and rotating
refresh tokens. Access tokens last an hour.
