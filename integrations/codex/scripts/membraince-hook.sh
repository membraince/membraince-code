#!/usr/bin/env bash
# MemBraince hook for Codex. Usage: membraince-hook.sh session-start|prompt|transcript
#
# session-start posts the hook input and prints the memories MemBraince returns;
# Codex adds that text to the conversation as context.
# prompt adds the prompt you typed to a queue on this machine, then recalls
# memories related to it the same way.
# transcript sends the queued prompts as one save; a failed save keeps them for
# the next one. Nothing but your own prompts is ever sent for saving.
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
# queue: prompts not yet picked up by a save. pending: prompts a save has
# taken; a save that fails leaves them there for the next save.
queue="${data}/membraince-queue-${session}.jsonl"
pending="${queue}.pending"
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
# The queue lock is held only while a prompt is added or a save takes the
# queue, never during an upload, so it waits milliseconds at most. One that
# outlives 2 seconds of retries was left by a crash.
queue_lock() {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    mkdir "${queue}.lock" 2>/dev/null && return 0
    sleep 0.05
  done
  rmdir "${queue}.lock" 2>/dev/null
  mkdir "${queue}.lock" 2>/dev/null
}
queue_unlock() {
  rmdir "${queue}.lock" 2>/dev/null
}

case "$action" in
  session-start)
    recall
    ;;
  prompt)
    if [ "${MEMBRAINCE_AUTO_SAVE:-true}" != "false" ] && [ -n "$session" ] && mkdir -p "$data"; then
      line="{\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"hook\":${input}}"
      queue_lock
      printf '%s\n' "$line" >>"$queue"
      queue_unlock
    fi
    recall
    ;;
  transcript)
    [ "${MEMBRAINCE_AUTO_SAVE:-true}" = "false" ] && exit 0
    [ -n "$session" ] || exit 0
    event="$(field hook_event_name)"
    stamp="${data}/membraince-saved-${session}"
    # Stop runs after every turn; save from it at most every 15 minutes per session.
    [ "$event" = "Stop" ] && [ -n "$(find "$stamp" -mmin -15 2>/dev/null)" ] && exit 0
    # One save per session at a time: a save holding this lock is uploading right
    # now, so this one steps aside and the next save sends anything left over. A
    # lock older than 2 minutes was left by a save that died (uploads stop at 20 s).
    saving="${queue}.saving"
    find "$saving" -maxdepth 0 -mmin +2 -exec rmdir {} \; 2>/dev/null
    mkdir "$saving" 2>/dev/null || exit 0
    trap 'rmdir "$saving" 2>/dev/null' EXIT
    # Take the queue: its prompts join any a failed save left, in order.
    queue_lock
    if [ -s "$queue" ]; then
      cat "$queue" >>"$pending" && rm -f "$queue"
    fi
    queue_unlock
    [ -s "$pending" ] || exit 0
    # Codex gives SessionEnd hooks at most 3 seconds.
    limit=20
    [ "$event" = "SessionEnd" ] && limit=2
    if post "$limit" application/x-ndjson <"$pending" >/dev/null; then
      rm -f "$pending"
      touch "$stamp"
    fi
    ;;
esac
exit 0
