#!/usr/bin/env bash
# MemBraince hook for Claude Code.
# Usage: membraince-hook.sh session-start|queue|tool|prompt|save
#
# session-start prints the memories MemBraince returns for the project, and what
#   earlier sessions in this folder learned about its code (Claude Code adds both
#   to the session as context), then sends what earlier sessions queued but
#   couldn't save.
# queue keeps the prompt you typed as one file on this machine; nothing is sent.
# tool keeps a tool call Claude made (a file it read or edited, a command and its
#   output) the same way, when "Learn the repository" is on. Files named like
#   secrets (.env, keys, credentials) are never kept.
# prompt prints what MemBraince adds for the prompt you typed: in a folder earlier
#   sessions learned, notes on the code it names (the session started with the
#   project's rules and code map); anywhere else, memories related to it.
# save sends this session's queue as one save and deletes the files it sent once
#   the save succeeds; a failed save keeps them for later.
# Requests go to the plugin's Server URL setting (https://membraince.com by
# default) with your key. A failure never blocks Claude Code. When MemBraince
# refuses the key (no subscription, a limit reached, ...), session start tells
# you why in one line, at most once a day; Claude never sees it.
key="${CLAUDE_PLUGIN_OPTION_API_KEY:-}"
[ -n "$key" ] || exit 0
umask 077 # queued prompts are readable by your account only
action="${1:-}"
user="${CLAUDE_PLUGIN_OPTION_USER_ID:-default}"
project="${CLAUDE_PLUGIN_OPTION_PROJECT:-}"
server="${CLAUDE_PLUGIN_OPTION_SERVER_URL:-https://membraince.com/v1/mcp}"
server="${server%/}"
base="${server%/v1/mcp}"
# JSON keeps newlines inside strings escaped, so dropping raw ones keeps it one line.
input="$(tr -d '\r\n')"
session="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr -cd 'A-Za-z0-9_-')"
# Queues are kept per key, memory owner, project, and server, so a leftover
# queue is only ever sent where it was meant to go. The folder name holds a
# hash, never the key.
fingerprint="$(printf '%s\n%s\n%s\n%s' "$key" "$user" "$project" "$base" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)"
root="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/membraince-queue-${fingerprint}"

post() { # post <route> <seconds> <content type>, body on stdin; sets answer and status
  local out sent
  answer=""
  out="$(curl -sS --max-time "$2" \
    -H "X-API-Key: ${key}" \
    -H "X-MemBraince-User: ${user}" \
    -H "X-MemBraince-Project: ${project}" \
    -H "Content-Type: $3" \
    --data-binary @- \
    -w '\n%{http_code}' \
    "${base}/v1/integrations/claude-code/$1" 2>/dev/null)"
  sent=$?
  status="${out##*$'\n'}"
  [ "$sent" = 0 ] || return 1
  case "$status" in 2??) answer="${out%$'\n'*}" ;; *) return 1 ;; esac
}

# MemBraince's refusal in one line for you, as a warning Claude Code shows and
# Claude never sees. The same problem is told at most once a day.
notice() {
  local message mark="${root}/notice-${status}"
  case "$status" in
    401) message="MemBraince didn't accept your API key, so memory is off. Check it in /plugin \\u2192 MemBraince, or create a new one at https://membraince.com/portal." ;;
    402) message="MemBraince memory is off until you subscribe at https://membraince.com/portal. What you type stays queued on this computer for up to 30 days and is saved once you do." ;;
    403) message="MemBraince doesn't know the project set in /plugin \\u2192 MemBraince for this key. Use a project name from https://membraince.com/portal, or leave it empty." ;;
    423) message="This API key can't unlock your encrypted MemBraince memories. Create a new key at https://membraince.com/portal and put it in /plugin \\u2192 MemBraince." ;;
    429) message="This API key has reached a MemBraince limit, so memory is paused. Usage is on https://membraince.com/portal; what you type stays queued and is saved later." ;;
    *) return 0 ;;
  esac
  [ -n "$(find "$mark" -mmin -1440 2>/dev/null)" ] && return 0
  ensure_root && : >"$mark"
  printf '{"systemMessage":"%s"}\n' "$message"
}

ensure_root() {
  [ -d "$root" ] && return 0
  mkdir -p "$root" || return 1
  # On Windows umask has no effect, so limit the folder to this account.
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) icacls "$(cygpath -w "$root")" /inheritance:r /grant:r "${USERNAME}:(OI)(CI)F" >/dev/null 2>&1 ;;
  esac
}

queue_prompt() {
  [ -n "$session" ] && ensure_root && mkdir -p "${root}/${session}" || return 0
  local nanos name
  nanos="$(date +%N 2>/dev/null)"
  case "$nanos" in '' | *N*) nanos=000000000 ;; esac
  name="$(date -u +%Y%m%d%H%M%S)${nanos}-$$-${RANDOM}"
  # Written under a hidden name, then renamed: a save only ever sees whole files.
  # Each line carries its own id, so a save resent after a lost response sends
  # the same ids and the server stores each prompt once.
  printf '{"id":"%s","time":"%s","hook":%s}\n' "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$input" >"${root}/${session}/.${name}.tmp" &&
    mv "${root}/${session}/.${name}.tmp" "${root}/${session}/${name}.json"
}

# One save per session at a time. The lock folder holds one file, named after
# its owner's process id; another save steps aside while that process runs. A
# lock changes hands only when its owner is gone, or after 10 minutes, far
# past any hook's time limit.
take_lock() {
  local lock="$1" owner
  if mkdir "$lock" 2>/dev/null; then
    : >"${lock}/$$"
    return
  fi
  owner="$(ls "$lock" 2>/dev/null | head -n 1)"
  if [ -z "$owner" ] || kill -0 "$owner" 2>/dev/null; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] || return 1
  fi
  # Ten minutes old with no owner's file: its save died. The next save takes it.
  [ -n "$owner" ] || { rmdir "$lock" 2>/dev/null; return 1; }
  # Taking a stale lock is one rename of its owner's file: of two saves only
  # one wins, and it fails if the lock has changed hands since. The folder
  # stays in place throughout, so no other save can take the lock meanwhile.
  mv "${lock}/${owner}" "${lock}/$$" 2>/dev/null
}

release_lock() {
  rm "${1}/$$" 2>/dev/null && rmdir "$1" 2>/dev/null
}

flush() { # flush <session folder> <seconds>; succeeds when nothing is left to send
  local dir="$1" files body sent=1
  take_lock "${dir}.saving" || return 1
  files=("$dir"/*.json)
  body="${dir}.body.$$"
  # The upload is read from one file built first, so a failed read never
  # passes for a sent save and deletes prompts that weren't sent.
  if [ ! -e "${files[0]}" ]; then
    sent=0
  elif cat "${files[@]}" >"$body" && post transcript "$2" application/x-ndjson <"$body"; then
    rm -f "${files[@]}"
    sent=0
  fi
  rm -f "$body"
  release_lock "${dir}.saving"
  return "$sent"
}

recover() {
  # Queues from earlier sessions whose last save failed. A session folder left
  # untouched for 30 days is deleted rather than kept forever.
  local dir left
  for dir in "$root"/*/; do
    dir="${dir%/}"
    [ -d "$dir" ] || continue
    case "$dir" in *.saving | *.stale.*) continue ;; esac
    [ "${dir##*/}" = "$session" ] && continue
    if [ -n "$(find "$dir" -maxdepth 0 -mtime +30 2>/dev/null)" ] && [ -z "$(find "$dir" -type f -mtime -30 2>/dev/null | head -n 1)" ]; then
      [ -d "${dir}.saving" ] || rm -rf "$dir"
      continue
    fi
    # One deadline for the whole hook: recall and recovery finish within 15
    # seconds, well inside the hook's 20-second limit.
    left=$((15 - SECONDS))
    [ "$left" -ge 2 ] || break
    flush "$dir" "$((left < 4 ? left : 4))"
  done
}

# A tool call is kept unless the file or command it names looks like a secret.
secret_name='(^|[/\\[:space:]=])(\.env(\.[[:alnum:]_-]+)?|[^/\\[:space:]]+\.(pem|key|p12|pfx|jks|keystore)|id_(rsa|dsa|ecdsa|ed25519)[^/\\[:space:]]*|\.netrc|\.npmrc|\.pypirc|\.git-credentials|credentials(\.[[:alnum:]]+)?|secrets?(\.[[:alnum:]]+)?)($|[[:space:]"'"'"';|&)])'
names_secret() {
  printf '%s' "$input" |
    sed -nE 's/.*"(file_path|notebook_path|command)"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\2/p' |
    grep -Eq "$secret_name"
}

[ "${CLAUDE_PLUGIN_OPTION_AUTO_SAVE:-true}" = "false" ] && auto_save=false || auto_save=true
[ "${CLAUDE_PLUGIN_OPTION_AUTO_RECALL:-true}" = "false" ] && auto_recall=false || auto_recall=true
[ "${CLAUDE_PLUGIN_OPTION_LEARN_CODE:-true}" = "false" ] && learn_code=false || learn_code=true
status=""
case "$action" in
  session-start)
    context=""
    if [ "$auto_recall" = true ] && post session-start 8 application/json < <(printf '%s' "$input"); then
      context="$answer"
      printf '%s' "$context"
    fi
    [ "$auto_save" = true ] && recover
    # Claude Code reads the output either as context or as one JSON object, never both.
    [ -n "$context" ] || notice
    ;;
  queue)
    [ "$auto_save" = true ] && queue_prompt
    ;;
  tool)
    [ "$auto_save" = true ] && [ "$learn_code" = true ] && ! names_secret && queue_prompt
    ;;
  prompt)
    [ "$auto_recall" = true ] && post prompt 8 application/json < <(printf '%s' "$input") && printf '%s' "$answer"
    ;;
  save)
    [ "$auto_save" = true ] && [ -n "$session" ] && [ -d "${root}/${session}" ] && flush "${root}/${session}" 20
    ;;
esac
exit 0
