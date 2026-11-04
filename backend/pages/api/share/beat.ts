import { NextApiRequest, NextApiResponse } from 'next';
import { kv } from '@vercel/kv';
import { sendApiError } from '../../../lib/api-response';
import { recordHeartBeat, ShareRequestError } from '../../../lib/share-workout';

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== 'POST') return sendApiError(res, 405, 'Method not allowed', 'METHOD_NOT_ALLOWED');
  try {
    await recordHeartBeat(kv, req.body);
    res.status(200).json({ success: true });
  } catch (error) {
    if (error instanceof ShareRequestError) return sendApiError(res, error.status, error.message, error.code);
    console.error('Shared heart rate update failed');
    sendApiError(res, 500, 'Unable to update sharing session', 'SHARE_BEAT_FAILED');
  }
}
