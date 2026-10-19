#!/usr/bin/env bash
# PreCompact and SessionEnd: send the prompts queued by queue-prompt.sh as one
# save, and clear the queue only once the save succeeds. Nothing but the
# prompts you typed is ever sent. Failures are silent and never block Claude Code.
[ -n "${CLAUDE_PLUGIN_OPTION_API_KEY:-}" ] || exit 0
[ "${CLAUDE_PLUGIN_OPTION_AUTO_SAVE:-true}" = "false" ] && exit 0
session="$(tr -d '\r\n' | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr -cd 'A-Za-z0-9_-')"
[ -n "$session" ] || exit 0
queue="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/membraince-queue-${session}.jsonl"
sending="${queue}.sending"
# One save per session at a time: a save holding the lock is uploading right
# now, so this one steps aside and the next save sends anything left over. A
# lock older than 2 minutes was left by a save that died (uploads stop at 20 s).
lock="${queue}.lock"
find "$lock" -maxdepth 0 -mmin +2 -exec rmdir {} \; 2>/dev/null
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock" 2>/dev/null' EXIT
# Prompts left over from a save that didn't finish go out with this one.
if [ -f "$sending" ]; then
  cat "$queue" >>"$sending" 2>/dev/null
  mv "$sending" "$queue"
fi
[ -s "$queue" ] || exit 0
# Prompts typed while this save is in flight go to a fresh queue.
mv "$queue" "$sending"
base="${CLAUDE_PLUGIN_OPTION_SERVER_URL:-https://membraince.com/v1/mcp}"
if curl -fsS --max-time 20 \
  -H "X-API-Key: ${CLAUDE_PLUGIN_OPTION_API_KEY}" \
  -H "X-MemBraince-User: ${CLAUDE_PLUGIN_OPTION_USER_ID:-default}" \
  -H "X-MemBraince-Project: ${CLAUDE_PLUGIN_OPTION_PROJECT:-}" \
  -H "Content-Type: application/x-ndjson" \
  --data-binary @"$sending" \
  "${base%/v1/mcp}/v1/integrations/claude-code/transcript" >/dev/null 2>&1; then
  rm -f "$sending"
else
  cat "$queue" >>"$sending" 2>/dev/null
  mv "$sending" "$queue"
fi
exit 0
