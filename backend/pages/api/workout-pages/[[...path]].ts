import type { NextApiRequest, NextApiResponse } from 'next';
import { productionWorkoutPageHandler } from '../../../lib/workout-page-runtime';

// Read bounded raw bytes ourselves: App Attest signs these exact compressed bytes.
export const config = { maxDuration: 60, api: { bodyParser: false, responseLimit: '16mb' } };
export default async function handler(req: NextApiRequest, res: NextApiResponse): Promise<void> {
  await productionWorkoutPageHandler()(req, res);
}
