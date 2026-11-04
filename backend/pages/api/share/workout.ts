import { NextApiRequest, NextApiResponse } from 'next';
import { kv } from '@vercel/kv';
import { sendApiError } from '../../../lib/api-response';
import { publishWorkout, ShareRequestError } from '../../../lib/share-workout';

export const config = { api: { bodyParser: { sizeLimit: '2mb' } } };

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return sendApiError(res, 405, 'Method not allowed', 'METHOD_NOT_ALLOWED');
  try {
    res.status(200).json(await publishWorkout(kv, req.body));
  } catch (error) {
    if (error instanceof ShareRequestError) return sendApiError(res, error.status, error.message, error.code);
    console.error('Shared workout update failed');
    sendApiError(res, 500, 'Unable to update shared workout', 'WORKOUT_UPDATE_FAILED');
  }
}
