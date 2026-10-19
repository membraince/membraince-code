#!/usr/bin/env bash
# Tests for the bash hook scripts of the Claude Code and Codex integrations,
# against tests/fake_server.py. Run from the repository root: bash tests/hooks.sh
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
py="$(command -v python3 || command -v python)"
"$py" "$repo/tests/fake_server.py" "$work" 2>"$work/server.log" &
server=$!
trap 'kill "$server" 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 1 300); do [ -s "$work/port" ] && break; sleep 0.1; done
if [ ! -s "$work/port" ]; then
  echo "the fake server didn't start:" >&2
  cat "$work/server.log" >&2
  exit 1
fi
port="$(cat "$work/port")"
failures=0

check() { # check <description> <shell condition>
  if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; failures=$((failures + 1)); fi
}

# Each agent's hook script, with its own action names and settings.
use_agent() {
  agent="$1"
  data="$work/$agent-data"
  rm -rf "$data" "$work/uploaded.txt" "$work/fail"
  : >"$work/uploaded.txt"
  if [ "$agent" = codex ]; then
    script="$repo/integrations/codex/scripts/membraince-hook.sh"
    queue_action=prompt save_action=transcript
  else
    script="$repo/integrations/claude-code/scripts/membraince-hook.sh"
    queue_action=queue save_action=save
  fi
}
run() { # run <action> <key> <json input>
  printf '%s' "$3" | MEMBRAINCE_API_KEY="$2" MEMBRAINCE_URL="http://127.0.0.1:${port}" PLUGIN_DATA="$data" \
    CLAUDE_PLUGIN_OPTION_API_KEY="$2" CLAUDE_PLUGIN_OPTION_SERVER_URL="http://127.0.0.1:${port}/v1/mcp" \
    CLAUDE_PLUGIN_DATA="$data" bash "$script" "$1"
}
prompt() { run "$queue_action" "${3:-key-a}" "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$1\",\"cwd\":\"/w/app\",\"prompt\":\"$2\"}"; }
save() { run "$save_action" "${2:-key-a}" "{\"hook_event_name\":\"${3:-PreCompact}\",\"session_id\":\"$1\"}"; }
start() { run session-start "${2:-key-a}" "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$1\",\"cwd\":\"/w/app\"}"; }
uploaded() { tr -d '\r' <"$work/uploaded.txt"; }
queued() { find "$data" -name '*.json' -type f | wc -l | tr -d ' '; }

for agent in codex claude-code; do
  echo "== $agent"
  use_agent "$agent"

  prompt s1 "first prompt" >/dev/null
  check "a prompt is queued as one file" '[ "$(queued)" = 1 ]'
  touch "$work/fail"
  save s1
  check "a failed save keeps the queue" '[ "$(queued)" = 1 ]'
  rm -f "$work/fail"
  save s1
  check "a successful save sends it and empties the queue" '[ "$(uploaded)" = "key-a first prompt" ] && [ "$(queued)" = 0 ]'

  # A lock held by a running process is respected; one left by a dead process is cleared.
  prompt s2 "behind a live lock" >/dev/null
  lock="$(find "$data" -maxdepth 1 -type d -name 'membraince-queue-*')/s2.saving"
  mkdir "$lock" && echo "$$" >"$lock/pid"
  save s2
  check "a save steps aside while the lock's owner runs" '[ "$(queued)" = 1 ]'
  sh -c 'exit 0' & dead=$!
  wait "$dead"
  echo "$dead" >"$lock/pid"
  save s2
  check "a lock whose owner is gone is cleared" '[ "$(queued)" = 0 ] && uploaded | grep -q "behind a live lock"'

  # Prompts a failed final save left behind go out when a later session starts,
  # but only with the key that queued them.
  : >"$work/uploaded.txt"
  prompt s3 "stranded with key a" >/dev/null
  prompt s4 "stranded with key b" key-b >/dev/null
  touch "$work/fail"
  save s3 key-a SessionEnd
  rm -f "$work/fail"
  start s5 key-a >/dev/null
  check "a new session sends an earlier session's stranded queue" '[ "$(uploaded)" = "key-a stranded with key a" ]'
  check "a queue made with another key is left alone" '[ "$(queued)" = 1 ]'

  # A session folder untouched for 30 days is deleted.
  old="$(find "$data" -maxdepth 2 -type d -name s4)"
  # Python sets the dates the same way on Linux, macOS, and Windows.
  "$py" -c 'import os, sys, time; t = time.time() - 40 * 86400; [os.utime(p, (t, t)) for p in sys.argv[1:]]' "$old"/*.json "$old"
  start s6 key-b >/dev/null
  check "a 30-day-old queue is deleted, not sent" '[ ! -d "$old" ] && ! uploaded | grep -q "key b"'

  case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) windows=true ;; *) windows=false ;; esac
  if [ "$windows" = false ]; then
    prompt s7 "private" >/dev/null
    file="$(find "$data" -name '*.json' -type f | head -n 1)"
    check "queued prompts are readable by their owner only" '[ "$("$py" -c "import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$file")" = 0o600 ]'
    save s7
  fi

  # 60 prompts arrive while saves overlap and, for a while, all fail.
  : >"$work/uploaded.txt"
  pids=()
  for i in $(seq -w 1 60); do
    [ "$i" = 15 ] && touch "$work/fail"
    [ "$i" = 35 ] && rm -f "$work/fail"
    prompt s8 "stress $i" >/dev/null &
    pids+=($!)
    if [ $((10#$i % 3)) = 0 ]; then save s8 & pids+=($!); fi
    if [ $((10#$i % 7)) = 0 ]; then save s8 & pids+=($!); fi
    sleep 0.03
  done
  wait "${pids[@]}"
  for _ in 1 2 3 4 5; do save s8; done
  check "under load, every prompt is sent exactly once" '[ "$(uploaded | sort -u | wc -l)" -eq 60 ] && [ "$(uploaded | wc -l)" -eq 60 ]'
  check "nothing is left queued" '[ "$(queued)" = 0 ]'
done

echo
[ "$failures" = 0 ] && echo "all hook tests passed" || echo "$failures hook test(s) failed"
exit "$failures"
