---
name: memory
description: Look up, add, correct, or remove what MemBraince remembers. Use when the user asks what you remember, asks you to remember something, or says a remembered fact is wrong.
---

MemBraince is the user's long-term memory. Use the `membraince` MCP server's tools:

1. **Looking something up.** Call `recall` with a short description of what you need. Summarize what comes back in your own words and say so plainly when nothing matches.
2. **Saving something.** Call `remember` once per fact. Write each one so it stands alone later: full names, the project it belongs to, and dates where they matter.
3. **Fixing something.** `recall` it to get the memory id, `forget` that id, then `remember` the corrected version. Tell the user what changed.

Don't save secrets such as passwords, API keys, or tokens, even if asked; explain that memory isn't the place for them.
