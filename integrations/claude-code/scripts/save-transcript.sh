#!/usr/bin/env bash
# PreCompact and SessionEnd: send the prompts queued by queue-prompt.sh as one
# save; a failed save keeps them for the next one. Nothing but the prompts you
# typed is ever sent. Failures are silent and never block Claude Code.
[ -n "${CLAUDE_PLUGIN_OPTION_API_KEY:-}" ] || exit 0
[ "${CLAUDE_PLUGIN_OPTION_AUTO_SAVE:-true}" = "false" ] && exit 0
session="$(tr -d '\r\n' | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr -cd 'A-Za-z0-9_-')"
[ -n "$session" ] || exit 0
# queue: prompts not yet picked up by a save. pending: prompts a save has
# taken; a save that fails leaves them there for the next save.
queue="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/membraince-queue-${session}.jsonl"
pending="${queue}.pending"
# One save per session at a time: a save holding this lock is uploading right
# now, so this one steps aside and the next save sends anything left over. A
# lock older than 2 minutes was left by a save that died (uploads stop at 20 s).
saving="${queue}.saving"
find "$saving" -maxdepth 0 -mmin +2 -exec rmdir {} \; 2>/dev/null
mkdir "$saving" 2>/dev/null || exit 0
trap 'rmdir "$saving" 2>/dev/null' EXIT
# Take the queue under the brief queue lock (see queue-prompt.sh): its prompts
# join any a failed save left, in order.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
  mkdir "${queue}.lock" 2>/dev/null && break
  sleep 0.05
done
mkdir "${queue}.lock" 2>/dev/null
if [ -s "$queue" ]; then
  cat "$queue" >>"$pending" && rm -f "$queue"
fi
rmdir "${queue}.lock" 2>/dev/null
[ -s "$pending" ] || exit 0
base="${CLAUDE_PLUGIN_OPTION_SERVER_URL:-https://membraince.com/v1/mcp}"
curl -fsS --max-time 20 \
  -H "X-API-Key: ${CLAUDE_PLUGIN_OPTION_API_KEY}" \
  -H "X-MemBraince-User: ${CLAUDE_PLUGIN_OPTION_USER_ID:-default}" \
  -H "X-MemBraince-Project: ${CLAUDE_PLUGIN_OPTION_PROJECT:-}" \
  -H "Content-Type: application/x-ndjson" \
  --data-binary @"$pending" \
  "${base%/v1/mcp}/v1/integrations/claude-code/transcript" >/dev/null 2>&1 && rm -f "$pending"
exit 0
