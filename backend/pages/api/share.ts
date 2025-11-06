import { NextApiRequest, NextApiResponse } from 'next';
import { kv } from '@vercel/kv';

const SHARE_CODE_LENGTH = 6;
const TOKEN_EXPIRY_SECONDS = 24 * 60 * 60; // 24 hours
const MAX_CODE_GENERATION_RETRIES = 100; // Prevent infinite loops

function generateShareCode(): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // Excludes confusing chars
  let code = '';
  for (let i = 0; i < SHARE_CODE_LENGTH; i++) {
    code += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return code;
}

function generateToken(): string {
  return Array.from(crypto.getRandomValues(new Uint8Array(32)))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}

interface ShareSession {
  code: string;
  token: string;
  bpm: number | null;
  max: number | null;
  avg: number | null;
  timestamp: number;
}

async function findUnusedCode(): Promise<string> {
  let attempts = 0;
  while (attempts < MAX_CODE_GENERATION_RETRIES) {
    const code = generateShareCode();
    const existing = await kv.get(`share:${code}`);
    if (!existing) {
      return code;
    }
    attempts++;
  }
  throw new Error('Failed to generate unique share code after maximum retries');
}

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method === 'POST') {
    try {
      const code = await findUnusedCode();
      const token = generateToken();
      const session: ShareSession = {
        code,
        token,
        bpm: null,
        max: null,
        avg: null,
        timestamp: Date.now(),
      };

      await kv.setex(`share:${code}`, TOKEN_EXPIRY_SECONDS, JSON.stringify(session));
      await kv.setex(`token:${token}`, TOKEN_EXPIRY_SECONDS, code);

      res.status(200).json({ code, token });
    } catch (error) {
      console.error('Error creating share session:', error);
      res.status(500).json({ error: 'Failed to create share session' });
    }
  } else {
    res.status(405).json({ error: 'Method not allowed' });
  }
}
