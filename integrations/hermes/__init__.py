"""MemBraince memory provider for Hermes Agent: long-term memory across your tools.

A MemoryProvider in plain Python with no dependencies, so it runs the same on Windows, macOS, and
Linux. Everything goes to MEMBRAINCE_URL (https://membraince.com by default) with your API key in
the X-API-Key header; nothing is sent to any other service.

- Session start: memories related to the project, and what earlier sessions in this folder learned
  about its code, go in the system prompt.
- Each prompt: Hermes adds what MemBraince returns for it to that turn.
- After a turn: the prompt you typed, and the files Hermes read and edited and the commands it ran
  (with "Learn the repository" on), are kept as small files in a private folder on this computer. A
  save sends them at most every 15 minutes per session, before compaction, and when a session ends,
  and deletes them only once MemBraince confirms. Hermes's replies are never sent, and neither are
  tool calls naming a secret file (.env, keys, credentials).
- Memory tools: membraince_recall, membraince_remember, membraince_forget.
- A group, channel, or thread on a messaging platform: memory stays off.

When MemBraince refuses the key (no subscription, a limit reached, ...), you are told why, at most
once a day per problem. A failure never blocks Hermes.
"""

from __future__ import annotations

import hashlib
import http.client
import itertools
import json
import logging
import os
import re
import shutil
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable, Optional

from agent.memory_provider import MemoryProvider

logger = logging.getLogger(__name__)

DEFAULT_URL = "https://membraince.com"
PORTAL = "https://membraince.com/portal"
# Hermes gives a provider's recall 8 seconds a turn; past that it stops waiting.
RECALL_SECONDS = 7
TOOL_SECONDS = 30
SAVE_SECONDS = 20
# What a session's end and Hermes's shutdown wait for at most, so a stuck server can't hold up quitting.
SESSION_END_SECONDS = 10
SHUTDOWN_SECONDS = 5
RECOVER_SECONDS = 4
SAVE_EVERY_SECONDS = 15 * 60
NOTICE_EVERY_SECONDS = 24 * 3600
QUEUE_KEPT_SECONDS = 30 * 24 * 3600
# A queue touched more recently may belong to a session still running; its own saves send it.
LEFTOVER_AFTER_SECONDS = 3600
UPLOAD_MAX_BYTES = 16 * 1024 * 1024
TOOL_RESULT_MAX_CHARS = 1_000_000
# Platforms running on your computer, whose working folder is a project.
LOCAL_PLATFORMS = {"cli", "tui", "acp"}
DIRECT_CHATS = {"dm", "private"}
# What Learn the repository keeps. Everything else Hermes does (web searches, messages, ...) stays here.
LEARNED_TOOLS = {"read_file", "write_file", "patch", "terminal"}
_SECRET_NAME = re.compile(
    r"(?:^|[/\\\s=])"
    r"(?:\.env(?:\.[\w-]+)?|[^/\\\s]+\.(?:pem|key|p12|pfx|jks|keystore)|id_(?:rsa|dsa|ecdsa|ed25519)[^/\\\s]*"
    r"|\.netrc|\.npmrc|\.pypirc|\.git-credentials|credentials(?:\.\w+)?|secrets?(?:\.\w+)?)"
    r"(?:$|[\s\"';|&)])"
)
_PATCH_FILE = re.compile(r"^\*\*\*\s*\w+\s+File:\s*(.+)$", re.M)

REFUSALS = {
    401: f"MemBraince didn't accept your API key, so memory is off. Run `hermes memory setup` to enter it again, or create a new one at {PORTAL}.",
    402: f"MemBraince memory is off until you subscribe at {PORTAL}. What you type stays queued on this computer for up to 30 days and is saved once you do.",
    403: f"MemBraince doesn't know the project in MEMBRAINCE_PROJECT for this key. Use a project name from {PORTAL}, or leave it unset.",
    423: f"This API key can't unlock your encrypted MemBraince memories. Create a new key at {PORTAL}, then run `hermes memory setup` to enter it.",
    429: f"This API key has reached a MemBraince limit, so memory is paused. Usage is on {PORTAL}; what you type stays queued and is saved later.",
}

INSTRUCTIONS = """MemBraince is the user's long-term memory across conversations and tools.
- {recall}
- Call `membraince_remember` when the user states a durable fact, preference, decision, or correction \
worth knowing in a future conversation. Write one self-contained statement per call, in plain language, \
with names and dates spelled out ("Dana prefers PostgreSQL over MySQL for new services", not "she prefers it").
- Never store passwords, API keys, tokens, or other secrets.
- Call `membraince_forget` with a memory id from `membraince_recall` when the user asks you to forget \
something or a memory is wrong.
New memories become searchable a few seconds after `membraince_remember` returns."""
RECALL_ADDED = (
    "Memories from MemBraince are added to this conversation at session start and with each prompt. Use them "
    "when they apply, say so when one changed what you did, and call `membraince_recall` only for something "
    "they don't cover."
)
RECALL_ASK = (
    "At the start of a task, call `membraince_recall` with a short description of the task when the user's "
    "preferences, past decisions, people, or project facts could matter. Use what it returns, and say so when "
    "a memory changed what you did."
)

TOOLS = {
    "membraince_recall": ("recall", {
        "name": "membraince_recall",
        "description": "Search the user's long-term memory. Returns the most relevant stored memories with their ids.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "What to look for, as a question or short description."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 8,
                          "description": "Maximum number of memories to return."},
            },
            "required": ["query"],
        },
    }),
    "membraince_remember": ("remember", {
        "name": "membraince_remember",
        "description": ("Save something to the user's long-term memory: a fact, preference, decision, or "
                        "correction worth knowing in future conversations."),
        "parameters": {
            "type": "object",
            "properties": {"content": {"type": "string", "description": "One self-contained statement to remember."}},
            "required": ["content"],
        },
    }),
    "membraince_forget": ("forget", {
        "name": "membraince_forget",
        "description": "Delete one memory by the id that membraince_recall returned.",
        "parameters": {
            "type": "object",
            "properties": {"memory_id": {"type": "string", "description": "Id of the memory to delete."}},
            "required": ["memory_id"],
        },
    }),
}


def _setting(name: str) -> str:
    """A setting from Hermes's environment, for this profile when one process serves several."""
    try:
        from agent.secret_scope import get_secret  # Hermes 0.22 and later
    except ImportError:
        return (os.environ.get(name) or "").strip()
    try:
        return (get_secret(name, "") or "").strip()
    except Exception:
        return ""


def _spawn(target: Callable[..., Any], name: str, *args: Any) -> threading.Thread:
    try:
        from agent.memory_provider import spawn_context_thread  # keeps this profile's context on the thread
    except ImportError:
        thread = threading.Thread(target=target, args=args, name=name, daemon=True)
    else:
        thread = spawn_context_thread(target, name=name, args=args)
    thread.start()
    return thread


def _shared_chat(init: dict[str, Any]) -> bool:
    """A chat where other people type and read the replies: a group, channel, or thread on a messaging platform.

    Their messages would be saved to your account, and your memories could come up in front of them.
    """
    chat_type = str(init.get("chat_type") or "").strip().lower()
    return chat_type not in DIRECT_CHATS if chat_type or init.get("chat_id") else False


def _working_folder(init: dict[str, Any]) -> str:
    """The project this session works in, or "" where there is none to learn about."""
    if init.get("cwd"):
        return str(init["cwd"])
    # On a messaging platform the folder isn't a project.
    if str(init.get("platform") or "cli") not in LOCAL_PLATFORMS:
        return ""
    # A process hosting sessions is in some other folder of its own, so only the session's own counts there.
    hosted = bool(init.get("gateway_session_key"))
    try:
        from agent.runtime_cwd import scope_terminal_cwd
    except ImportError:
        folder = "" if hosted else os.environ.get("TERMINAL_CWD", "")
    else:
        try:
            folder = scope_terminal_cwd()
        except Exception:
            return ""
    if folder:
        return os.path.abspath(folder)
    return "" if hosted else os.getcwd()


def _names_secret(args: dict[str, Any]) -> bool:
    named = [args.get("path"), args.get("command"), *_PATCH_FILE.findall(str(args.get("patch") or ""))]
    return any(isinstance(name, str) and _SECRET_NAME.search(name.strip()) for name in named)


def _message_text(content: Any) -> str:
    if isinstance(content, list):
        return "\n".join(part["text"] for part in content if isinstance(part, dict) and isinstance(part.get("text"), str))
    return content if isinstance(content, str) else ""


def _safe_name(session_id: str) -> str:
    """A session's folder name. Hermes's ids can be 70 characters, too long for Windows paths under a long home."""
    name = re.sub(r"[^A-Za-z0-9_-]", "", session_id or "")
    return name if len(name) <= 32 else hashlib.sha256(name.encode("utf-8")).hexdigest()[:32]


def _limit_to_this_account(folder: Path) -> None:
    """On Windows, folder modes do nothing: replace the inherited permissions with your account alone."""
    if os.name != "nt":
        return
    account = os.environ.get("USERNAME")
    if not account:
        return
    try:
        subprocess.run(
            ["icacls", str(folder), "/inheritance:r", "/grant:r", f"{account}:(OI)(CI)F"],
            capture_output=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.SubprocessError):
        logger.debug("Could not limit the MemBraince queue folder to this account", exc_info=True)


class _SessionStart:
    """One session-start request, answered in the background."""

    def __init__(self) -> None:
        self.done = threading.Event()
        self.text = ""
        self.shown = False


class MemBrainceProvider(MemoryProvider):
    def __init__(self) -> None:
        self._key = ""
        self._user = "default"
        self._project = ""
        self._base = DEFAULT_URL
        self._auto_recall = True
        self._auto_save = True
        self._learn = True
        self._off = False
        self._primary = True
        self._init: dict[str, Any] = {}
        self._cwd = ""
        self._session_id = ""
        self._root: Optional[Path] = None  # set by initialize; nothing is queued or sent before that
        self._warn: Optional[Callable[[str], None]] = None
        self._tls: Optional[ssl.SSLContext] = None
        self._start: Optional[_SessionStart] = None
        self._recalled = False
        self._refusal = 0
        self._told: set[int] = set()
        self._last_save: dict[str, float] = {}
        self._saving = threading.Lock()
        self._turn_lock = threading.Lock()
        self._held: list[dict[str, Any]] = []
        self._seen: set[tuple[str, str, str]] = set()
        self._order = itertools.count()
        self._threads: list[threading.Thread] = []

    @property
    def name(self) -> str:
        return "membraince"

    def is_available(self) -> bool:
        return bool(_setting("MEMBRAINCE_API_KEY"))

    def unavailable_reason(self) -> str:
        return f"MEMBRAINCE_API_KEY isn't set. Create a key at {PORTAL}, then run `hermes memory setup`."

    def get_config_schema(self) -> list[dict[str, Any]]:
        return [{
            "key": "api_key",
            "description": "MemBraince API key",
            "secret": True,
            "required": True,
            "env_var": "MEMBRAINCE_API_KEY",
            "url": PORTAL,
        }]

    def save_config(self, values: dict[str, Any], hermes_home: str) -> None:
        """Nothing to write: the key is in Hermes's .env, and the other settings are environment variables."""

    def initialize(self, session_id: str, **kwargs: Any) -> None:
        self._session_id = session_id or ""
        self._key = _setting("MEMBRAINCE_API_KEY")
        self._user = _setting("MEMBRAINCE_USER") or "default"
        self._project = _setting("MEMBRAINCE_PROJECT")
        base = (_setting("MEMBRAINCE_URL") or DEFAULT_URL).rstrip("/")
        self._base = base[: -len("/v1/mcp")] if base.endswith("/v1/mcp") else base
        self._auto_recall = _setting("MEMBRAINCE_AUTO_RECALL").lower() != "false"
        self._auto_save = _setting("MEMBRAINCE_AUTO_SAVE").lower() != "false"
        self._learn = _setting("MEMBRAINCE_LEARN_CODE").lower() != "false"
        platform = str(kwargs.get("platform") or "cli")
        self._off = not self._key or _shared_chat(kwargs)
        # Cron jobs and subagents recall, but only the sessions you type in save.
        self._primary = kwargs.get("agent_context", "primary") == "primary" and platform not in {"cron", "subagent"}
        self._init = kwargs
        self._cwd = _working_folder(kwargs)
        self._warn = kwargs.get("warning_callback")
        # Queues are kept per key, memory owner, project, and server, so a leftover queue is only
        # ever sent where it was meant to go. The folder name holds a hash, never the key.
        identity = "\n".join((self._key, self._user, self._project, self._base))
        fingerprint = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:16]
        self._root = Path(kwargs.get("hermes_home") or Path.home() / ".hermes") / f"membraince-queue-{fingerprint}"
        if self._off:
            return
        if self._auto_recall:
            self._request_session_start()
        if self._saves():
            self._background(self._send_leftovers, "membraince-leftovers")

    def system_prompt_block(self) -> str:
        if self._off:
            return ""
        instructions = INSTRUCTIONS.format(recall=RECALL_ADDED if self._auto_recall else RECALL_ASK)
        start = self._start
        if start is None:
            return instructions
        # Later prompt rebuilds repeat the same text, which keeps Hermes's prompt cache valid.
        if start.done.wait(RECALL_SECONDS):
            start.shown = True
        return f"{instructions}\n\n{start.text}" if start.shown and start.text else instructions

    def prefetch(self, query: str, *, session_id: str = "", **kwargs: Any) -> str:
        self._recalled = False
        if self._off:
            return ""
        self._cwd = _working_folder(self._init)  # a session can move to another folder between turns
        parts = []
        if self._auto_recall:
            start = self._start
            # An answer too slow for the system prompt, or a session Hermes resumed with its stored one.
            if start is not None and not start.shown and start.done.is_set():
                start.shown = True
                parts.append(start.text)
            hook = {"hook_event_name": "UserPromptSubmit", "session_id": session_id or self._session_id, "prompt": query}
            parts.append(self._post_text("prompt", self._with_cwd(hook)))
        self._recalled = any(parts)
        notice = self._tell_refusal()
        if notice:
            parts.append(f"MemBraince isn't working for this user. Tell them once, in your own words: {notice}")
        return "\n\n".join(part for part in parts if part)

    def on_turn_start(self, turn_number: int, message: str, **kwargs: Any) -> None:
        # Hermes skips prefetch for prompts such as "thanks"; a turn start always comes.
        if self._warn is not None:
            self._tell_refusal()

    def recall_status(self) -> Any:
        if not self._recalled:
            return None
        from agent.memory_provider import RecallStatus  # Hermes 0.22 and later, which is what calls this

        return RecallStatus(provider_label="MemBraince", count=0)

    def sync_turn(self, user_content: str, assistant_content: str, *, session_id: str = "",
                  messages: Optional[list[dict[str, Any]]] = None, **kwargs: Any) -> None:
        if not self._saves():
            return
        author = kwargs.get("turn_author")
        if isinstance(author, dict) and author.get("is_bot"):
            return  # not something you typed
        session = session_id or self._session_id
        self._cwd = _working_folder(self._init)
        with self._turn_lock:
            calls = [*self._held, *self._new_tool_calls(messages)]
            self._held = []
            self._seen = set()
        self._queue(session, self._with_cwd({"hook_event_name": "UserPromptSubmit", "session_id": session, "prompt": user_content}))
        for call in calls:
            self._queue(session, self._with_cwd({"hook_event_name": "PostToolUse", "session_id": session, **call}))
        if time.monotonic() - self._last_save.get(session, -SAVE_EVERY_SECONDS) >= SAVE_EVERY_SECONDS:
            self._flush(session, SAVE_SECONDS)

    def on_pre_compress(self, messages: list[dict[str, Any]], **kwargs: Any) -> str:
        if self._saves():
            # Mid-turn, compaction removes this turn's tool calls from the list, so they wait here for
            # the turn's prompt. After a reply the turn is over, and its sync has its calls already.
            last = messages[-1] if messages else None
            finished = isinstance(last, dict) and last.get("role") == "assistant" and not last.get("tool_calls")
            if not finished:
                with self._turn_lock:
                    self._held += self._new_tool_calls(messages)
            self._background(self._flush, "membraince-save", self._session_id, SAVE_SECONDS)
        return ""

    def on_session_switch(self, new_session_id: str, *, parent_session_id: str = "", reset: bool = False,
                          rewound: bool = False, **kwargs: Any) -> None:
        if self._off:
            return
        previous, self._session_id = self._session_id, new_session_id or self._session_id
        if self._saves() and previous and previous != self._session_id:
            self._background(self._flush, "membraince-save", previous, SAVE_SECONDS)
        if reset and self._auto_recall:
            self._request_session_start()

    def on_session_end(self, messages: list[dict[str, Any]], **kwargs: Any) -> None:
        if self._saves():
            self._flush(self._session_id, SESSION_END_SECONDS)

    def shutdown(self) -> None:
        deadline = time.monotonic() + SHUTDOWN_SECONDS
        for thread in self._threads:
            thread.join(max(0, deadline - time.monotonic()))
        # Hermes finishes a turn's sync before this, so a last prompt is on disk by now.
        if self._saves():
            self._flush(self._session_id, SHUTDOWN_SECONDS)

    def get_tool_schemas(self) -> list[dict[str, Any]]:
        return [] if self._off else [schema for _, schema in TOOLS.values()]

    def handle_tool_call(self, tool_name: str, args: dict[str, Any], **kwargs: Any) -> str:
        if self._off or tool_name not in TOOLS:
            return json.dumps({"error": f"MemBraince can't run {tool_name} here."})
        call = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": TOOLS[tool_name][0], "arguments": args}}
        status, text = self._post("/v1/mcp", json.dumps(call).encode("utf-8"), "application/json", TOOL_SECONDS)
        if status in REFUSALS:
            self._note_refusal(status)
            return json.dumps({"error": REFUSALS[status]})
        try:
            reply = json.loads(text) if status == 200 else None
        except ValueError:
            reply = None
        result = reply.get("result") if isinstance(reply, dict) else None
        if not isinstance(result, dict):
            problem = reply.get("error") if isinstance(reply, dict) else None
            message = problem.get("message") if isinstance(problem, dict) else None
            return json.dumps({"error": message or "MemBraince couldn't be reached. Try again in a moment."})
        answer = "\n".join(str(part.get("text") or "") for part in result.get("content") or []
                           if isinstance(part, dict) and part.get("type") == "text")
        return json.dumps({"error": answer} if result.get("isError") else {"result": answer})

    # Requests

    def _post(self, path: str, body: bytes, content_type: str, seconds: float) -> tuple[int, str]:
        """(status, answer); status 0 when no answer came. Your key goes only to the server in your settings."""
        headers = {"X-API-Key": self._key, "X-MemBraince-User": self._user, "Content-Type": content_type,
                   "Accept": "application/json, text/plain", "User-Agent": "membraince-hermes"}
        if self._project:
            headers["X-MemBraince-Project"] = self._project
        request = urllib.request.Request(self._base + path, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=seconds, context=self._tls_context()) as response:
                return response.status, response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as refused:
            refused.close()
            return refused.code, ""
        except (OSError, http.client.HTTPException, ValueError):
            return 0, ""

    def _tls_context(self) -> ssl.SSLContext:
        if self._tls is None:
            context = ssl.create_default_context()
            try:
                import certifi  # some Python builds have no system certificates to fall back on

                context.load_verify_locations(certifi.where())
            except (ImportError, OSError):
                pass
            self._tls = context
        return self._tls

    def _post_text(self, route: str, hook: dict[str, Any]) -> str:
        status, text = self._post(f"/v1/integrations/hermes/{route}", json.dumps(hook).encode("utf-8"),
                                  "application/json", RECALL_SECONDS)
        if 200 <= status < 300:
            return text.strip()
        self._note_refusal(status)
        return ""

    def _with_cwd(self, hook: dict[str, Any]) -> dict[str, Any]:
        return {**hook, "cwd": self._cwd} if self._cwd else hook

    def _request_session_start(self) -> None:
        start = _SessionStart()
        self._start = start

        def fetch() -> None:
            try:
                hook = {"hook_event_name": "SessionStart", "session_id": self._session_id}
                start.text = self._post_text("session-start", self._with_cwd(hook))
            finally:
                start.done.set()

        self._background(fetch, "membraince-session-start")

    def _background(self, target: Callable[..., Any], name: str, *args: Any) -> None:
        self._threads = [thread for thread in self._threads if thread.is_alive()]
        self._threads.append(_spawn(target, name, *args))

    # Telling you about a refusal

    def _note_refusal(self, status: int) -> None:
        """Keep MemBraince's refusal for the next turn: before one starts, Hermes has nowhere to show it."""
        if status in REFUSALS:
            with self._turn_lock:
                self._refusal = status

    def _tell_refusal(self) -> str:
        """The refusal in one line, for the same problem at most once a day.

        With a warning line, Hermes prints it for you and the model never sees it. Without one
        (messaging platforms), this returns the text to add to the turn.
        """
        with self._turn_lock:
            status, self._refusal = self._refusal, 0
        if not status or status in self._told:
            return ""
        self._told.add(status)
        mark = self._root / f"notice-{status}"
        try:
            if time.time() - mark.stat().st_mtime < NOTICE_EVERY_SECONDS:
                return ""
        except OSError:
            pass
        try:
            self._ensure_root()
            mark.touch()
        except OSError:
            logger.debug("Could not record a MemBraince notice", exc_info=True)
        if self._warn is not None:
            try:
                self._warn(REFUSALS[status])
                return ""
            except Exception:
                logger.debug("Hermes's warning line failed", exc_info=True)
        return REFUSALS[status]

    # The local queue

    def _saves(self) -> bool:
        return self._root is not None and not self._off and self._primary and self._auto_save

    def _new_tool_calls(self, messages: Optional[list[dict[str, Any]]]) -> list[dict[str, Any]]:
        """This turn's file reads, edits, and commands not kept yet: everything after your last message."""
        if not self._learn or not self._cwd or not messages:
            return []
        turn = list(messages)
        for index in range(len(turn) - 1, -1, -1):
            if isinstance(turn[index], dict) and turn[index].get("role") == "user":
                turn = turn[index + 1:]
                break
        results = {m.get("tool_call_id"): _message_text(m.get("content"))
                   for m in turn if isinstance(m, dict) and m.get("role") == "tool"}
        calls = []
        for message in turn:
            if not isinstance(message, dict) or message.get("role") != "assistant":
                continue
            for call in message.get("tool_calls") or []:
                function = call.get("function") if isinstance(call, dict) else None
                if not isinstance(function, dict) or function.get("name") not in LEARNED_TOOLS:
                    continue
                result = results.get(call.get("id"))
                raw = function.get("arguments")
                seen = (str(call.get("id")), str(function["name"]), str(raw))
                if result is None or len(result) > TOOL_RESULT_MAX_CHARS or seen in self._seen:
                    continue
                self._seen.add(seen)
                try:
                    args = json.loads(raw) if isinstance(raw, str) else raw
                except ValueError:
                    continue
                if isinstance(args, dict) and not _names_secret(args):
                    calls.append({"tool_name": function["name"], "tool_input": args, "tool_response": result})
        return calls

    def _ensure_root(self) -> None:
        if not self._root.is_dir():
            self._root.mkdir(parents=True, mode=0o700, exist_ok=True)
            _limit_to_this_account(self._root)

    def _queue(self, session: str, hook: dict[str, Any]) -> None:
        name = f"{time.time_ns():020d}-{os.getpid()}-{next(self._order):06d}"
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        # Each line carries an id, so a save resent after a lost answer stores nothing twice.
        line = json.dumps({"id": name, "time": now, "hook": hook}) + "\n"
        if not _safe_name(session):
            return
        try:
            self._ensure_root()
            folder = self._root / _safe_name(session)
            folder.mkdir(mode=0o700, exist_ok=True)
            # Written under a hidden name, then renamed: a save only ever sees whole files.
            hidden = folder / f".{name}.tmp"
            with open(os.open(hidden, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="ascii", newline="\n") as handle:
                handle.write(line)
            os.replace(hidden, folder / f"{name}.json")
        except OSError as error:
            logger.warning("Could not queue a MemBraince save: %s", error)

    def _flush(self, session: str, seconds: float) -> bool:
        """Send a session's queue, deleting exactly the files sent once MemBraince confirms; True when nothing is left."""
        if not _safe_name(session):
            return True
        if not self._saving.acquire(timeout=seconds):
            return False
        try:
            folder = self._root / _safe_name(session)
            try:
                files = sorted(folder.glob("*.json"))
            except OSError:
                return False
            while files:
                batch: list[Path] = []
                body = bytearray()
                try:
                    for path in files:
                        data = path.read_bytes()
                        if batch and len(body) + len(data) > UPLOAD_MAX_BYTES:
                            break
                        body += data
                        batch.append(path)
                except OSError:
                    # A file that can't be read stops the save before anything is sent or deleted.
                    return False
                status, _ = self._post("/v1/integrations/hermes/transcript", bytes(body), "application/x-ndjson", seconds)
                if not 200 <= status < 300:
                    self._note_refusal(status)
                    return False
                for path in batch:
                    try:
                        path.unlink()
                    except OSError:
                        pass  # resent later; MemBraince recognizes the line
                files = files[len(batch):]
            self._last_save[session] = time.monotonic()
            return True
        finally:
            self._saving.release()

    def _send_leftovers(self) -> None:
        """Send what earlier sessions with this key couldn't, and delete a queue left alone for 30 days."""
        current = _safe_name(self._session_id)
        try:
            folders = [folder for folder in self._root.iterdir() if folder.is_dir() and folder.name != current]
        except OSError:
            return
        for folder in folders:
            try:
                newest = max(path.stat().st_mtime for path in (folder, *folder.iterdir()))
                age = time.time() - newest
                if age > QUEUE_KEPT_SECONDS:
                    shutil.rmtree(folder, ignore_errors=True)
                elif age > LEFTOVER_AFTER_SECONDS and not self._flush(folder.name, RECOVER_SECONDS):
                    return  # the server is down or refusing: later sessions try again
            except OSError:
                continue


def register(ctx: Any) -> None:
    ctx.register_memory_provider(MemBrainceProvider())
    # Hermes 0.22 and later: everything else works without it on older versions.
    register_skill = getattr(ctx, "register_skill", None)
    if register_skill is not None:
        register_skill(
            "memory",
            Path(__file__).parent / "skills" / "memory" / "SKILL.md",
            description="Look up, add, correct, or remove what MemBraince remembers.",
        )
