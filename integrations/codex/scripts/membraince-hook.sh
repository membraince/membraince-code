#!/usr/bin/env bash
# MemBraince hook for Codex. Usage: membraince-hook.sh session-start|prompt|transcript
#
# session-start prints the memories MemBraince returns for the project (Codex
#   adds them to the conversation as context), then sends prompts that earlier
#   sessions queued but couldn't save.
# prompt queues the prompt you typed, as one file on this machine, then prints
#   the memories related to it.
# transcript sends this session's queued prompts as one save and deletes the
#   files it sent once the save succeeds; a failed save keeps them for later.
# Only the prompts you type are queued and sent for saving. Requests go to
# MEMBRAINCE_URL (https://membraince.com by default) with MEMBRAINCE_API_KEY.
# Any failure prints nothing and never blocks Codex.
[ -n "${MEMBRAINCE_API_KEY:-}" ] || exit 0
umask 077 # queued prompts are readable by your account only
action="${1:-}"
base="${MEMBRAINCE_URL:-https://membraince.com}"
# JSON keeps newlines inside strings escaped, so dropping raw ones keeps it one line.
input="$(tr -d '\r\n')"
field() {
  printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}
session="$(field session_id | tr -cd 'A-Za-z0-9_-')"
# Queues are kept per API key, so a leftover queue is only ever sent with the
# key that queued it. The folder name holds a hash of the key, never the key.
fingerprint="$(printf '%s' "$MEMBRAINCE_API_KEY" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)"
root="${PLUGIN_DATA:-${TMPDIR:-/tmp}}/membraince-queue-${fingerprint}"

post() { # post <route> <seconds> <content type>, body on stdin
  curl -fsS --max-time "$2" \
    -H "X-API-Key: ${MEMBRAINCE_API_KEY}" \
    -H "Content-Type: $3" \
    --data-binary @- \
    "${base}/v1/integrations/codex/$1" 2>/dev/null
}

recall() {
  [ "${MEMBRAINCE_AUTO_RECALL:-true}" = "false" ] || printf '%s' "$input" | post "$1" 8 application/json
}

queue_prompt() {
  [ -n "$session" ] && mkdir -p "${root}/${session}" || return 0
  local nanos name
  nanos="$(date +%N 2>/dev/null)"
  case "$nanos" in '' | *N*) nanos=000000000 ;; esac
  name="$(date -u +%Y%m%d%H%M%S)${nanos}-$$-${RANDOM}"
  # Written under a hidden name, then renamed: a save only ever sees whole files.
  printf '{"time":"%s","hook":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$input" >"${root}/${session}/.${name}.tmp" &&
    mv "${root}/${session}/.${name}.tmp" "${root}/${session}/${name}.json"
}

# One save per session at a time. The lock folder records its owner's process
# id; another save steps aside while that process runs. A lock is cleared only
# when its owner is gone, or after 10 minutes, far past any hook's time limit.
take_lock() {
  local lock="$1" owner stale
  if mkdir "$lock" 2>/dev/null; then
    echo "$$" >"${lock}/pid"
    return 0
  fi
  owner="$(cat "${lock}/pid" 2>/dev/null)"
  if { [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; } || [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    # Rename first, so of two saves clearing the same stale lock only one wins,
    # and check it is still the lock that was judged stale.
    stale="${lock}.stale.$$"
    mv "$lock" "$stale" 2>/dev/null || return 1
    if [ "$(cat "${stale}/pid" 2>/dev/null)" != "$owner" ]; then
      mv "$stale" "$lock" 2>/dev/null
      return 1
    fi
    rm -rf "$stale"
    mkdir "$lock" 2>/dev/null || return 1
    echo "$$" >"${lock}/pid"
    return 0
  fi
  return 1
}

release_lock() {
  [ "$(cat "${1}/pid" 2>/dev/null)" = "$$" ] && rm -rf "$1"
}

flush() { # flush <session folder> <seconds>; succeeds when nothing is left to send
  local dir="$1" files sent=1
  take_lock "${dir}.saving" || return 1
  files=("$dir"/*.json)
  if [ ! -e "${files[0]}" ]; then
    sent=0
  elif cat "${files[@]}" | post transcript "$2" application/x-ndjson >/dev/null; then
    rm -f "${files[@]}"
    sent=0
  fi
  release_lock "${dir}.saving"
  return "$sent"
}

recover() {
  # Queues from earlier sessions whose last save failed. A session folder left
  # untouched for 30 days is deleted rather than kept forever.
  local dir
  for dir in "$root"/*/; do
    dir="${dir%/}"
    [ -d "$dir" ] || continue
    case "$dir" in *.saving | *.stale.*) continue ;; esac
    [ "${dir##*/}" = "$session" ] && continue
    if [ -n "$(find "$dir" -maxdepth 0 -mtime +30 2>/dev/null)" ] && [ -z "$(find "$dir" -type f -mtime -30 2>/dev/null | head -n 1)" ]; then
      [ -d "${dir}.saving" ] || rm -rf "$dir"
      continue
    fi
    [ "$SECONDS" -lt 12 ] || break
    flush "$dir" 4
  done
  find "$root" -maxdepth 1 -name '*.saved' -mtime +1 -exec rm -f {} + 2>/dev/null
}

[ "${MEMBRAINCE_AUTO_SAVE:-true}" = "false" ] && auto_save=false || auto_save=true
case "$action" in
  session-start)
    recall session-start
    [ "$auto_save" = true ] && recover
    ;;
  prompt)
    [ "$auto_save" = true ] && queue_prompt
    recall prompt
    ;;
  transcript)
    [ "$auto_save" = true ] && [ -n "$session" ] && [ -d "${root}/${session}" ] || exit 0
    event="$(field hook_event_name)"
    stamp="${root}/${session}.saved"
    # Stop runs after every turn; save from it at most every 15 minutes per session.
    [ "$event" = "Stop" ] && [ -n "$(find "$stamp" -mmin -15 2>/dev/null)" ] && exit 0
    # Codex gives SessionEnd hooks at most 3 seconds, and taking the lock never waits.
    limit=20
    [ "$event" = "SessionEnd" ] && limit=2
    flush "${root}/${session}" "$limit" && touch "$stamp"
    ;;
esac
exit 0
