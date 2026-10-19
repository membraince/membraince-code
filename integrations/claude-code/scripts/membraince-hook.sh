#!/usr/bin/env bash
# MemBraince hook for Claude Code. Usage: membraince-hook.sh session-start|queue|save
#
# session-start prints the memories MemBraince returns for the project (Claude
#   Code adds them to the session as context), then sends prompts that earlier
#   sessions queued but couldn't save.
# queue keeps the prompt you typed as one file on this machine; nothing is sent.
# save sends this session's queued prompts as one save and deletes the files it
#   sent once the save succeeds; a failed save keeps them for later.
# Only the prompts you type are queued and sent for saving. Requests go to the
# plugin's Server URL setting (https://membraince.com by default) with your key.
# Any failure prints nothing and never blocks Claude Code.
key="${CLAUDE_PLUGIN_OPTION_API_KEY:-}"
[ -n "$key" ] || exit 0
umask 077 # queued prompts are readable by your account only
action="${1:-}"
user="${CLAUDE_PLUGIN_OPTION_USER_ID:-default}"
project="${CLAUDE_PLUGIN_OPTION_PROJECT:-}"
server="${CLAUDE_PLUGIN_OPTION_SERVER_URL:-https://membraince.com/v1/mcp}"
base="${server%/v1/mcp}"
# JSON keeps newlines inside strings escaped, so dropping raw ones keeps it one line.
input="$(tr -d '\r\n')"
session="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr -cd 'A-Za-z0-9_-')"
# Queues are kept per key, memory owner, and project, so a leftover queue is
# only ever sent where it was meant to go. The folder name holds a hash, never the key.
fingerprint="$(printf '%s\n%s\n%s' "$key" "$user" "$project" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)"
root="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/membraince-queue-${fingerprint}"

post() { # post <route> <seconds> <content type>, body on stdin
  curl -fsS --max-time "$2" \
    -H "X-API-Key: ${key}" \
    -H "X-MemBraince-User: ${user}" \
    -H "X-MemBraince-Project: ${project}" \
    -H "Content-Type: $3" \
    --data-binary @- \
    "${base}/v1/integrations/claude-code/$1" 2>/dev/null
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
}

[ "${CLAUDE_PLUGIN_OPTION_AUTO_SAVE:-true}" = "false" ] && auto_save=false || auto_save=true
case "$action" in
  session-start)
    [ "${CLAUDE_PLUGIN_OPTION_AUTO_RECALL:-true}" = "false" ] || printf '%s' "$input" | post session-start 8 application/json
    [ "$auto_save" = true ] && recover
    ;;
  queue)
    [ "$auto_save" = true ] && queue_prompt
    ;;
  save)
    [ "$auto_save" = true ] && [ -n "$session" ] && [ -d "${root}/${session}" ] && flush "${root}/${session}" 20
    ;;
esac
exit 0
