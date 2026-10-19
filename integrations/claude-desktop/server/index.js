#!/usr/bin/env node
// MemBraince for Claude Desktop: a stdio-to-HTTP bridge. Claude Desktop speaks
// MCP over stdin/stdout (one JSON-RPC message per line); MemBraince serves MCP
// over HTTP at /v1/mcp. Each message is forwarded as one POST and the reply is
// written back as one line. No dependencies: Node 18+ ships fetch.
"use strict";

const readline = require("node:readline");

const url = process.env.MEMBRAINCE_URL || "https://membraince.com/v1/mcp";
const headers = {
  "Content-Type": "application/json",
  Accept: "application/json, text/event-stream",
  "X-API-Key": process.env.MEMBRAINCE_API_KEY || "",
  "X-MemBraince-User": process.env.MEMBRAINCE_USER || "default",
};
if (process.env.MEMBRAINCE_PROJECT) headers["X-MemBraince-Project"] = process.env.MEMBRAINCE_PROJECT;

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

function fail(id, message) {
  if (id !== undefined && id !== null) {
    send({ jsonrpc: "2.0", id, error: { code: -32603, message } });
  }
}

async function forward(line) {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
  }
  try {
    const response = await fetch(url, { method: "POST", headers, body: line });
    if (response.status === 202) return; // notification accepted, nothing to answer
    if (response.status === 401) return fail(message.id, "MemBraince rejected the API key. Check it in the extension settings.");
    if (!response.ok) return fail(message.id, `MemBraince returned HTTP ${response.status}.`);
    send(await response.json());
  } catch (error) {
    fail(message.id, `Could not reach MemBraince: ${error.message}`);
  }
}

if (!headers["X-API-Key"]) {
  process.stderr.write("MemBraince: no API key configured; requests will be rejected.\n");
}
readline
  .createInterface({ input: process.stdin, terminal: false })
  .on("line", (line) => {
    if (line.trim()) forward(line);
  });
