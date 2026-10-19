#!/usr/bin/env bash
# MemBraince hook for Codex. Usage: membraince-hook.sh session-start|prompt|transcript
#
# session-start and prompt post the hook input to MemBraince and print the
# memories it returns; Codex adds that text to the conversation as context.
# transcript posts the hook input plus the end of the session file, and
# MemBraince saves the messages you typed since its last save of the session.
# Needs MEMBRAINCE_API_KEY. Any failure prints nothing and never blocks Codex.
[ -n "${MEMBRAINCE_API_KEY:-}" ] || exit 0
action="${1:-}"
case "$action" in
  session-start | prompt) [ "${MEMBRAINCE_AUTO_RECALL:-true}" = "false" ] && exit 0 ;;
  transcript) [ "${MEMBRAINCE_AUTO_SAVE:-true}" = "false" ] && exit 0 ;;
  *) exit 0 ;;
esac
base="${MEMBRAINCE_URL:-https://membraince.com}"
# JSON keeps newlines inside strings escaped, so dropping raw ones keeps it one line.
input="$(tr -d '\r\n')"
post() {
  curl -fsS --max-time "$1" \
    -H "X-API-Key: ${MEMBRAINCE_API_KEY}" \
    -H "X-MemBraince-User: ${MEMBRAINCE_USER:-default}" \
    -H "X-MemBraince-Project: ${MEMBRAINCE_PROJECT:-}" \
    -H "Content-Type: $2" \
    --data-binary @- \
    "${base}/v1/integrations/codex/${action}" 2>/dev/null
}
if [ "$action" = "transcript" ]; then
  # transcript_path is a JSON string; Windows paths arrive with escaped backslashes.
  path="$(printf '%s' "$input" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's#\\#/#g')"
  [ -n "$path" ] && [ -f "$path" ] || exit 0
  { printf '%s\n' "$input"; tail -c 2000000 "$path"; } | post 3 application/x-ndjson >/dev/null
else
  printf '%s' "$input" | post 8 application/json
fi
exit 0
