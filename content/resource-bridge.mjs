#!/usr/bin/env node
// Ticket bridge for the platform's imported MCP providers.
//
// The box injects `X-HC-USER-TICKET` into requests a real person makes through
// the platform entry; there is no API to mint one. Caddy logs every request, so
// the ticket is read back out of that log and attached here, on the box's side
// of the fence, while the request goes to `http://app.<package-id>.lzcx<endpoint>`.
//
// MCP providers are called as:  /p/<package-id>/<endpoint-path>
// The package id is everything up to the first path segment after /p/, so
// `cloud.lazycat.shell.files` and `wx.clawbot.lazycat.app.mediasaber` both work.

import { createReadStream } from 'node:fs'
import { readFile, stat } from 'node:fs/promises'
import { createServer, request as httpRequest } from 'node:http'

const PORT = Number(process.env.RESOURCE_BRIDGE_PORT || 3092)
const HOST = '127.0.0.1'
const LOG_FILE = process.env.RESOURCE_LOG || '/data/proxy.log'
const TICKET_FILE = process.env.RESOURCE_TICKET_FILE || '/data/run/ticket'
const TICKET_TTL_MS = 10 * 60_000
const LOG_SCAN_BYTES = 512 * 1024

const FORWARD = new Set([
  'content-type',
  'accept',
  'accept-language',
  'user-agent',
  'mcp-session-id',
  'mcp-protocol-version',
  'mcp-method',
  'last-event-id',
  'cache-control',
])

let cached = { ticket: '', at: 0 }

const note = (message) => process.stdout.write(`[bridge] ${message}\n`)

async function fromFile() {
  try {
    return (await readFile(TICKET_FILE, 'utf8')).trim()
  } catch {
    return ''
  }
}

async function fromLog() {
  let handle
  try {
    const info = await stat(LOG_FILE)
    const start = Math.max(0, info.size - LOG_SCAN_BYTES)
    handle = createReadStream(LOG_FILE, { start, encoding: 'utf8' })
    let text = ''
    for await (const chunk of handle) text += chunk
    handle = undefined
    // Caddy's json log keeps headers as { name: [values] }; take the newest one.
    const matches = [...text.matchAll(/"X-Hc-User-Ticket":\s*\[\s*"([^"]+)"/g)]
    return matches.length === 0 ? '' : matches[matches.length - 1][1]
  } catch {
    return ''
  } finally {
    handle?.destroy()
  }
}

async function ticket() {
  const now = Date.now()
  if (cached.ticket !== '' && now - cached.at < TICKET_TTL_MS) return cached.ticket
  const found = (await fromFile()) || (await fromLog())
  if (found !== '') {
    if (found !== cached.ticket) note('learned a fresh user ticket')
    cached = { ticket: found, at: now }
  }
  return found
}

function forwardHeaders(headers, ticketValue, upstreamHost) {
  const out = {}
  for (const [name, value] of Object.entries(headers)) {
    const lower = name.toLowerCase()
    if (FORWARD.has(lower) && value !== undefined) out[lower] = value
  }
  out.host = upstreamHost
  if (ticketValue !== '') out['x-hc-user-ticket'] = ticketValue
  return out
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://${HOST}:${PORT}`)
  const parts = url.pathname.split('/').filter(Boolean)
  if (parts[0] !== 'p' || parts.length < 3) {
    res.writeHead(404, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ error: 'use /p/<package-id>/<endpoint>' }))
    return
  }
  const packageId = parts[1]
  const endpoint = `/${parts.slice(2).join('/')}${url.search}`
  const upstreamHost = `app.${packageId}.lzcx`
  const ticketValue = await ticket()
  if (ticketValue === '') {
    note(`no ticket yet for ${packageId}`)
    res.writeHead(503, { 'content-type': 'application/json' })
    res.end(JSON.stringify({
      error: 'no user ticket captured yet',
      hint: 'open the app once in a browser so the platform injects X-HC-USER-TICKET, then retry',
    }))
    return
  }

  const upstream = httpRequest(
    { host: '172.18.0.1', port: 80, method: req.method, path: endpoint, headers: forwardHeaders(req.headers, ticketValue, upstreamHost) },
    (answer) => {
      const headers = { ...answer.headers }
      res.writeHead(answer.statusCode ?? 502, headers)
      answer.pipe(res)
    },
  )
  upstream.on('error', (error) => {
    note(`upstream error for ${packageId}: ${error.message}`)
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ error: `upstream unreachable: ${error.message}` }))
  })
  req.pipe(upstream)
})

server.listen(PORT, HOST, () => note(`listening on http://${HOST}:${PORT}`))
