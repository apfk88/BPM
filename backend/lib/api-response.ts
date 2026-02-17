import { NextApiResponse } from 'next';

export interface ApiErrorBody {
  error: string;
  message: string;
  code: string;
}

export function sendApiError(
  res: NextApiResponse,
  status: number,
  message: string,
  code: string,
): void {
  const body: ApiErrorBody = {
    error: message,
    message,
    code,
  };
  res.status(status).json(body);
}
