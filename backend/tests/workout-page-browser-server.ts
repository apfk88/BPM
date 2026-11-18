// Local-only browser integration harness. It is not imported by any application route.
// Uses isolated real Redis, memory-backed private objects, and the production HTTP router.
import { createServer, request } from 'node:http';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createBody, handleTestAPI, testEnvironment, testKey } from './workout-page-test-support';

async function main() {
  if (process.env.VERCEL || process.env.NODE_ENV === 'production') throw new Error('Browser fixture server is restricted to local development');
  const env = await testEnvironment();
  const owner = testKey(), body = createBody();
  const metadata = await env.pages.create(owner, body);
  const port = Number(process.env.BPM_WORKOUT_TEST_PORT || 3014);
  const webPort = Number(process.env.BPM_WORKOUT_WEB_PORT || 3013);
  const server = createServer((req, res) => {
    if (req.url?.startsWith('/api/workout-pages')) { handleTestAPI(env.handler, req, res); return; }
    const proxy = request({ hostname: '127.0.0.1', port: webPort, method: req.method, path: req.url,
      headers: { ...req.headers, host: `127.0.0.1:${webPort}` } }, upstream => {
      res.writeHead(upstream.statusCode || 502, upstream.headers); upstream.pipe(res);
    });
    proxy.on('error', () => { res.statusCode = 502; res.end('Start the local Next.js viewer first.'); });
    req.pipe(proxy);
  });
  await new Promise<void>(resolveListen => server.listen(port, '127.0.0.1', resolveListen));
  const fixture = { url: `http://127.0.0.1:${port}/w/${metadata.linkCode}#${body.viewKey}`,
    legacyURL: `http://127.0.0.1:${port}/w/${body.pageID}#${body.viewKey}`, linkCode: metadata.linkCode, ownerKey: owner,
    pageID: body.pageID, viewKey: body.viewKey, apiURL: `http://127.0.0.1:${port}/api/workout-pages/${body.pageID}` };
  const fixturePath = resolve(process.env.BPM_WORKOUT_FIXTURE_PATH || '/private/tmp/bpm-workout-page-browser-fixture.json');
  await writeFile(fixturePath, JSON.stringify(fixture, null, 2), { mode: 0o600 });
  console.log(`Synthetic workout viewer: ${fixture.url}`);
  console.log(`Synthetic management fixture: ${fixturePath}`);
  const stop = async () => { server.closeAllConnections(); server.close(); await env.stop(); process.exit(0); };
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
}
void main().catch(error => { console.error(error.message); process.exitCode = 1; });
