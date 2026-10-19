// MemBraince for OpenCode: automatic recall and save.
//
// Recall: when you send a message, memories related to the project (first
// message of a session) and to the message are added to the system prompt.
// Save: when a session goes idle, the messages you typed since the last save
// are sent as one save, at most once every SAVE_INTERVAL_MS per session, and
// again when a session is compacted. OpenCode's replies and tool output are
// never sent. Every failure is silent, so MemBraince never blocks a session.
//
// The memory tools themselves come from the MCP server entry in opencode.json.

const BASE = (process.env.MEMBRAINCE_URL || "https://membraince.com").replace(/\/+$/, "")
const SAVE_INTERVAL_MS = 15 * 60 * 1000
const TIMEOUT_MS = 8000

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

  const post = async (path, body) => {
    try {
      const response = await fetch(`${BASE}/v1/integrations/opencode/${path}`, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      })
      return response.ok ? await response.text() : ""
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
