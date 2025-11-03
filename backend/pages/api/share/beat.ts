import { NextApiRequest, NextApiResponse } from 'next';
import { kv } from '@vercel/kv';

interface ShareSession {
  code: string;
  token: string;
  bpm: number | null;
  max: number | null;
  avg: number | null;
  timestamp: number;
}

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method === 'POST') {
    const { token, bpm, max, avg } = req.body;

    if (!token || typeof bpm !== 'number') {
      return res.status(400).json({ error: 'Missing token or bpm' });
    }

    const code = await kv.get(`token:${token}`);
    if (!code) {
      return res.status(401).json({ error: 'Invalid token' });
    }

    const sessionData = await kv.get(`share:${code}`);
    if (!sessionData) {
      return res.status(404).json({ error: 'Session not found' });
    }

    // Handle both string and object responses from KV
    const session: ShareSession = typeof sessionData === 'string' 
      ? JSON.parse(sessionData) 
      : sessionData as ShareSession;
    session.bpm = bpm;
    if (typeof max === 'number') session.max = max;
    if (typeof avg === 'number') session.avg = avg;
    session.timestamp = Date.now();

    const ttl = await kv.ttl(`share:${code}`);
    await kv.setex(`share:${code}`, ttl > 0 ? ttl : 86400, JSON.stringify(session));

    res.status(200).json({ success: true });
  } else {
    res.status(405).json({ error: 'Method not allowed' });
  }
}
