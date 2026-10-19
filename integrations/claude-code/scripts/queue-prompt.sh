#!/usr/bin/env bash
# UserPromptSubmit: add the prompt you typed to a queue on this machine.
# save-transcript.sh sends the queue as one save later. Nothing is sent here.
[ -n "${CLAUDE_PLUGIN_OPTION_API_KEY:-}" ] || exit 0
[ "${CLAUDE_PLUGIN_OPTION_AUTO_SAVE:-true}" = "false" ] && exit 0
# JSON keeps newlines inside strings escaped, so dropping raw ones keeps it one line.
input="$(tr -d '\r\n')"
session="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr -cd 'A-Za-z0-9_-')"
[ -n "$session" ] || exit 0
data="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}"
mkdir -p "$data" || exit 0
queue="${data}/membraince-queue-${session}.jsonl"
line="{\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"hook\":${input}}"
# The queue lock is held only while a prompt is added or a save takes the
# queue, never during an upload, so it waits milliseconds at most. One that
# outlives 2 seconds of retries was left by a crash.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
  mkdir "${queue}.lock" 2>/dev/null && break
  sleep 0.05
done
mkdir "${queue}.lock" 2>/dev/null
printf '%s\n' "$line" >>"$queue"
rmdir "${queue}.lock" 2>/dev/null
exit 0
