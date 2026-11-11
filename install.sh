#!/bin/sh
# MemBraince setup for macOS, Linux, and WSL. Saves your API key once and adds
# MemBraince to each coding agent it finds on this computer:
#
#   curl -fsSL https://raw.githubusercontent.com/membraince/membraince-code/main/install.sh | sh
#
# Run it again to change the key or to update the integrations. It needs curl.
#
# What it does, and nothing else:
#   - asks for your API key (or takes MEMBRAINCE_API_KEY), checks it with
#     MemBraince, and saves it in ~/.config/membraince/api-key, readable by your
#     account only;
#   - OpenCode: puts membraince.js in OpenCode's plugins folder;
#   - Hermes: puts the key in Hermes's .env file, installs the plugin with
#     `hermes plugins install`, and makes MemBraince the memory provider;
#   - Codex: installs the plugin with `codex plugin add`.

BASE="${MEMBRAINCE_URL:-https://membraince.com}"
BASE="${BASE%/}"
SOURCE="${MEMBRAINCE_SOURCE:-https://raw.githubusercontent.com/membraince/membraince-code/main}"
PORTAL="https://membraince.com/portal"
REPO="https://github.com/membraince/membraince-code"
key_file="${HOME}/.config/membraince/api-key"
found=0
umask 077
log="$(mktemp 2>/dev/null)" || log="${TMPDIR:-/tmp}/membraince-setup-$$.log"

say() { printf '%s\n' "$*"; }
stop() {
  say "$*" >&2
  exit 1
}
trap '{ stty echo </dev/tty; } 2>/dev/null; rm -f "$log"' EXIT
# Some shells skip the line above when Ctrl-C stops them, which would leave
# the terminal hiding what you type.
trap 'exit 130' INT TERM HUP

command -v curl >/dev/null 2>&1 || stop "MemBraince setup needs curl. Install it and run this again."

# The answer MemBraince gives this key, as an HTTP status (000 when it can't be
# reached). The key goes to curl on standard input, never on a command line.
check_key() {
  printf 'header = "X-API-Key: %s"\n' "$1" |
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 --config - \
      -X POST -H 'Content-Type: application/json' -d '{"cwd":""}' \
      "${BASE}/v1/integrations/opencode/session-start" 2>/dev/null
}

ask_key() {
  (: </dev/tty) 2>/dev/null || stop "No API key to use. Set MEMBRAINCE_API_KEY to a key from ${PORTAL} and run this again."
  printf 'Paste your MemBraince API key (create one at %s). It stays hidden: ' "$PORTAL" >/dev/tty
  stty -echo </dev/tty 2>/dev/null
  IFS= read -r key </dev/tty
  stty echo </dev/tty 2>/dev/null
  printf '\n' >/dev/tty
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
}

say "MemBraince setup"
key="$(printf '%s' "${MEMBRAINCE_API_KEY:-}" | tr -d '[:space:]')"
if [ -z "$key" ] && [ -f "$key_file" ]; then
  key="$(tr -d '[:space:]' <"$key_file" 2>/dev/null)"
  [ -n "$key" ] && say "Using the key already saved in ~/.config/membraince/api-key."
fi
tries=0
while :; do
  [ -z "$key" ] && ask_key
  case "$key" in
    "" | *[!A-Za-z0-9._-]*)
      say "That doesn't look like a MemBraince API key."
      key=""
      ;;
    *)
      status="$(check_key "$key")"
      case "$status" in
        401)
          say "MemBraince didn't accept that key."
          key=""
          ;;
        423) stop "That key can't unlock your encrypted MemBraince memories. Create a new key at ${PORTAL} and run this again." ;;
        *) break ;;
      esac
      ;;
  esac
  tries=$((tries + 1))
  [ "$tries" -ge 3 ] && stop "Create a key at ${PORTAL} and run this again."
done
case "$status" in
  200) ;;
  402) say "This account has no subscription yet, so memory stays off until you subscribe at ${PORTAL}." ;;
  403 | 429) ;; # the key is good; the agents say what's wrong when it matters
  *) say "Couldn't reach MemBraince to check the key, so it's saved unchecked." ;;
esac

mkdir -p "${HOME}/.config/membraince" || stop "Couldn't create ~/.config/membraince."
printf '%s' "$key" >"${key_file}.new" && mv -f "${key_file}.new" "$key_file" || stop "Couldn't save the key in ~/.config/membraince/api-key."
chmod 600 "$key_file" 2>/dev/null
say "Key saved in ~/.config/membraince/api-key."

# OpenCode loads every file in its plugins folder; the plugin reads the saved
# key and adds the memory tools itself, so opencode.json stays untouched.
opencode_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
if [ -d "$opencode_dir" ] || command -v opencode >/dev/null 2>&1; then
  found=1
  target="${opencode_dir}/plugins/membraince.js"
  [ -f "${opencode_dir}/plugin/membraince.js" ] && target="${opencode_dir}/plugin/membraince.js"
  if mkdir -p "$(dirname "$target")" &&
    curl -fsSL --max-time 60 "${SOURCE}/integrations/opencode/membraince.js" -o "${target}.new" 2>"$log" &&
    mv -f "${target}.new" "$target"; then
    say "OpenCode: MemBraince added. Restart OpenCode to use it."
  else
    rm -f "${target}.new"
    say "OpenCode: couldn't download the plugin. Check your connection and run this again."
  fi
fi

# Hermes reads the key from its own .env file. Its commands get an empty
# standard input so they never wait for an answer.
if command -v hermes >/dev/null 2>&1; then
  found=1
  env_file="$(hermes config env-path </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
  if [ -n "$env_file" ] && mkdir -p "$(dirname "$env_file")" && {
    { [ -f "$env_file" ] && grep -v '^MEMBRAINCE_API_KEY=' "$env_file"; } >"${env_file}.new"
    printf 'MEMBRAINCE_API_KEY=%s\n' "$key" >>"${env_file}.new"
  } && mv -f "${env_file}.new" "$env_file" &&
    hermes plugins install membraince/membraince-code/integrations/hermes --force --enable </dev/null >"$log" 2>&1 &&
    hermes config set memory.provider membraince </dev/null >>"$log" 2>&1; then
    say "Hermes: MemBraince is now your memory provider. Start a new session to use it."
  else
    say "Hermes: setup didn't finish. Run \`hermes plugins install membraince/membraince-code/integrations/hermes\` to see why."
  fi
fi

# Codex's hooks read the saved key. Signing in and trusting the hooks are
# yours to do, inside Codex.
if command -v codex >/dev/null 2>&1; then
  found=1
  codex plugin marketplace add membraince/membraince-code </dev/null >"$log" 2>&1
  codex plugin marketplace upgrade membraince </dev/null >>"$log" 2>&1
  if codex plugin add membraince@membraince </dev/null >>"$log" 2>&1; then
    say "Codex: MemBraince added. Open Codex, sign in when it asks to connect MemBraince and choose the same home project as your key's, then run /hooks and trust the MemBraince hooks."
  else
    say "Codex: couldn't add the plugin. Add it from /plugins in Codex: ${REPO}/tree/main/integrations/codex"
  fi
elif [ -d "${HOME}/.codex" ]; then
  found=1
  say "Codex: add MemBraince from Plugins in the Codex app. Steps: ${REPO}/tree/main/integrations/codex"
fi

if command -v claude >/dev/null 2>&1; then
  found=1
  say "Claude Code: run /plugin marketplace add membraince/membraince-code, then /plugin install membraince@membraince, and paste your key when asked."
fi

if [ "$found" -eq 0 ]; then
  say "No OpenCode, Hermes, Codex, or Claude Code found on this computer. Install one and run this again; other tools are listed at ${REPO}"
else
  say "Check it works: tell your agent \"Remember that I prefer short commit messages\", then ask about it in a new session."
fi
