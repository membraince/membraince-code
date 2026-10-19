---
name: memory
description: Review, correct, or clean up what MemBraince remembers about the user. Use when the user asks what you remember, wants a memory changed or forgotten, or asks you to remember something specific.
---

MemBraince stores the user's long-term memory. Its tools are `recall`, `remember`, and `forget` on the `membraince` MCP server.

- **"What do you remember about X?"** Call `recall` with X, then summarize the results in plain language. Mention when nothing was found instead of guessing.
- **"Remember that ..."** Call `remember` with one self-contained statement per fact. Spell out names and dates so the memory still makes sense out of context.
- **"That's wrong"** Call `recall` to find the memory and its id. `remember` the corrected statement first, and only once that succeeds, `forget` the old memory, so a failure never leaves the user with neither. Confirm what changed.
- **"Forget that"** Call `recall` to find the memory and its id, then `forget` it and confirm.
- Never store passwords, API keys, tokens, or other secrets, even when asked. Say why instead.
