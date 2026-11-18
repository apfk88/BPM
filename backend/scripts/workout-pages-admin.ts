// Operator CLI. Uses existing server environment credentials; no public admin HTTP endpoint.
import { kv } from '@vercel/kv';
import { PAGE_PREFIX, WorkoutPages } from '../lib/workout-pages';
import { privateWorkoutBlobs } from '../lib/workout-page-runtime';

async function main() {
  const [action, argument] = process.argv.slice(2);
  const pages = new WorkoutPages(kv, privateWorkoutBlobs);
  switch (action) {
    case 'usage': console.log(JSON.stringify(await pages.usage(argument), null, 2)); return;
    case 'cleanup': console.log(JSON.stringify(await pages.cleanup(100))); return;
    case 'remove': await pages.moderate(argument); console.log('Page removed.'); return;
    case 'block': await pages.moderate(argument, true); console.log('Page removed and uploader blocked.'); return;
    case 'pause': await kv.set(`${PAGE_PREFIX}uploads-paused`, '1'); console.log('New uploads paused.'); return;
    case 'resume': await kv.del(`${PAGE_PREFIX}uploads-paused`); console.log('New uploads resumed.'); return;
    default: throw new Error('Usage: workout-pages-admin usage [YYYY-MM] | cleanup | remove PAGE_ID | block PAGE_ID | pause | resume');
  }
}
void main().catch(() => { console.error('Operation failed. Verify the command and server environment configuration.'); process.exitCode = 1; });
