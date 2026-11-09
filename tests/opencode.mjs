// Tests for the OpenCode plugin (integrations/opencode/membraince.js) against a stand-in for
// MemBraince that answers recall with a fixed line, or with the status in `status` when it is set,
// and a stand-in OpenCode client that records toasts. Run from the repository root: node tests/opencode.mjs
import fs from "node:fs"
import http from "node:http"
import os from "node:os"
import path from "node:path"

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

const config = { mcp: { other: { type: "local", command: ["x"] } } }
await hooks.config(config)
check("the plugin adds the memory tools' server next to the ones already configured", config.mcp.other && config.mcp.membraince.url === `${process.env.MEMBRAINCE_URL}/v1/mcp` && config.mcp.membraince.headers["X-API-Key"] === "key-a" && config.mcp.membraince.oauth === false)
const own = { mcp: { membraince: { type: "remote", url: "https://example.test/mcp" } } }
await hooks.config(own)
check("a membraince entry already in opencode.json is left alone", own.mcp.membraince.url === "https://example.test/mcp")
const bare = {}
await hooks.config(bare)
check("a configuration with no servers gets the memory tools' server", bare.mcp.membraince.type === "remote")

// With no MEMBRAINCE_API_KEY, the key comes from the file the installer writes.
const home = fs.mkdtempSync(path.join(os.tmpdir(), "membraince-opencode-"))
const before = { HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE }
process.env.HOME = process.env.USERPROFILE = home
delete process.env.MEMBRAINCE_API_KEY
check("with no key anywhere the plugin does nothing", Object.keys(await MemBraince({ client, directory: "/w/app" })).length === 0)
fs.mkdirSync(path.join(home, ".config", "membraince"), { recursive: true })
fs.writeFileSync(path.join(home, ".config", "membraince", "api-key"), "key-from-file\n")
const fromFile = {}
await (await MemBraince({ client, directory: "/w/app" })).config(fromFile)
check("the saved key file is used when MEMBRAINCE_API_KEY isn't set", fromFile.mcp.membraince.headers["X-API-Key"] === "key-from-file")
Object.assign(process.env, before)
process.env.MEMBRAINCE_API_KEY = "key-a"
fs.rmSync(home, { recursive: true, force: true })

const noToasts = await MemBraince({ client: { session: client.session }, directory: "/w/app" })
status = 423
await noToasts["chat.message"]({ sessionID: "s5" }, { parts: [{ type: "text", text: "x" }] })
check("a client without toasts doesn't break the plugin", true)
server.close()
console.log(failures ? `${failures} OpenCode test(s) failed` : "all OpenCode tests passed")
process.exit(failures)
