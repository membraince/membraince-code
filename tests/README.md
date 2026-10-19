# Tests

Hook tests run each integration's real hook scripts against `fake_server.py`, a stand-in for
MemBraince that records every uploaded prompt and can be told to fail. They check that prompts are
queued and sent exactly once, that failed saves keep their prompts, that locks are respected and
cleared only when their owner is gone, that a later session sends prompts an earlier one couldn't
(and only with the same key), that 30-day-old queues are deleted, and that 60 prompts arriving
during overlapping and failing saves are each sent exactly once.

```bash
bash tests/hooks.sh
```

On Windows, also run the PowerShell hook's tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/hooks.ps1
```

They need `bash`, `curl`, and Python 3. CI runs them on Linux, macOS, and Windows.
