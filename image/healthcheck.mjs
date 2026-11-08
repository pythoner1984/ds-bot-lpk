// Health probe for the platform: the proxy has to answer its own health path,
// and dsh has to be listening behind it. Caddy's /healthz answers 200 even when
// dsh is in a crash loop, which is exactly the state that needs a restart.
import { request } from 'node:http'

const probe = (port, path) =>
  new Promise((resolve) => {
    const req = request({ host: '127.0.0.1', port, path, timeout: 4000 }, (res) => {
      res.resume()
      resolve(res.statusCode ?? 0)
    })
    req.on('error', () => resolve(0))
    req.on('timeout', () => {
      req.destroy()
      resolve(0)
    })
    req.end()
  })

const proxy = await probe(3080, '/healthz')
if (proxy !== 200) {
  console.error(`proxy answered ${proxy} on /healthz`)
  process.exit(1)
}

// Any HTTP answer means dsh is up; 401 is the normal unauthenticated reply.
if ((await probe(3081, '/')) === 0) {
  console.error('dsh is not listening on 3081')
  process.exit(1)
}
