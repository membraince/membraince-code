# Tests

Hook tests run each integration's real hook scripts against `fake_server.py`, a stand-in for
MemBraince that records every uploaded prompt and can be told to fail. They check that prompts are
queued and sent exactly once, that failed saves keep their prompts, that locks are respected and
cleared only when their owner is gone, that a later session sends prompts an earlier one couldn't
(only with the same key, to the same server), that a save whose answer is lost is resent with the
same line ids, that a file that can't be read stops the save before anything is sent or deleted,
that the queue folder is private to your account (including on Windows), that session start
finishes inside its time limit with a slow server, that 30-day-old queues are deleted, that 60
prompts arriving during overlapping and failing saves are each sent exactly once, and that a refused
key makes session start show one warning a day while the queue waits.

```bash
bash tests/hooks.sh
```

On Windows, also run the PowerShell hook's tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/hooks.ps1
```

They need `bash`, `curl`, and Python 3. CI runs them on Linux, macOS, and Windows.

The OpenCode plugin's tests need Node 18 or later:

```bash
node tests/opencode.mjs
```

The Hermes plugin's tests run the plugin against `fake_server.py` with a small stand-in for the base class
Hermes gives it, so they need only Python 3:

```bash
python tests/hermes.py
```
