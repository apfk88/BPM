import { randomBytes, randomInt } from 'crypto';
import { NextApiRequest, NextApiResponse } from 'next';
import { kv } from '@vercel/kv';
import { sendApiError } from '../../lib/api-response';
import { createShareSession, deleteShareSession, ShareRequestError } from '../../lib/share-workout';

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  res.setHeader('Cache-Control', 'no-store');
  try {
    if (req.method === 'POST') {
      for (let attempt = 0; attempt < 100; attempt++) {
        const code = String(randomInt(0, 1000000)).padStart(6, '0');
        const token = randomBytes(32).toString('hex');
        if (await createShareSession(kv, code, token)) return res.status(200).json({ code, token });
      }
      throw new Error('Share code capacity exhausted');
    }
    if (req.method === 'DELETE') {
      await deleteShareSession(kv, req.body?.token);
      return res.status(200).json({ success: true });
    }
    sendApiError(res, 405, 'Method not allowed', 'METHOD_NOT_ALLOWED');
  } catch (error) {
    if (error instanceof ShareRequestError) return sendApiError(res, error.status, error.message, error.code);
    console.error('Share session request failed');
    sendApiError(res, 500, 'Unable to update sharing session', 'SHARE_SESSION_FAILED');
  }
}
