// MemBraince for OpenCode: automatic recall and save.
//
// Recall: when you send a message, memories related to the project (first
// message of a session) and to the message are added to the system prompt.
// Save: when a session goes idle, the messages you typed since the last save
// are sent as one save, at most once every SAVE_INTERVAL_MS per session, and
// again when a session is compacted. OpenCode's replies and tool output are
// never sent. A failure never blocks a session. When MemBraince refuses the key
// (no subscription, a limit reached, ...), a warning tells you why, at most
// once a day per problem; the model never sees it.
//
// The memory tools themselves come from the MCP server entry in opencode.json.

const BASE = (process.env.MEMBRAINCE_URL || "https://membraince.com").replace(/\/+$/, "")
const SAVE_INTERVAL_MS = 15 * 60 * 1000
const TIMEOUT_MS = 8000
const NOTICE_INTERVAL_MS = 24 * 60 * 60 * 1000
const REFUSALS = {
  401: "MemBraince didn't accept your API key, so memory is off. Check MEMBRAINCE_API_KEY, or create a new key at https://membraince.com/portal.",
  402: "MemBraince memory is off until you subscribe at https://membraince.com/portal.",
  403: "MemBraince doesn't know the project in MEMBRAINCE_PROJECT for this key. Use a project name from https://membraince.com/portal, or leave it unset.",
  423: "This API key can't unlock your encrypted MemBraince memories. Create a new key at https://membraince.com/portal and put it in MEMBRAINCE_API_KEY.",
  429: "This API key has reached a MemBraince limit, so memory is paused. Usage is on https://membraince.com/portal.",
}

export const MemBraince = async ({ client, directory }) => {
  const key = process.env.MEMBRAINCE_API_KEY
  if (!key) return {}
  const autoRecall = process.env.MEMBRAINCE_AUTO_RECALL !== "false"
  const autoSave = process.env.MEMBRAINCE_AUTO_SAVE !== "false"
  const headers = {
    "Content-Type": "application/json",
    "X-API-Key": key,
    "X-MemBraince-User": process.env.MEMBRAINCE_USER || "default",
    "X-MemBraince-Project": process.env.MEMBRAINCE_PROJECT || "",
  }
  const started = new Set()
  const memories = new Map()
  const lastSave = new Map()
  const told = new Map()

  const notice = async (status) => {
    const message = REFUSALS[status]
    const now = Date.now()
    if (!message || now - (told.get(status) || 0) < NOTICE_INTERVAL_MS) return
    told.set(status, now)
    try {
      await client.tui.showToast({ body: { message, variant: "warning" } })
    } catch {
      // Not every OpenCode client shows toasts.
    }
  }

  const post = async (path, body) => {
    try {
      const response = await fetch(`${BASE}/v1/integrations/opencode/${path}`, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      })
      if (response.ok) return await response.text()
      await notice(response.status)
      return ""
    } catch {
      return ""
    }
  }

  const save = async (sessionID, force) => {
    const now = Date.now()
    if (!force && now - (lastSave.get(sessionID) || 0) < SAVE_INTERVAL_MS) return
    lastSave.set(sessionID, now)
    try {
      const result = await client.session.messages({ path: { id: sessionID } })
      const messages = (result.data || [])
        .filter((message) => message.info.role === "user")
        .map((message) => ({
          id: message.info.id,
          time: new Date(message.info.time.created).toISOString(),
          text: message.parts
            .filter((part) => part.type === "text" && !part.synthetic && !part.ignored)
            .map((part) => part.text)
            .join("\n"),
        }))
        .filter((message) => message.text.trim())
      if (messages.length) await post("messages", { session_id: sessionID, cwd: directory, messages })
    } catch {
      // Saving is best effort; the next idle period tries again.
    }
  }

  return {
    "chat.message": async (input, output) => {
      if (!autoRecall) return
      const prompt = output.parts
        .filter((part) => part.type === "text" && !part.synthetic)
        .map((part) => part.text)
        .join("\n")
      const found = []
      if (!started.has(input.sessionID)) {
        started.add(input.sessionID)
        found.push(await post("session-start", { cwd: directory }))
      }
      found.push(await post("prompt", { prompt }))
      memories.set(input.sessionID, found.filter(Boolean).join("\n\n"))
    },
    "experimental.chat.system.transform": async (input, output) => {
      const text = input.sessionID && memories.get(input.sessionID)
      if (text) output.system.push(text)
    },
    event: async ({ event }) => {
      if (!autoSave) return
      if (event.type === "session.idle") await save(event.properties.sessionID, false)
      if (event.type === "session.compacted") await save(event.properties.sessionID, true)
    },
  }
}
