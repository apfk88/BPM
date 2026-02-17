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
  if (req.method === 'GET') {
    const { code } = req.query;

    if (!code || typeof code !== 'string') {
      return sendApiError(res, 400, 'Missing code', 'MISSING_CODE');
    }

    const sessionData = await kv.get(`share:${code}`);
    if (!sessionData) {
      return sendApiError(res, 404, 'Session not found', 'SESSION_NOT_FOUND');
    }

    // Handle both string and object responses from KV
    const session: ShareSession = typeof sessionData === 'string' 
      ? JSON.parse(sessionData) 
      : sessionData as ShareSession;

    res.status(200).json({
      bpm: session.bpm,
      max: session.max,
      avg: session.avg,
      min: session.min,
      timestamp: session.timestamp,
    });
  } else {
    sendApiError(res, 405, 'Method not allowed', 'METHOD_NOT_ALLOWED');
  }
}
