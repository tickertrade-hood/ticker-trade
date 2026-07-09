'use strict';
// TICKER.TRADE on Robinhood Chain — static UI server, port 8757. Zero deps.
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 8757;
const ROOT = __dirname;
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.ico': 'image/x-icon', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };

http.createServer((req, res) => {
  let p = new URL(req.url, 'http://x').pathname;
  if (p === '/') p = '/index.html';
  const fp = path.normalize(path.join(ROOT, p));
  // must be ROOT itself or strictly inside it (trailing sep prevents sibling-prefix escape)
  if (fp !== ROOT && !fp.startsWith(ROOT + path.sep)) { res.writeHead(403); return res.end(); }
  fs.readFile(fp, (err, data) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(fp)] || 'application/octet-stream',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
      // defense-in-depth vs XSS: only same-origin scripts (ethers is vendored locally)
      'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src *; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'",
    });
    res.end(data);
  });
}).on('error', e => {
  if (e.code === 'EADDRINUSE') { console.log('[ticker-web] already running on :' + PORT); process.exit(0); }
  throw e;
}).listen(PORT, () => console.log(`[ticker-rh] TICKER.TRADE (Robinhood Chain) UI at http://localhost:${PORT}`));
