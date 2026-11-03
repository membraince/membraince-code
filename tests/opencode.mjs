// Tests for the OpenCode plugin (integrations/opencode/membraince.js) against a stand-in for
// MemBraince that answers recall with a fixed line, or with the status in `status` when it is set,
// and a stand-in OpenCode client that records toasts. Run from the repository root: node tests/opencode.mjs
import http from "node:http"

let status = 0
const requests = []
const server = http.createServer((req, res) => {
  let body = ""
  req.on("data", (chunk) => (body += chunk))
  req.on("end", () => {
    requests.push({ path: req.url, body })
    if (status) {
      res.writeHead(status, { "Content-Type": "application/json" })
      return res.end('{"detail":"request cannot be admitted"}')
    }
    res.writeHead(200, { "Content-Type": "text/plain" })
    res.end(req.url.endsWith("/messages") ? '{"saved":1}' : "Memories from MemBraince: (test)")
  })
})
console.log("== opencode")
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
process.env.MEMBRAINCE_URL = `http://127.0.0.1:${server.address().port}`
process.env.MEMBRAINCE_API_KEY = "key-a"
const { MemBraince } = await import(new URL("../integrations/opencode/membraince.js", import.meta.url))

const toasts = []
const client = {
  tui: { showToast: async ({ body }) => toasts.push(body) },
  session: { messages: async () => ({ data: [] }) },
}
const hooks = await MemBraince({ client, directory: "/w/app" })
let failures = 0
const check = (description, ok) => {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${description}`)
  if (!ok) failures++
}
const send = async (sessionID, text) => {
  await hooks["chat.message"]({ sessionID }, { parts: [{ type: "text", text }] })
  const output = { system: [] }
  await hooks["experimental.chat.system.transform"]({ sessionID }, output)
  return output.system
}

check("a message gets what recall returns", JSON.stringify(await send("s1", "hi")) === JSON.stringify(["Memories from MemBraince: (test)\n\nMemories from MemBraince: (test)"]))
check("no warning while MemBraince accepts the key", toasts.length === 0)
status = 402
const refused = await send("s2", "hi")
check("a refused key adds nothing to the system prompt", refused.length === 0)
check("a refused key shows one warning, though two requests were refused", toasts.length === 1 && toasts[0].variant === "warning" && toasts[0].message.startsWith("MemBraince memory is off until you subscribe"))
await send("s3", "again")
check("the same refusal again the same day shows nothing", toasts.length === 1)
status = 401
await send("s3", "again")
check("a different refusal is told", toasts.length === 2 && toasts[1].message.startsWith("MemBraince didn't accept your API key"))
status = 500
await send("s4", "x")
check("a server error stays silent", toasts.length === 2)
const noToasts = await MemBraince({ client: { session: client.session }, directory: "/w/app" })
status = 423
await noToasts["chat.message"]({ sessionID: "s5" }, { parts: [{ type: "text", text: "x" }] })
check("a client without toasts doesn't break the plugin", true)
server.close()
console.log(failures ? `${failures} OpenCode test(s) failed` : "all OpenCode tests passed")
process.exit(failures)
