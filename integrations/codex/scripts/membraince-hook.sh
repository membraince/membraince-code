#!/usr/bin/env bash
# MemBraince hook for Codex. Usage: membraince-hook.sh session-start|prompt|transcript
#
# session-start posts the hook input and prints the memories MemBraince returns;
# Codex adds that text to the conversation as context.
# prompt adds the prompt you typed to a queue on this machine, then recalls
# memories related to it the same way.
# transcript sends the queued prompts as one save and clears the queue only
# once the save succeeds. Nothing but your own prompts is ever sent for saving.
# Needs MEMBRAINCE_API_KEY. Any failure prints nothing and never blocks Codex.
[ -n "${MEMBRAINCE_API_KEY:-}" ] || exit 0
action="${1:-}"
base="${MEMBRAINCE_URL:-https://membraince.com}"
# JSON keeps newlines inside strings escaped, so dropping raw ones keeps it one line.
input="$(tr -d '\r\n')"
field() {
  printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}
session="$(field session_id | tr -cd 'A-Za-z0-9_-')"
data="${PLUGIN_DATA:-${TMPDIR:-/tmp}}"
queue="${data}/membraince-queue-${session}.jsonl"
post() {
  curl -fsS --max-time "$1" \
    -H "X-API-Key: ${MEMBRAINCE_API_KEY}" \
    -H "X-MemBraince-User: ${MEMBRAINCE_USER:-default}" \
    -H "X-MemBraince-Project: ${MEMBRAINCE_PROJECT:-}" \
    -H "Content-Type: $2" \
    --data-binary @- \
    "${base}/v1/integrations/codex/${action}" 2>/dev/null
}
recall() {
  [ "${MEMBRAINCE_AUTO_RECALL:-true}" = "false" ] || printf '%s' "$input" | post 8 application/json
}

case "$action" in
  session-start)
    recall
    ;;
  prompt)
    if [ "${MEMBRAINCE_AUTO_SAVE:-true}" != "false" ] && [ -n "$session" ]; then
      mkdir -p "$data" && printf '{"time":"%s","hook":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$input" >>"$queue"
    fi
    recall
    ;;
  transcript)
    [ "${MEMBRAINCE_AUTO_SAVE:-true}" = "false" ] && exit 0
    [ -n "$session" ] || exit 0
    sending="${queue}.sending"
    # Prompts left over from a save that didn't finish go out with this one.
    if [ -f "$sending" ]; then
      cat "$queue" >>"$sending" 2>/dev/null
      mv "$sending" "$queue"
    fi
    [ -s "$queue" ] || exit 0
    event="$(field hook_event_name)"
    stamp="${data}/membraince-saved-${session}"
    # Stop runs after every turn; save from it at most every 15 minutes per session.
    [ "$event" = "Stop" ] && [ -n "$(find "$stamp" -mmin -15 2>/dev/null)" ] && exit 0
    # Codex gives SessionEnd hooks at most 3 seconds.
    limit=20
    [ "$event" = "SessionEnd" ] && limit=2
    # Prompts typed while this save is in flight go to a fresh queue.
    mv "$queue" "$sending"
    if post "$limit" application/x-ndjson <"$sending" >/dev/null; then
      rm -f "$sending"
      touch "$stamp"
    else
      cat "$queue" >>"$sending" 2>/dev/null
      mv "$sending" "$queue"
    fi
    ;;
esac
exit 0
