---
name: memory
description: Look up, add, correct, or remove what MemBraince remembers. Use when the user asks what you remember, asks you to remember something, or says a remembered fact is wrong.
---

MemBraince is the user's long-term memory. Use its tools:

1. **Looking something up.** Call `membraince_recall` with a short description of what you need. Summarize what comes back in your own words and say so plainly when nothing matches.
2. **Saving something.** Call `membraince_remember` once per fact. Write each one so it stands alone later: full names, the project it belongs to, and dates where they matter.
3. **Fixing something.** `membraince_recall` it to get the memory id, `membraince_remember` the corrected version, and only after that succeeds, `membraince_forget` the old id, so a failure never loses both. Tell the user what changed.
4. **Removing something.** `membraince_recall` it to get the memory id, `membraince_forget` it, and confirm.

Don't save secrets such as passwords, API keys, or tokens, even if asked; explain that memory isn't the place for them.
