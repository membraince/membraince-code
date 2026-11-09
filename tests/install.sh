#!/usr/bin/env bash
# Tests for install.sh against tests/fake_server.py, with a throwaway home folder
# and stand-ins for the `hermes` and `codex` commands that record how they were
# called. Run from the repository root: bash tests/install.sh
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
source_url="file://${repo}"
command -v cygpath >/dev/null 2>&1 && source_url="file:///$(cygpath -m "$repo")"

check() { # check <description> <shell condition>
  if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; failures=$((failures + 1)); fi
}

bin="$work/bin"
mkdir -p "$bin"
for name in hermes codex; do
  cat >"$bin/$name" <<EOF
#!/bin/sh
echo "$name \$*" >>"$work/calls.txt"
[ "\$1 \$2" = "config env-path" ] && echo "\$FAKE_HERMES_ENV"
[ -f "$work/$name-fails" ] && [ "\$2" != env-path ] && exit 1
exit 0
EOF
  chmod +x "$bin/$name"
done

# setup <home> [VAR=value ...]: runs the installer with no terminal and prints what it says.
setup() {
  local home="$1"
  shift
  env -u MEMBRAINCE_API_KEY -u XDG_CONFIG_HOME HOME="$home" PATH="$bin:$PATH" FAKE_HERMES_ENV="$home/.hermes/.env" \
    MEMBRAINCE_URL="http://127.0.0.1:${port}" MEMBRAINCE_SOURCE="$source_url" "$@" sh "$repo/install.sh" </dev/null 2>&1
}
calls() { grep -c -- "$1" "$work/calls.txt" 2>/dev/null; }

echo "== install.sh"
home="$work/home"
mkdir -p "$home/.config/opencode" "$home/.hermes"
printf 'OTHER=1\nMEMBRAINCE_API_KEY=old\n' >"$home/.hermes/.env"
said="$(setup "$home" MEMBRAINCE_API_KEY=key-a)"
check "the key is checked with MemBraince before it's saved" '[ "$(grep -c session-start "$work/routes.txt")" = 1 ] && grep -q "\"X-API-Key\": \"key-a\"" "$work/requests.jsonl"'
check "the key is saved in ~/.config/membraince/api-key" '[ "$(cat "$home/.config/membraince/api-key")" = key-a ]'
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) ;;
  *) check "the key file is readable by its owner only" '[ "$("$py" -c "import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$home/.config/membraince/api-key")" = 0o600 ]' ;;
esac
check "OpenCode gets the plugin file in its plugins folder" 'cmp -s "$home/.config/opencode/plugins/membraince.js" "$repo/integrations/opencode/membraince.js"'
check "Hermes's .env gets the key once and keeps its other lines" '[ "$(cat "$home/.hermes/.env")" = "$(printf "OTHER=1\nMEMBRAINCE_API_KEY=key-a")" ]'
check "Hermes installs the plugin without questions and makes it the memory provider" '[ "$(calls "hermes plugins install membraince/membraince-code/integrations/hermes --force --enable")" = 1 ] && [ "$(calls "hermes config set memory.provider membraince")" = 1 ]'
check "Codex adds the marketplace and the plugin" '[ "$(calls "codex plugin marketplace add membraince/membraince-code")" = 1 ] && [ "$(calls "codex plugin add membraince@membraince")" = 1 ]'
check "each agent found gets its own line" 'case "$said" in *"OpenCode: MemBraince added."*"Hermes: MemBraince is now your memory provider."*"Codex: MemBraince added."*) true ;; *) false ;; esac'
check "the key itself is never printed" 'case "$said" in *key-a*) false ;; *) true ;; esac'

mkdir -p "$home/.config/opencode/plugin"
echo old >"$home/.config/opencode/plugin/membraince.js"
rm -f "$home/.config/opencode/plugins/membraince.js" "$work/routes.txt"
said="$(setup "$home")"
check "run again with no key given, it uses the saved one" 'case "$said" in *"Using the key already saved"*) true ;; *) false ;; esac && [ "$(cat "$home/.config/membraince/api-key")" = key-a ]'
check "a plugin file in OpenCode's older plugin folder is updated where it is" 'cmp -s "$home/.config/opencode/plugin/membraince.js" "$repo/integrations/opencode/membraince.js" && [ ! -e "$home/.config/opencode/plugins/membraince.js" ]'

touch "$work/hermes-fails" "$work/codex-fails"
said="$(setup "$home")"
check "an agent's failing command is reported and the others still run" 'case "$said" in *"OpenCode: MemBraince added."*"Hermes: setup didn'"'"'t finish."*"Codex: couldn'"'"'t add the plugin."*) true ;; *) false ;; esac'
rm -f "$work/hermes-fails" "$work/codex-fails"

fresh="$work/fresh"
mkdir -p "$fresh/.config/opencode"
echo 401 >"$work/status"
said="$(setup "$fresh" MEMBRAINCE_API_KEY=key-bad)"
check "a key MemBraince doesn't accept is not saved, and nothing is installed" '[ $? != 0 ] && [ ! -e "$fresh/.config/membraince/api-key" ] && [ ! -e "$fresh/.config/opencode/plugins/membraince.js" ]'
echo 423 >"$work/status"
said="$(setup "$fresh" MEMBRAINCE_API_KEY=key-locked)"
check "a key that can't unlock the memories is not saved" 'case "$said" in *"can'"'"'t unlock"*) true ;; *) false ;; esac && [ ! -e "$fresh/.config/membraince/api-key" ]'
echo 402 >"$work/status"
said="$(setup "$fresh" MEMBRAINCE_API_KEY=key-b)"
check "with no subscription the key is saved and the installer says memory is off" 'case "$said" in *"no subscription yet"*"Key saved"*) true ;; *) false ;; esac && [ "$(cat "$fresh/.config/membraince/api-key")" = key-b ]'
rm -f "$work/status"
said="$(setup "$fresh" MEMBRAINCE_API_KEY=key-c MEMBRAINCE_URL=http://127.0.0.1:1)"
check "when MemBraince can't be reached the key is saved unchecked" 'case "$said" in *"saved unchecked"*) true ;; *) false ;; esac && [ "$(cat "$fresh/.config/membraince/api-key")" = key-c ]'
said="$(setup "$work/empty" MEMBRAINCE_API_KEY="bad key!")"
check "something that isn't a key is refused without asking MemBraince" 'case "$said" in *"doesn'"'"'t look like a MemBraince API key"*) true ;; *) false ;; esac && [ ! -e "$work/empty/.config/membraince/api-key" ]'
echo
[ "$failures" = 0 ] && echo "all install tests passed" || echo "$failures install test(s) failed"
exit "$failures"
