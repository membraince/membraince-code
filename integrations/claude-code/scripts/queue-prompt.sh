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
mkdir -p "$data" && printf '{"time":"%s","hook":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$input" >>"${data}/membraince-queue-${session}.jsonl"
exit 0
