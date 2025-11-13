import { NextApiRequest, NextApiResponse } from 'next';
import { kv } from '@vercel/kv';

const SHARE_CODE_LENGTH = 6;
const TOKEN_EXPIRY_SECONDS = 2 * 60 * 60; // 2 hours
const MAX_CODE_GENERATION_RETRIES = 100; // Prevent infinite loops

function generateShareCode(): string {
  const digits = '0123456789';
  let code = '';
  for (let i = 0; i < SHARE_CODE_LENGTH; i++) {
    code += digits.charAt(Math.floor(Math.random() * digits.length));
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
  min: number | null;
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
        min: null,
        timestamp: Date.now(),
      };

      await kv.setex(`share:${code}`, TOKEN_EXPIRY_SECONDS, JSON.stringify(session));
      await kv.setex(`token:${token}`, TOKEN_EXPIRY_SECONDS, code);

      res.status(200).json({ code, token });
    } catch (error) {
      console.error('Error creating share session:', error);
      res.status(500).json({ error: 'Failed to create share session' });
    }
  } else if (req.method === 'DELETE') {
    try {
      const { token } = req.body;

      if (!token || typeof token !== 'string') {
        return res.status(400).json({ error: 'Missing token' });
      }

      const code = await kv.get(`token:${token}`);
      if (!code) {
        // Token already expired or invalid, consider it successful
        return res.status(200).json({ success: true });
      }

      // Delete both the share session and token mapping
      await kv.del(`share:${code}`);
      await kv.del(`token:${token}`);

      res.status(200).json({ success: true });
    } catch (error) {
      console.error('Error deleting share session:', error);
      res.status(500).json({ error: 'Failed to delete share session' });
    }
  } else {
    res.status(405).json({ error: 'Method not allowed' });
  }
}
