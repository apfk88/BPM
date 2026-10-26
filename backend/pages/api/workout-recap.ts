import type { NextApiRequest, NextApiResponse } from 'next';
import { sendApiError } from '../../lib/api-response';
import { decodeRecording, generateRecap, RecapError } from '../../lib/workout-recap';
import { admitRecap } from '../../lib/workout-recap-limits';

export const config = { api: { bodyParser: { sizeLimit: '2800kb' } }, maxDuration: 60 };

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return sendApiError(res, 405, 'Method not allowed', 'METHOD_NOT_ALLOWED');
  }
  const key = process.env.OPENAI_API_KEY;
  if (!key) return sendApiError(res, 503, 'Voice capture is not available yet. You can still type your workout.', 'AI_NOT_CONFIGURED');
  if (!req.headers['content-type']?.startsWith('application/json')) {
    return sendApiError(res, 415, 'Send a JSON recording.', 'INVALID_CONTENT_TYPE');
  }
  try {
    const audio = decodeRecording(req.body);
    // Vercel overwrites this header. Outside Vercel use the connection, not caller-provided forwarding headers.
    const forwarded = process.env.VERCEL ? req.headers['x-vercel-forwarded-for'] : undefined;
    const ip = (Array.isArray(forwarded) ? forwarded[0] : forwarded)?.split(',')[0]?.trim()
      || req.socket.remoteAddress || 'unknown';
    await admitRecap(ip, key);
    const result = await generateRecap(audio, key);
    return res.status(200).json(result);
  } catch (error) {
    if (error instanceof RecapError) return sendApiError(res, error.status, error.message, error.code);
    const timedOut = error instanceof Error && ['TimeoutError', 'AbortError'].includes(error.name);
    return sendApiError(res, timedOut ? 504 : 502,
      timedOut ? 'Processing took too long. Your recording is ready to send again.' : 'Voice capture could not finish. Try sending again.',
      timedOut ? 'AI_TIMEOUT' : 'AI_FAILED');
  }
}
