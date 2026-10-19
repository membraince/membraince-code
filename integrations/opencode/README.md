# MemBraince for OpenCode

Long-term memory for [OpenCode](https://opencode.ai), backed by [MemBraince](https://membraince.com).

- **Memory tools**: `recall`, `remember`, and `forget`, from the MemBraince MCP server.
- **Recall automatically**: with each message you send, memories related to it (and, on a session's
  first message, to the project) are added to the system prompt.
- **Save automatically**: when a session goes idle, the messages you typed since the last save are
  sent as one save, at most once every 15 minutes per session, and again when a session is
  compacted. OpenCode's replies and tool output are not saved.

## Setup

1. Create an account and an API key at https://membraince.com/portal, and put it in the
   `MEMBRAINCE_API_KEY` environment variable.
2. Add the MCP server to your OpenCode config (`~/.config/opencode/opencode.json`, or
   `opencode.json` in a project):

   ```json
   {
     "$schema": "https://opencode.ai/config.json",
     "mcp": {
       "membraince": {
         "type": "remote",
         "url": "https://membraince.com/v1/mcp",
         "headers": { "X-API-Key": "{env:MEMBRAINCE_API_KEY}" },
         "oauth": false
       }
     }
   }
   ```

3. For automatic recall and save, copy [`membraince.js`](membraince.js) into
   `~/.config/opencode/plugins/` (or `.opencode/plugins/` in a project).
4. Restart OpenCode.

The plugin has no dependencies. Automatic recall uses OpenCode's
`experimental.chat.system.transform` hook, so a future OpenCode release may change how it works;
the memory tools keep working either way.

### Settings

| Variable | Meaning | Default |
| --- | --- | --- |
| `MEMBRAINCE_API_KEY` | Your API key | none; the plugin does nothing without it |
| `MEMBRAINCE_USER` | Whose memories these are inside your account | `default` |
| `MEMBRAINCE_PROJECT` | A project name from the portal to save to and recall from | the key's home project |
| `MEMBRAINCE_AUTO_RECALL` | `false` turns off automatic recall | `true` |
| `MEMBRAINCE_AUTO_SAVE` | `false` turns off automatic save | `true` |

## What the plugin sends

Everything goes to `https://membraince.com` with your API key in the `X-API-Key` header. Nothing is
sent anywhere else.

| When | Request | Contents |
| --- | --- | --- |
| A session's first message | `POST /v1/integrations/opencode/session-start` | The project folder path |
| Each message you send | `POST /v1/integrations/opencode/prompt` | The message text |
| A session goes idle or is compacted | `POST /v1/integrations/opencode/messages` | The session id, project folder path, and the text of the messages you typed |
| OpenCode calls a tool | `recall`, `remember`, or `forget` on `/v1/mcp` | What OpenCode passes to the tool |

Memories are encrypted with a key only your API keys and recovery code can unlock. See the
[privacy policy](https://membraince.com/privacy), [terms](https://membraince.com/terms), and
[support](https://membraince.com/support).
