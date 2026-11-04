import { NextApiRequest, NextApiResponse } from 'next';
import { kv } from '@vercel/kv';
import { sendApiError } from '../../../lib/api-response';
import { readSharedSession, ShareRequestError } from '../../../lib/share-workout';

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'GET') return sendApiError(res, 405, 'Method not allowed', 'METHOD_NOT_ALLOWED');
  try {
    res.status(200).json(await readSharedSession(kv, req.query.code));
  } catch (error) {
    if (error instanceof ShareRequestError) return sendApiError(res, error.status, error.message, error.code);
    console.error('Shared heart rate request failed');
    sendApiError(res, 500, 'Unable to load sharing session', 'SHARE_READ_FAILED');
  }
}
