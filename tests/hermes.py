"""Tests for the Hermes plugin (integrations/hermes) against fake_server.py, a stand-in for MemBraince.

Hermes itself isn't needed: a small stand-in gives the plugin the base class it imports. Run from
the repository root: python tests/hermes.py
"""

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "integrations" / "hermes"
SETTINGS = ("MEMBRAINCE_API_KEY", "MEMBRAINCE_USER", "MEMBRAINCE_PROJECT", "MEMBRAINCE_URL",
            "MEMBRAINCE_AUTO_RECALL", "MEMBRAINCE_AUTO_SAVE", "MEMBRAINCE_LEARN_CODE")
RECALLED = "Memories from MemBraince: (test)"


class RecallStatus:
    def __init__(self, provider_label, count):
        self.provider_label, self.count = provider_label, count


agent = types.ModuleType("agent")
memory_provider = types.ModuleType("agent.memory_provider")
memory_provider.MemoryProvider = object
memory_provider.RecallStatus = RecallStatus
sys.modules.update({"agent": agent, "agent.memory_provider": memory_provider})
spec = importlib.util.spec_from_file_location("membraince_hermes", PLUGIN / "__init__.py")
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)

work = Path(tempfile.mkdtemp(prefix="membraince-hermes-"))
server_folder = work / "server"
server_folder.mkdir()
server = subprocess.Popen([sys.executable, str(ROOT / "tests" / "fake_server.py"), str(server_folder)])
for _ in range(200):
    if (server_folder / "port").exists():
        break
    time.sleep(0.05)
URL = f"http://127.0.0.1:{(server_folder / 'port').read_text()}"

failures = 0
homes = 0


def check(description, ok):
    global failures
    print(f"  {'ok  ' if ok else 'FAIL'} {description}")
    if not ok:
        failures += 1


def section(title):
    print(f"== {title}")


def control(name, value=""):
    (server_folder / name).write_text(value, encoding="utf-8")


def reset():
    """Forget what the server saw and stop any failure it was told to act out."""
    for name in ("routes.txt", "uploaded.txt", "received.txt", "requests.jsonl",
                 "status", "fail", "drop", "tool-error", "recall-slow", "recall-empty"):
        (server_folder / name).unlink(missing_ok=True)


def home():
    global homes
    homes += 1
    folder = work / f"home{homes}"
    folder.mkdir()
    return folder


def provider(session="s1", folder=None, env=None, **init):
    """A provider initialized the way Hermes does, with its background requests finished."""
    for name in SETTINGS:
        os.environ.pop(name, None)
    os.environ.update({"MEMBRAINCE_API_KEY": "key-a", "MEMBRAINCE_URL": URL, **(env or {})})
    made = plugin.MemBrainceProvider()
    init.setdefault("platform", "cli")
    if init["platform"] == "cli":
        init.setdefault("cwd", "/w/app")
    made.initialize(session, hermes_home=str(folder or home()), **init)
    settle(made)
    return made


def settle(made):
    for thread in list(made._threads):
        thread.join(30)


def lines(name):
    path = server_folder / name
    return path.read_text(encoding="utf-8").splitlines() if path.exists() else []


def routes():
    return [line.removeprefix("/v1/integrations/hermes/") for line in lines("routes.txt")]


def requests():
    return [json.loads(line) for line in lines("requests.jsonl")]


def sent(route):
    return [json.loads(entry["body"]) for entry in requests() if entry["path"].endswith("/" + route)]


def queue_files(made):
    return sorted(path for path in made._root.rglob("*.json"))


def tool_call(call_id, name, args):
    return {"id": call_id, "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}


def conversation(prompt, *calls):
    """A conversation so far, as Hermes hands it over: an earlier turn, then this one's calls and results."""
    messages = [
        {"role": "user", "content": "An earlier prompt"},
        {"role": "assistant", "content": None, "tool_calls": [tool_call("old", "read_file", {"path": "/w/app/old.py"})]},
        {"role": "tool", "tool_call_id": "old", "content": '{"content": "1|old"}'},
        {"role": "assistant", "content": "Done earlier."},
        {"role": "user", "content": prompt},
    ]
    for call_id, name, args, result in calls:
        messages.append({"role": "assistant", "content": None, "tool_calls": [tool_call(call_id, name, args)]})
        messages.append({"role": "tool", "tool_call_id": call_id, "content": result})
    return [*messages, {"role": "assistant", "content": "Done."}]


READ = ("c1", "read_file", {"path": "/w/app/core.py"}, '{"content": "1|class Core:", "total_lines": 1}')
PATCH = ("c2", "patch", {"mode": "replace", "path": "/w/app/core.py", "old_string": "a", "new_string": "b"}, '{"success": true}')
TERMINAL = ("c3", "terminal", {"command": "pytest -q"}, '{"output": "4 passed", "exit_code": 0, "error": null}')


try:
    section("setup")
    for name in SETTINGS:
        os.environ.pop(name, None)
    check("not available without a key", plugin.MemBrainceProvider().is_available() is False)
    os.environ["MEMBRAINCE_API_KEY"] = "key-a"
    reset()
    check("available with a key, without a request", plugin.MemBrainceProvider().is_available() and not routes())
    schema = plugin.MemBrainceProvider().get_config_schema()
    check("the wizard asks for the key alone, hidden, saved to Hermes's .env",
          len(schema) == 1 and schema[0]["secret"] and schema[0]["env_var"] == "MEMBRAINCE_API_KEY")
    source = (PLUGIN / "__init__.py").read_text(encoding="utf-8")
    check("Hermes's discovery finds the provider in the file's first 8 KB", "MemoryProvider" in source[:8192])
    manifest = (PLUGIN / "plugin.yaml").read_text(encoding="utf-8")
    check("the manifest names the plugin as Hermes's setup expects", "name: membraince\n" in manifest and "MEMBRAINCE_API_KEY" in manifest)

    registered = []
    class Context:
        def register_memory_provider(self, made):
            registered.append(made)
    plugin.register(Context())
    check("older Hermes (no skills from a provider): the provider still registers", len(registered) == 1)
    skills = []
    class NewerContext(Context):
        def register_skill(self, name, path, description=""):
            skills.append((name, Path(path)))
    plugin.register(NewerContext())
    check("newer Hermes gets the memory skill, and its file exists", skills and skills[0][0] == "memory" and skills[0][1].is_file())
    skill = (PLUGIN / "skills" / "memory" / "SKILL.md").read_text(encoding="utf-8")
    check("the skill names the tools as Hermes shows them", "membraince_recall" in skill and "membraince_forget" in skill)

    section("recall")
    reset()
    warnings = []
    made = provider("s1", warning_callback=warnings.append)
    check("session start asks once, in the background", routes() == ["session-start"])
    body = sent("session-start")[0]
    check("it sends the session id and project folder", body["session_id"] == "s1" and body["cwd"] == "/w/app")
    block = made.system_prompt_block()
    check("the system prompt holds the instructions and the session-start memories",
          "membraince_remember" in block and RECALLED in block and "secrets" in block)
    check("rebuilding the system prompt gives the same text and no request",
          made.system_prompt_block() == block and routes() == ["session-start"])
    answer = made.prefetch("How do I deploy?", session_id="s1")
    check("a prompt gets what recall returns, once", answer == RECALLED)
    body = sent("prompt")[0]
    check("the prompt route gets the prompt, session, and folder",
          body["prompt"] == "How do I deploy?" and body["session_id"] == "s1" and body["cwd"] == "/w/app")
    headers = {key.lower(): value for key, value in requests()[0]["headers"].items()}
    check("requests carry the key and default memory owner, and no project unless set",
          headers["x-api-key"] == "key-a" and headers["x-membraince-user"] == "default" and "x-membraince-project" not in headers)
    status = made.recall_status()
    check("Hermes can show that memories were recalled", status.provider_label == "MemBraince" and status.count == 0)
    check("no warning while MemBraince accepts the key", warnings == [])
    made.prefetch("hello there")
    reset()
    control("recall-empty")
    made = provider("s1")
    check("an empty answer adds nothing", made.prefetch("x") == "" and made.recall_status() is None)

    reset()
    control("recall-slow")
    original = plugin.RECALL_SECONDS
    plugin.RECALL_SECONDS = 5
    made = plugin.MemBrainceProvider()
    os.environ.update({"MEMBRAINCE_API_KEY": "key-a", "MEMBRAINCE_URL": URL})
    made.initialize("late", hermes_home=str(home()), platform="cli", cwd="/w/app")
    plugin.RECALL_SECONDS = 0.1
    late_block = made.system_prompt_block()
    plugin.RECALL_SECONDS = 5
    settle(made)
    (server_folder / "recall-slow").unlink()
    check("a slow session start doesn't hold up the system prompt", RECALLED not in late_block)
    check("its answer comes with the next prompt instead", made.prefetch("x") == f"{RECALLED}\n\n{RECALLED}")
    check("and only that once", made.prefetch("y") == RECALLED)
    plugin.RECALL_SECONDS = original

    section("automatic save")
    reset()
    folder = home()
    made = provider("s1", folder)
    secret_read = ("c4", "read_file", {"path": "/w/app/.env"}, '{"content": "1|KEY=x"}')
    secret_pem = ("c5", "read_file", {"path": "/w/app/certs/server.pem"}, '{"content": "1|x"}')
    secret_command = ("c6", "terminal", {"command": "cat .env.local | grep KEY"}, '{"output": "KEY=x", "exit_code": 0}')
    secret_patch = ("c7", "patch", {"mode": "patch", "patch": "*** Begin Patch\n*** Update File: config/credentials.yaml\n-a\n+b\n*** End Patch"}, '{"success": true}')
    secret_ssh = ("c8", "write_file", {"path": "/home/d/.ssh/id_ed25519", "content": "x"}, '{"bytes_written": 1}')
    other = ("c9", "web_search", {"query": "weather"}, '{"results": ["sunny"]}')
    made.sync_turn("Fix the core", "Fixed.", session_id="s1", messages=conversation(
        "Fix the core", READ, secret_read, secret_pem, PATCH, secret_command, secret_patch, secret_ssh, other, TERMINAL))
    uploaded = lines("uploaded.txt")
    check("the first turn saves right away: the prompt, then the turn's calls, in order",
          uploaded == ["key-a Fix the core", "key-a tool read_file", "key-a tool patch", "key-a tool terminal"])
    received = "\n".join(lines("received.txt"))
    check("an earlier turn's calls aren't sent again", "old.py" not in received)
    check("nothing naming a secret file is sent", not any(word in received for word in (".env", "server.pem", "credentials", "id_ed25519")))
    check("other tools' calls stay here", "web_search" not in received and "sunny" not in received)
    check("Hermes's reply isn't sent", "Fixed." not in received)
    check("the tool's arguments and result arrive as Hermes gave them",
          '\\"total_lines\\": 1' in received and '"tool_name": "read_file"' in received and '"cwd": "/w/app"' in received)
    check("a save deletes what it sent", queue_files(made) == [])
    check("saves go to Hermes's own route", all(route == "transcript" for route in routes()[1:]))

    made.sync_turn("Second prompt", "OK", session_id="s1", messages=conversation("Second prompt"))
    check("within 15 minutes a turn only queues", len(lines("uploaded.txt")) == 4 and len(queue_files(made)) == 1)
    made._last_save["s1"] = time.monotonic() - 16 * 60
    made.sync_turn("Third prompt", "OK", session_id="s1", messages=conversation("Third prompt"))
    check("after 15 minutes a turn saves everything queued",
          lines("uploaded.txt")[4:] == ["key-a Second prompt", "key-a Third prompt"] and queue_files(made) == [])

    reset()
    made.sync_turn("Before compaction", "OK", session_id="s1", messages=conversation("Before compaction"))
    made.on_pre_compress(conversation("Now", READ)[:-1])
    settle(made)
    check("compaction sends the queue", lines("uploaded.txt") == ["key-a Before compaction"])
    made.sync_turn("Now", "OK", session_id="s1", messages=[{"role": "user", "content": "Summary"}, {"role": "assistant", "content": "OK"}])
    made.on_session_end([])
    check("a call compaction removed still follows its prompt", lines("uploaded.txt")[1:] == ["key-a Now", "key-a tool read_file"])
    reset()
    made.on_pre_compress(conversation("Kept", READ)[:-1])
    settle(made)
    made.sync_turn("Kept", "OK", session_id="s1", messages=conversation("Kept", READ))
    made.on_session_end([])
    check("a call compaction kept is sent once", lines("uploaded.txt") == ["key-a Kept", "key-a tool read_file"])
    reset()
    finished = conversation("Finished", READ)
    made.sync_turn("Finished", "OK", session_id="s1", messages=finished)
    made.on_pre_compress(finished)
    settle(made)
    made.sync_turn("Next", "OK", session_id="s1", messages=[*finished, {"role": "user", "content": "Next"}, {"role": "assistant", "content": "OK"}])
    made.on_session_end([])
    check("compacting between turns doesn't send the last turn's calls again",
          lines("uploaded.txt") == ["key-a Finished", "key-a tool read_file", "key-a Next"])
    reset()
    made.sync_turn("Last prompt", "OK", session_id="s1", messages=conversation("Last prompt"))
    made.on_session_end([])
    made.shutdown()
    check("a session's end sends the queue, and shutdown has nothing left", lines("uploaded.txt") == ["key-a Last prompt"])
    reset()
    made.sync_turn("Late prompt", "OK", session_id="s1", messages=conversation("Late prompt"))
    made.shutdown()
    check("shutdown sends what's left", lines("uploaded.txt") == ["key-a Late prompt"])

    reset()
    made = provider("s1")
    control("fail")
    made.sync_turn("Kept when a save fails", "OK", session_id="s1", messages=conversation("Kept when a save fails"))
    check("a failed save keeps the prompt", len(queue_files(made)) == 1 and not lines("uploaded.txt"))
    (server_folder / "fail").unlink()
    made.on_session_end([])
    check("the next save sends it", lines("uploaded.txt") == ["key-a Kept when a save fails"] and queue_files(made) == [])

    reset()
    made = provider("s1")
    control("drop")
    made.sync_turn("Answer lost", "OK", session_id="s1", messages=conversation("Answer lost"))
    first = lines("received.txt")
    check("a save whose answer is lost keeps the file", len(queue_files(made)) == 1 and len(first) == 1)
    (server_folder / "drop").unlink()
    made.on_session_end([])
    check("the resend is the same line, so MemBraince stores it once", lines("received.txt") == first * 2 and queue_files(made) == [])

    reset()
    made = provider("s1")
    made._queue("s1", {"session_id": "s1", "prompt": "Unsent"})
    (made._root / "s1" / "99999999999999999999-unreadable.json").mkdir()
    check("a file that can't be read stops the save", made._flush("s1", 2) is False and not lines("uploaded.txt"))
    check("and nothing is deleted", any(path.is_file() for path in queue_files(made)))
    (made._root / "s1" / "99999999999999999999-unreadable.json").rmdir()

    reset()
    made = provider("s1")
    maximum = plugin.UPLOAD_MAX_BYTES
    plugin.UPLOAD_MAX_BYTES = 300
    for number in range(5):
        made._queue("s1", {"session_id": "s1", "prompt": f"Part {number} " + "x" * 120})
    made.on_session_end([])
    plugin.UPLOAD_MAX_BYTES = maximum
    check("a large queue goes out in several uploads, each prompt once, in order",
          routes().count("transcript") > 1 and [line.split()[2] for line in lines("uploaded.txt")] == list("01234"))

    section("leftovers")
    reset()
    folder = home()
    early = provider("early", folder)
    control("fail")
    early.sync_turn("Unsaved", "OK", session_id="early", messages=conversation("Unsaved"))
    (server_folder / "fail").unlink()
    check("a session still running isn't swept by another one", (provider("recent", folder), lines("uploaded.txt"))[1] == [])
    old = time.time() - 2 * 3600
    for path in [early._root / "early", *queue_files(early)]:
        os.utime(path, (old, old))
    provider("other-key", folder, env={"MEMBRAINCE_API_KEY": "key-b"})
    check("another key doesn't send it", lines("uploaded.txt") == [])
    provider("other-server", folder, env={"MEMBRAINCE_URL": URL + "/"})  # the same address
    check("the same key to the same server sends it", lines("uploaded.txt") == ["key-a Unsaved"] and queue_files(early) == [])
    reset()
    old = time.time() - 31 * 24 * 3600
    stale = early._root / "stale"
    stale.mkdir()
    (stale / "1.json").write_text("{}\n", encoding="utf-8")
    for path in (stale / "1.json", stale):
        os.utime(path, (old, old))
    provider("after", folder)
    check("a queue untouched for 30 days is deleted, not sent", not stale.exists() and lines("uploaded.txt") == [])

    section("private queue")
    reset()
    made = provider("s1")
    control("fail")
    made.sync_turn("Private", "OK", session_id="s1", messages=conversation("Private"))
    (server_folder / "fail").unlink()
    if os.name == "nt":
        rights = subprocess.run(["icacls", str(made._root)], capture_output=True, text=True).stdout
        check("the folder is limited to this account", os.environ["USERNAME"] in rights and "(I)" not in rights and "Users" not in rights.replace(str(made._root), ""))
    else:
        check("the folder is readable by this account only", stat.S_IMODE(made._root.stat().st_mode) == 0o700)
        check("the files too", stat.S_IMODE(queue_files(made)[0].stat().st_mode) == 0o600)
    fingerprinted = made._root.name.removeprefix("membraince-queue-")
    check("the folder name holds a hash, never the key", "key-a" not in str(made._root) and len(fingerprinted) == 16)

    section("refusals")
    WORDS = {
        401: "MemBraince didn't accept your API key",
        402: "MemBraince memory is off until you subscribe",
        403: "MemBraince doesn't know the project",
        423: "This API key can't unlock your encrypted MemBraince memories",
        429: "This API key has reached a MemBraince limit",
    }
    for code, words in WORDS.items():
        reset()
        control("status", str(code))
        folder = home()
        warnings = []
        made = provider("s1", folder, warning_callback=warnings.append)
        block = made.system_prompt_block()
        check(f"{code}: no warning before a turn starts, when Hermes has nowhere to show it", warnings == [])
        answer = made.prefetch("hi")
        check(f"{code}: one warning for you, though several requests were refused",
              len(warnings) == 1 and warnings[0].startswith(words) and len(routes()) == 2)
        check(f"{code}: nothing recalled, and the model isn't told", RECALLED not in block and answer == "")
        tool = json.loads(made.handle_tool_call("membraince_recall", {"query": "x"}))
        check(f"{code}: a tool call says why", tool["error"].startswith(words))
        made.sync_turn("Waits", "OK", session_id="s1", messages=conversation("Waits"))
        check(f"{code}: what you type stays queued", len(queue_files(made)) == 1)
        made = provider("s2", folder, warning_callback=warnings.append)
        made.prefetch("again")
        check(f"{code}: the same problem isn't told again the same day", len(warnings) == 1)
    mark = made._root / "notice-429"
    os.utime(mark, (time.time() - 25 * 3600,) * 2)
    made = provider("s3", folder, warning_callback=warnings.append)
    made.prefetch("again")
    check("a day later it's told again", len(warnings) == 2)
    control("status", "401")
    made = provider("s4", folder, warning_callback=warnings.append)
    made.on_turn_start(1, "thanks")
    check("a different problem is told, also on a prompt Hermes doesn't recall for", len(warnings) == 3 and warnings[2].startswith(WORDS[401]))
    reset()
    control("status", "402")
    folder = home()
    warnings = []
    provider("s1", folder, warning_callback=warnings.append).shutdown()
    check("a session that never reached a turn leaves it untold", warnings == [])
    made = provider("s2", folder, warning_callback=warnings.append)
    made.on_turn_start(1, "thanks")
    check("so the next session tells it", len(warnings) == 1)
    reset()
    control("status", "429")
    warnings = []
    made = provider("s1", warning_callback=warnings.append)
    made.sync_turn("Refused save", "OK", session_id="s1", messages=conversation("Refused save"))
    made.on_turn_start(2, "next")
    check("a refused save is told at the next turn", len(warnings) == 1 and warnings[0].startswith(WORDS[429]))
    reset()
    control("status", "500")
    warnings = []
    made = provider("s1", warning_callback=warnings.append)
    check("a server error stays silent", made.prefetch("x") == "" and warnings == [])
    check("a tool call says it couldn't reach MemBraince", "couldn't be reached" in made.handle_tool_call("membraince_recall", {"query": "x"}))
    reset()
    control("status", "402")
    made = provider("s1", platform="telegram", chat_type="dm", chat_id="1")
    told = made.prefetch("hi")
    check("without a warning line, the model is asked to tell the user, in one line",
          told.startswith("MemBraince isn't working") and WORDS[402] in told and "\n" not in told)
    check("and only once", made.prefetch("again") == "")
    reset()
    broken = []
    def warn_fails(message):
        broken.append(message)
        raise RuntimeError("no terminal")
    control("status", "402")
    made = provider("s1", warning_callback=warn_fails)
    told = made.prefetch("hi")
    check("a warning line that fails falls back to the model", broken and WORDS[402] in told)

    section("group chats")
    reset()
    for chat in ({"chat_type": "group"}, {"chat_type": "channel"}, {"chat_type": "thread"}, {"chat_id": "42"}):
        made = provider("g1", platform="telegram", **chat)
        made.sync_turn("A friend's message", "OK", session_id="g1", messages=conversation("A friend's message", TERMINAL))
        results = (made.system_prompt_block(), made.prefetch("Anything"), made.get_tool_schemas(), made._root.exists())
        tool = json.loads(made.handle_tool_call("membraince_recall", {"query": "x"}))
        made.on_pre_compress(conversation("x"))
        made.on_session_switch("g2", reset=True)
        made.on_session_end([])
        made.shutdown()
        check(f"{chat}: memory is off: no request, prompt text, tools, or queue",
              results == ("", "", [], False) and "error" in tool and not routes())
    made = provider("d1", platform="telegram", chat_type="dm", chat_id="1")
    check("a direct message works normally", routes() == ["session-start"] and len(made.get_tool_schemas()) == 3)
    check("with no project folder", "cwd" not in sent("session-start")[0])
    made.sync_turn("Remember this", "OK", session_id="d1", messages=conversation("Remember this", TERMINAL))
    check("it saves the prompt, and learns no repository", lines("uploaded.txt") == ["key-a Remember this"])
    check("a messaging platform's private chat type counts too", len(provider("d2", platform="whatsapp", chat_type="private").get_tool_schemas()) == 3)

    section("project folder")
    runtime = types.ModuleType("agent.runtime_cwd")
    runtime.scope_terminal_cwd = lambda: "/w/hosted"
    sys.modules["agent.runtime_cwd"] = runtime
    reset()
    hosted = dict(platform="cli", chat_type="dm", chat_id="local-1", gateway_session_key="agent:main:local:dm:local-1")
    made = provider("h1", cwd="", **{k: v for k, v in hosted.items() if k != "platform"})
    check("a session a background Hermes hosts uses that session's folder, though it has a chat id", sent("session-start")[0]["cwd"].replace("\\", "/").endswith("/w/hosted"))
    runtime.scope_terminal_cwd = lambda: "/w/moved"
    made.prefetch("x")
    check("a session that moves to another folder follows it", sent("prompt")[-1]["cwd"].replace("\\", "/").endswith("/w/moved"))
    reset()
    runtime.scope_terminal_cwd = lambda: ""
    made = provider("h2", cwd="", **{k: v for k, v in hosted.items() if k != "platform"})
    check("a hosted session with no folder of its own has none", "cwd" not in sent("session-start")[0])
    reset()
    made = provider("h3", cwd="")
    check("a plain terminal session uses the folder it started in", sent("session-start")[0]["cwd"] == os.getcwd())
    reset()
    runtime.scope_terminal_cwd = lambda: "/w/gateway-home"
    made = provider("h4", platform="telegram", chat_type="dm", chat_id="1")
    check("a messaging session's configured folder isn't a project", "cwd" not in sent("session-start")[0])
    del sys.modules["agent.runtime_cwd"]

    section("who saves")
    for context in ({"agent_context": "cron"}, {"agent_context": "subagent"}, {"agent_context": "flush"}, {"platform": "cron"}):
        reset()
        made = provider("c1", **context)
        made.sync_turn("Scheduled", "OK", session_id="c1", messages=conversation("Scheduled"))
        made.on_session_end([])
        check(f"{context}: recalls, but saves nothing", RECALLED in made.prefetch("x") and not lines("uploaded.txt") and "transcript" not in routes())
    reset()
    made = provider("b1")
    made.sync_turn("From a bot", "OK", session_id="b1", messages=conversation("From a bot"), turn_author={"id": "9", "name": "bot", "is_bot": True})
    check("a turn another bot wrote isn't saved", not lines("uploaded.txt"))

    section("settings")
    reset()
    made = provider("o1", env={"MEMBRAINCE_LEARN_CODE": "false"})
    made.sync_turn("Prompt only", "OK", session_id="o1", messages=conversation("Prompt only", READ))
    check("Learn the repository off sends the prompt alone", lines("uploaded.txt") == ["key-a Prompt only"])
    reset()
    made = provider("o1", env={"MEMBRAINCE_AUTO_SAVE": "false"})
    made.sync_turn("Not saved", "OK", session_id="o1", messages=conversation("Not saved", READ))
    made.on_session_end([])
    check("automatic save off queues and sends nothing", not made._root.exists() and "transcript" not in routes())
    reset()
    made = provider("o1", env={"MEMBRAINCE_AUTO_RECALL": "false"})
    check("automatic recall off sends no recall", made.prefetch("x") == "" and routes() == [])
    check("and tells the model to ask", "At the start of a task" in made.system_prompt_block() and "added to this conversation" not in made.system_prompt_block())
    reset()
    made = provider("o1", env={"MEMBRAINCE_USER": "dana", "MEMBRAINCE_PROJECT": "ledger", "MEMBRAINCE_URL": URL + "/v1/mcp/"})
    headers = {key.lower(): value for key, value in requests()[0]["headers"].items()}
    check("memory owner and project go along, and a server URL ending in /v1/mcp/ works",
          headers["x-membraince-user"] == "dana" and headers["x-membraince-project"] == "ledger" and routes() == ["session-start"])
    project_queue = made._root
    made = provider("o2", env={"MEMBRAINCE_USER": "eve", "MEMBRAINCE_PROJECT": "ledger"})
    check("another memory owner has its own queue", project_queue.name != made._root.name)
    made = plugin.MemBrainceProvider()
    reset()
    outside = home()
    (outside / "stray.json").write_text("{}\n", encoding="utf-8")
    previous = os.getcwd()
    os.chdir(outside)
    try:
        made.on_session_end([])
        made.shutdown()
    finally:
        os.chdir(previous)
    check("a provider Hermes never initialized sends nothing and leaves files alone", not routes() and (outside / "stray.json").exists())

    section("session changes")
    reset()
    folder = home()
    made = provider("s1", folder)
    made.system_prompt_block()
    control("fail")
    made.sync_turn("Before the switch", "OK", session_id="s1", messages=conversation("Before the switch"))
    (server_folder / "fail").unlink()
    made.on_session_switch("s2", parent_session_id="s1", reset=False, reason="compression")
    settle(made)
    check("compaction starts a new session id without recalling again: the system prompt keeps what it had",
          routes().count("session-start") == 1 and RECALLED in made.system_prompt_block())
    check("the old session's queue is sent", lines("uploaded.txt") == ["key-a Before the switch"])
    made.prefetch("x", session_id="s2")
    check("recall uses the new id", sent("prompt")[-1]["session_id"] == "s2")
    made.on_session_switch("s3", reset=True)
    settle(made)
    check("a new conversation recalls again", routes().count("session-start") == 2 and sent("session-start")[-1]["session_id"] == "s3")
    made.on_session_switch("s3", rewound=True)
    settle(made)
    check("rewinding the same session doesn't", routes().count("session-start") == 2)

    section("memory tools")
    reset()
    made = provider("t1")
    check("three tools, named for Hermes", [schema["name"] for schema in made.get_tool_schemas()] == ["membraince_recall", "membraince_remember", "membraince_forget"])
    check("each describes its arguments", all(schema["parameters"]["required"] for schema in made.get_tool_schemas()))
    reset()
    for name, args, sent_name in (("membraince_recall", {"query": "deploy"}, "recall"),
                                  ("membraince_remember", {"content": "Dana likes tea"}, "remember"),
                                  ("membraince_forget", {"memory_id": "m1"}, "forget")):
        answer = json.loads(made.handle_tool_call(name, args))
        call = json.loads(requests()[-1]["body"])
        check(f"{name} calls {sent_name} on /v1/mcp",
              answer == {"result": f"tool {sent_name}"} and requests()[-1]["path"] == "/v1/mcp"
              and call["method"] == "tools/call" and call["params"] == {"name": sent_name, "arguments": args})
    control("tool-error")
    check("a tool's error result comes back as an error", json.loads(made.handle_tool_call("membraince_recall", {"query": "x"})) == {"error": "tool recall"})
    (server_folder / "tool-error").unlink()
    check("an unknown tool is refused without a request", "error" in json.loads(made.handle_tool_call("other", {})) and len(routes()) == 4)
    made._base = "http://127.0.0.1:9"
    check("a server that can't be reached is an error, not a crash", "couldn't be reached" in made.handle_tool_call("membraince_recall", {"query": "x"}))
    made.system_prompt_block()
    check("and recall adds nothing", made.prefetch("x") == "")

    section("threads")
    reset()
    made = provider("t1")
    barrier = threading.Barrier(8)
    def turn(number):
        barrier.wait()
        made.sync_turn(f"Prompt {number}", "OK", session_id="t1", messages=conversation(f"Prompt {number}"))
    workers = [threading.Thread(target=turn, args=(number,)) for number in range(8)]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join(30)
    made.on_session_end([])
    uploaded = sorted(line.split()[-1] for line in lines("uploaded.txt"))
    check("prompts arriving together are each sent once", uploaded == sorted(str(number) for number in range(8)) and queue_files(made) == [])
finally:
    shutil.rmtree(work, ignore_errors=True)
    server.wait(timeout=10)

print(f"{failures} Hermes test(s) failed" if failures else "all Hermes tests passed")
sys.exit(1 if failures else 0)
