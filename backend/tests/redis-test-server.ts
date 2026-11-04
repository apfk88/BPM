import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createConnection } from 'node:net';
import type { ShareRedis } from '../lib/share-workout';

const binary = process.env.BPM_TEST_REDIS_SERVER || 'redis-server';
export const redisTestAvailable = spawnSync(binary, ['--version'], { stdio: 'ignore' }).status === 0;

// Exercise the production Lua against a real, isolated Redis without npm test
// dependencies or access to any configured KV credentials.
export async function startRedisTestServer(): Promise<ShareRedis & {
  command(...args: (string | number)[]): Promise<any>;
  stop(): Promise<void>;
}> {
  const directory = await mkdtemp(join(tmpdir(), 'bpm-share-redis-'));
  const socketPath = join(directory, 'redis.sock');
  const child = spawn(binary, ['--port', '0', '--unixsocket', socketPath, '--save', '', '--appendonly', 'no'], { stdio: 'ignore' });

  async function command(...args: (string | number)[]): Promise<any> {
    return new Promise((resolve, reject) => {
      const socket = createConnection(socketPath);
      let bytes = Buffer.alloc(0);
      socket.on('error', reject);
      socket.on('connect', () => {
        const encoded = args.map(value => {
          const string = String(value);
          return `$${Buffer.byteLength(string)}\r\n${string}\r\n`;
        });
        socket.write(`*${args.length}\r\n${encoded.join('')}`);
      });
      socket.on('data', data => {
        bytes = Buffer.concat([bytes, data]);
        try {
          const parsed = parseReply(bytes, 0);
          if (parsed) { socket.end(); resolve(parsed.value); }
        } catch (error) { socket.destroy(); reject(error); }
      });
    });
  }

  for (let attempt = 0; ; attempt++) {
    try { await command('PING'); break; } catch (error) {
      if (attempt >= 100 || child.exitCode !== null) {
        child.kill();
        await rm(directory, { recursive: true, force: true });
        throw error;
      }
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  }
  return {
    command,
    get: key => command('GET', key),
    eval: (script, keys, args) => command('EVAL', script, keys.length, ...keys, ...args.map(String)),
    stop: async () => {
      const exited = new Promise<void>(resolve => child.once('exit', () => resolve()));
      child.kill('SIGTERM');
      await exited;
      await rm(directory, { recursive: true, force: true });
    },
  };
}

function parseReply(bytes: Buffer, offset: number): { value: any; end: number } | null {
  const lineEnd = bytes.indexOf('\r\n', offset);
  if (lineEnd < 0) return null;
  const line = bytes.toString('utf8', offset + 1, lineEnd);
  const next = lineEnd + 2;
  switch (String.fromCharCode(bytes[offset])) {
    case '+': return { value: line, end: next };
    case '-': throw new Error(line);
    case ':': return { value: Number(line), end: next };
    case '$': {
      const length = Number(line);
      if (length === -1) return { value: null, end: next };
      if (bytes.length < next + length + 2) return null;
      return { value: bytes.toString('utf8', next, next + length), end: next + length + 2 };
    }
    case '*': {
      const length = Number(line);
      if (length === -1) return { value: null, end: next };
      const values = [];
      let cursor = next;
      for (let i = 0; i < length; i++) {
        const item = parseReply(bytes, cursor);
        if (!item) return null;
        values.push(item.value);
        cursor = item.end;
      }
      return { value: values, end: cursor };
    }
    default: throw new Error('Unsupported Redis test reply');
  }
}
