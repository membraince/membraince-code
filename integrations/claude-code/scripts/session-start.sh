#!/usr/bin/env bash
# SessionStart: print the memories most relevant to this project. Claude Code
# adds this hook's plain-text output to the session as context. Any failure
# prints nothing, so a down server never blocks or clutters a session.
[ -n "${CLAUDE_PLUGIN_OPTION_API_KEY:-}" ] || exit 0
[ "${CLAUDE_PLUGIN_OPTION_AUTO_RECALL:-true}" = "false" ] && exit 0
base="${CLAUDE_PLUGIN_OPTION_SERVER_URL:-https://membraince.com/v1/mcp}"
curl -fsS --max-time 8 \
  -H "X-API-Key: ${CLAUDE_PLUGIN_OPTION_API_KEY}" \
  -H "X-MemBraince-User: ${CLAUDE_PLUGIN_OPTION_USER_ID:-default}" \
  -H "X-MemBraince-Project: ${CLAUDE_PLUGIN_OPTION_PROJECT:-}" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  "${base%/v1/mcp}/v1/integrations/claude-code/session-start" 2>/dev/null || true
exit 0
