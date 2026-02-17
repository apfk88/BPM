import { NextApiRequest, NextApiResponse } from 'next';
import { kv } from '@vercel/kv';
import { sendApiError } from '../../../lib/api-response';

interface ShareSession {
  code: string;
  token: string;
  bpm: number | null;
  max: number | null;
  avg: number | null;
  min: number | null;
  timestamp: number;
}

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method === 'POST') {
    const { token, bpm, max, avg, min } = req.body;

    // bpm can be a number or null (null means disconnected/no data)
    if (!token || (bpm !== null && typeof bpm !== 'number')) {
      return sendApiError(res, 400, 'Missing token or invalid bpm', 'INVALID_BEAT_REQUEST');
    }

    const code = await kv.get(`token:${token}`);
    if (!code) {
      return sendApiError(res, 401, 'Invalid token', 'INVALID_TOKEN');
    }

    const sessionData = await kv.get(`share:${code}`);
    if (!sessionData) {
      return sendApiError(res, 404, 'Session not found', 'SESSION_NOT_FOUND');
    }

    // Handle both string and object responses from KV
    const session: ShareSession = typeof sessionData === 'string' 
      ? JSON.parse(sessionData) 
      : sessionData as ShareSession;
    session.bpm = bpm;
    if (typeof max === 'number') session.max = max;
    if (typeof avg === 'number') session.avg = avg;
    if (typeof min === 'number') session.min = min;
    session.timestamp = Date.now();

    const ttl = await kv.ttl(`share:${code}`);
    await kv.setex(`share:${code}`, ttl > 0 ? ttl : 86400, JSON.stringify(session));

    res.status(200).json({ success: true });
  } else {
    sendApiError(res, 405, 'Method not allowed', 'METHOD_NOT_ALLOWED');
  }
}
