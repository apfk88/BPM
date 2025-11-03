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
  if (req.method === 'GET') {
    const { code } = req.query;

    if (!code || typeof code !== 'string') {
      return res.status(400).json({ error: 'Missing code' });
    }

    const sessionStr = await kv.get(`share:${code}`);
    if (!sessionStr) {
      return res.status(404).json({ error: 'Session not found' });
    }

    const session: ShareSession = JSON.parse(sessionStr as string);

    res.status(200).json({
      bpm: session.bpm,
      max: session.max,
      avg: session.avg,
      timestamp: session.timestamp,
    });
  } else {
    res.status(405).json({ error: 'Method not allowed' });
  }
}
