#!/usr/bin/env bash
# PreCompact and SessionEnd: send the messages you typed near the end of this
# session's transcript, and MemBraince saves the ones since its last save of the
# session (one save per run, de-duplicated by message). Failures are silent and never block Claude Code.
[ -n "${CLAUDE_PLUGIN_OPTION_API_KEY:-}" ] || exit 0
[ "${CLAUDE_PLUGIN_OPTION_AUTO_SAVE:-true}" = "false" ] && exit 0
input="$(cat)"
# transcript_path is a JSON string; Windows paths arrive with escaped backslashes.
path="$(printf '%s' "$input" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr -s '\\\\' '/')"
[ -n "$path" ] && [ -f "$path" ] || exit 0
base="${CLAUDE_PLUGIN_OPTION_SERVER_URL:-https://membraince.com/v1/mcp}"
# Only the lines holding your own messages leave this machine: Claude's replies
# and tool results are filtered out here, before anything is sent.
tail -c 2000000 "$path" | grep -F '"type":"user"' | grep -vF '"tool_use_id"' | curl -fsS --max-time 20 \
  -H "X-API-Key: ${CLAUDE_PLUGIN_OPTION_API_KEY}" \
  -H "X-MemBraince-User: ${CLAUDE_PLUGIN_OPTION_USER_ID:-default}" \
  -H "X-MemBraince-Project: ${CLAUDE_PLUGIN_OPTION_PROJECT:-}" \
  -H "Content-Type: application/x-ndjson" \
  --data-binary @- \
  "${base%/v1/mcp}/v1/integrations/claude-code/transcript" >/dev/null 2>&1 || true
exit 0
